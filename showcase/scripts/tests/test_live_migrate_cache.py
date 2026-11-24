"""Unit tests for live Postgres & ClickHouse migration snapshot cache helpers."""

from __future__ import annotations

import contextlib
import hashlib
import http.server
import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
import uuid
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import live_migrate_cache as lmc  # noqa: E402


def _seed_repo(root: Path) -> None:
    (root / "products").mkdir(parents=True, exist_ok=True)
    (root / "products/db_routing.yaml").write_text(
        "routes:\n"
        "  - app_label: visual_review\n    database: visual_review\n"
        "  - app_label: stamphog\n    database: stamphog\n",
        encoding="utf-8",
    )
    for rel in (
        "posthog/migrations/0001_initial.py",
        "products/visual_review/backend/migrations/0001_initial.py",
        "posthog/clickhouse/migrations/0001_initial.py",
        "posthog/clickhouse/migrations/0002_events.py",
        "ee/clickhouse/migrations/0001_ee.py",
        "infra/clickhouse/config.xml",
        "showcase/scripts/live_posthog.sh",
        "showcase/scripts/live_migrate_cache.py",
    ):
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(f"# {rel}\n", encoding="utf-8")
    (root / "uv.lock").write_text(
        'version = 1\n\n[[package]]\nname = "infi-clickhouse-orm"\nversion = "2.1.3"\n\n'
        '[[package]]\nname = "other-pkg"\nversion = "1.0.0"\n',
        encoding="utf-8",
    )


class CanonicalDdlAndOrderingTest(unittest.TestCase):
    def test_canonicalize_strips_uuid_normalizes_zk_and_preserves_db_before_kafka_prefix(self) -> None:
        ddl = (
            "CREATE TABLE posthog_e2e_test_1.events UUID '11111111-2222-3333-4444-555555555555' "
            "(`uuid` UUID) "
            "ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/99999999-aaaa-bbbb-cccc-dddddddddddd_noshard/posthog.events', '{replica}-{shard}', _timestamp) "
            "SETTINGS kafka_broker_list = '127.0.0.1:19092', "
            "kafka_topic_list = 'e2e_test_1_events_json', "
            "kafka_group_name = 'e2e_test_1_group'"
        )
        canonical = lmc.canonicalize_ddl(
            ddl,
            ch_db="posthog_e2e_test_1",
            kafka_prefix="e2e_test_1_",
            kafka_broker="127.0.0.1:19092",
        )
        self.assertNotIn("11111111-2222-3333-4444-555555555555", canonical)
        self.assertNotIn("99999999-aaaa-bbbb-cccc-dddddddddddd", canonical)
        self.assertIn("CREATE TABLE __ENACT_CH_DB__.events (`uuid` UUID)", canonical)
        self.assertIn("'/clickhouse/tables/__ENACT_CH_ZK__/noshard/posthog.events'", canonical)
        self.assertIn("kafka_broker_list = '__ENACT_KAFKA_BROKER__'", canonical)
        self.assertIn("kafka_topic_list = '__ENACT_KAFKA_PREFIX__events_json'", canonical)
        self.assertNotIn("posthog___ENACT_KAFKA_PREFIX__", canonical)

        rehydrated = lmc.instantiate_ddl(
            canonical,
            ch_db="posthog_mcp_1",
            kafka_prefix="mcp_1_",
            kafka_broker="127.0.0.1:29092",
            zk_prefix="enactzk_0123456789ab",
        )
        self.assertIn("CREATE TABLE posthog_mcp_1.events (`uuid` UUID)", rehydrated)
        self.assertIn("'/clickhouse/tables/enactzk_0123456789ab/noshard/posthog.events'", rehydrated)
        self.assertIn("kafka_broker_list = '127.0.0.1:29092'", rehydrated)
        self.assertIn("kafka_topic_list = 'mcp_1_events_json'", rehydrated)
        self.assertEqual(
            lmc.canonicalize_ddl(rehydrated, "posthog_mcp_1", "mcp_1_", "127.0.0.1:29092"),
            canonical,
        )

    def test_prod_tables_noshard_canonicalization_and_base_recapture_idempotence(self) -> None:
        cases = [
            (
                "CREATE TABLE posthog_e2e_1.infi_clickhouse_orm_migrations (`package_name` String) "
                "ENGINE = ReplicatedMergeTree('/clickhouse/prod/tables/noshard/posthog_e2e_1/infi_clickhouse_orm_migrations', '{replica}-{shard}')",
                "'/clickhouse/prod/tables/__ENACT_CH_ZK__/noshard/__ENACT_CH_DB__/infi_clickhouse_orm_migrations'",
                "'/clickhouse/prod/tables/enactzk_a1b2c3d4e5f6/noshard/posthog_mcp_2/infi_clickhouse_orm_migrations'",
            ),
            (
                "CREATE TABLE posthog_e2e_1.infi_clickhouse_orm_migrations (`package_name` String) "
                "ENGINE = ReplicatedMergeTree('/clickhouse/prod/tables/noshard/{database}/{table}', '{replica}-{shard}')",
                "'/clickhouse/prod/tables/__ENACT_CH_ZK__/noshard/{database}/{table}'",
                "'/clickhouse/prod/tables/enactzk_a1b2c3d4e5f6/noshard/{database}/{table}'",
            ),
            (
                "CREATE TABLE posthog_e2e_1.cohort_membership (`id` Int64) "
                "ENGINE = ReplicatedReplacingMergeTree('/clickhouse/prod/tables/posthog.cohort_membership', '{replica}-{shard}', id)",
                "'/clickhouse/prod/tables/__ENACT_CH_ZK__/posthog.cohort_membership'",
                "'/clickhouse/prod/tables/enactzk_a1b2c3d4e5f6/posthog.cohort_membership'",
            ),
        ]
        for raw_ddl, want_canonical_zk, want_instantiated_zk in cases:
            canonical = lmc.canonicalize_ddl(raw_ddl, "posthog_e2e_1", "e2e_1_", "127.0.0.1:19092")
            self.assertIn(want_canonical_zk, canonical)
            self.assertNotIn("posthog_e2e_1", canonical)
            instantiated = lmc.instantiate_ddl(
                canonical, "posthog_mcp_2", "mcp_2_", "127.0.0.1:29092", "enactzk_a1b2c3d4e5f6"
            )
            self.assertIn(want_instantiated_zk, instantiated)
            recaptured = lmc.canonicalize_ddl(instantiated, "posthog_mcp_2", "mcp_2_", "127.0.0.1:29092")
            self.assertEqual(recaptured, canonical)
            self.assertNotIn("enactzk_", recaptured)
            self.assertNotIn("posthog_mcp_2", recaptured)

    def test_order_ddl_statements_respects_tiers_and_view_dag(self) -> None:
        rows = [
            {
                "name": "summary_view",
                "engine": "View",
                "ddl": "CREATE VIEW db.summary_view AS SELECT * FROM db.events_mv",
                "dependencies_table": ["db.events_mv"],
            },
            {
                "name": "events_mv",
                "engine": "MaterializedView",
                "ddl": "CREATE MATERIALIZED VIEW db.events_mv TO db.events_dist AS SELECT * FROM db.events_kafka WHERE dictHas('db.geo_dict', city)",
                "dependencies_table": ["db.events_kafka", "db.events_dist"],
            },
            {
                "name": "geo_dict",
                "engine": "Dictionary",
                "ddl": "CREATE DICTIONARY db.geo_dict (id UInt64) SOURCE(CLICKHOUSE(TABLE 'events_local'))",
                "dependencies_table": [],
            },
            {
                "name": "events_dist",
                "engine": "Distributed",
                "ddl": "CREATE TABLE db.events_dist AS db.events_local ENGINE = Distributed('cluster', 'db', 'events_local')",
                "dependencies_table": [],
            },
            {
                "name": "events_kafka",
                "engine": "Kafka",
                "ddl": "CREATE TABLE db.events_kafka (x String) ENGINE = Kafka()",
                "dependencies_table": [],
            },
            {
                "name": "events_local",
                "engine": "MergeTree",
                "ddl": "CREATE TABLE db.events_local (x String) ENGINE = MergeTree()",
                "dependencies_table": [],
            },
        ]
        ordered = [r["name"] for r in lmc.order_ddl_statements(rows, ch_db="db")]
        self.assertEqual(ordered[:2], ["events_kafka", "events_local"])
        self.assertEqual(ordered[2], "events_dist")
        self.assertEqual(ordered[3], "geo_dict")
        self.assertEqual(ordered[4], "events_mv")
        self.assertEqual(ordered[5], "summary_view")


class KeysAndSubsetSelectionTest(unittest.TestCase):
    def test_ch_key_stability_and_invalidation(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _seed_repo(root)
            k1 = lmc.compute_ch_key(root, "ClickHouse client version 25.3.1.100")
            # Patch version change within same major.minor keeps key identical.
            self.assertEqual(k1, lmc.compute_ch_key(root, "25.3.9.2"))
            # Unrelated package update in uv.lock keeps key identical.
            lock = root / "uv.lock"
            lock.write_text(lock.read_text().replace("1.0.0", "1.0.1"), encoding="utf-8")
            self.assertEqual(k1, lmc.compute_ch_key(root, "25.3.1.100"))
            # ClickHouse minor bump invalidates key.
            self.assertNotEqual(k1, lmc.compute_ch_key(root, "25.4.0.1"))
            # Migration change invalidates key.
            (root / "posthog/clickhouse/migrations/0003_extra.py").write_text("# 3\n", encoding="utf-8")
            k2 = lmc.compute_ch_key(root, "25.3.1.100")
            self.assertNotEqual(k1, k2)

    def test_select_ch_and_pg_base_pick_largest_valid_subset(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "repo"
            store = Path(work) / "snapshots"
            _seed_repo(root)

            # Two CH candidates: older 1-migration subset and stale 3-migration one referencing a deleted migration.
            old_key = "1" * 64
            lmc.publish_generation(
                store / "ch-v1",
                lmc.CH_FORMAT_PREFIX,
                old_key,
                "ch25.3",
                {
                    "ddl.json": b'{"database_ddl":"CREATE DATABASE IF NOT EXISTS __ENACT_CH_DB__","statements":[]}',
                    "migrations.json": json.dumps(
                        {"applied": [["posthog.clickhouse.migrations", "0001_initial"]], "applied_jsonl": "{}"}
                    ).encode(),
                    "seed_rows.json": b"{}",
                },
            )
            stale_key = "2" * 64
            lmc.publish_generation(
                store / "ch-v1",
                lmc.CH_FORMAT_PREFIX,
                stale_key,
                "ch25.3",
                {
                    "ddl.json": b'{"database_ddl":"CREATE DATABASE IF NOT EXISTS __ENACT_CH_DB__","statements":[]}',
                    "migrations.json": json.dumps(
                        {
                            "applied": [
                                ["posthog.clickhouse.migrations", "0001_initial"],
                                ["posthog.clickhouse.migrations", "0999_deleted"],
                            ],
                            "applied_jsonl": "{}",
                        }
                    ).encode(),
                    "seed_rows.json": b"{}",
                },
            )
            best_ch = lmc.select_ch_base(store / "ch-v1", root, "25.3.2")
            self.assertIsNotNone(best_ch)
            assert best_ch is not None
            self.assertEqual(best_ch.parent.name, old_key)

            # PG candidates: verify same template_key & subset check.
            pg_key_ok = lmc.compute_pg_key(root, "tpl_a", "15")
            pg_key_stale = "3" * 64
            lmc.publish_generation(
                store / "live-v1",
                lmc.PG_FORMAT_PREFIX,
                pg_key_ok,
                "pg15",
                {
                    "live-postgres.dump": b"PGDMP",
                    "live-migrations.json": json.dumps(
                        {
                            "template_key": "tpl_a",
                            "routed_apps": ["stamphog", "visual_review"],
                            "applied": [["posthog", "0001_initial"], ["visual_review", "0001_initial"]],
                        }
                    ).encode(),
                },
            )
            lmc.publish_generation(
                store / "live-v1",
                lmc.PG_FORMAT_PREFIX,
                pg_key_stale,
                "pg15",
                {
                    "live-postgres.dump": b"PGDMP",
                    "live-migrations.json": json.dumps(
                        {
                            "template_key": "tpl_a",
                            "routed_apps": ["stamphog", "visual_review"],
                            "applied": [["posthog", "0999_deleted"]],
                        }
                    ).encode(),
                },
            )
            best_pg = lmc.select_pg_base(store / "live-v1", root, "tpl_a", "15")
            self.assertIsNotNone(best_pg)
            assert best_pg is not None
            self.assertEqual(best_pg.parent.name, pg_key_ok)


class SnapshotVerificationAndHttpRoundtripTest(unittest.TestCase):
    def test_verify_cli_rejects_corrupt_and_escaping_snapshots(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "snapshots"
            key = "a" * 64
            gen_dir = lmc.publish_generation(
                root / "live-v1",
                lmc.PG_FORMAT_PREFIX,
                key,
                "pg15",
                {"live-postgres.dump": b"PGDMP", "live-migrations.json": b'{"applied": []}'},
            )
            out_file = Path(work) / "github-output"
            res = subprocess.run(
                [sys.executable, str(SCRIPTS / "live_migrate_cache.py"), "verify", str(root)],
                env={**os.environ, "GITHUB_OUTPUT": str(out_file)},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(out_file.read_text(encoding="utf-8"), "eligible=true\n")

            # Corrupt dump breaks verification.
            (gen_dir / "live-postgres.dump").write_bytes(b"tampered")
            bad = subprocess.run(
                [sys.executable, str(SCRIPTS / "live_migrate_cache.py"), "verify", str(root)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(bad.returncode, 1)

            # Pointer escape also fails verification.
            (gen_dir.parent / "current-v1").write_text("../../escape\n", encoding="utf-8")
            esc = subprocess.run(
                [sys.executable, str(SCRIPTS / "live_migrate_cache.py"), "verify", str(root)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(esc.returncode, 1)

    def test_ch_capture_and_restore_against_mock_clickhouse_http(self) -> None:
        executed: list[tuple[str, str]] = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                return

            def do_POST(self) -> None:
                parsed = urllib.parse.urlparse(self.path)
                params = urllib.parse.parse_qs(parsed.query)
                query = params.get("query", [""])[0]
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length).decode("utf-8") if length else ""
                executed.append((query, body))
                payload = b""
                if "FROM system.tables" in query:
                    payload = json.dumps(
                        {
                            "data": [
                                {
                                    "name": "events",
                                    "engine": "MergeTree",
                                    "create_table_query": "CREATE TABLE posthog_e2e_1.events UUID '00000000-0000-0000-0000-000000000001' (`id` Int64) ENGINE = MergeTree()",
                                    "dependencies_table": [],
                                    "total_rows": "0",
                                },
                                {
                                    "name": "channel_definition",
                                    "engine": "MergeTree",
                                    "create_table_query": "CREATE TABLE posthog_e2e_1.channel_definition (`k` String) ENGINE = MergeTree()",
                                    "dependencies_table": [],
                                    "total_rows": "1",
                                },
                                {
                                    "name": "infi_clickhouse_orm_migrations",
                                    "engine": "MergeTree",
                                    "create_table_query": "CREATE TABLE posthog_e2e_1.infi_clickhouse_orm_migrations (`package_name` String, `module_name` String, `applied` Date) ENGINE = MergeTree()",
                                    "dependencies_table": [],
                                    "total_rows": "2",
                                },
                            ]
                        }
                    ).encode("utf-8")
                elif "FROM `posthog_e2e_1`.`infi_clickhouse_orm_migrations`" in query:
                    payload = (
                        '{"package_name":"posthog.clickhouse.migrations","module_name":"0001_initial","applied":"2026-01-01"}\n'
                        '{"package_name":"posthog.clickhouse.migrations","module_name":"0002_events","applied":"2026-01-01"}\n'
                    ).encode("utf-8")
                elif "FROM `posthog_e2e_1`.`channel_definition`" in query:
                    payload = b'{"k":"direct"}\n'
                self.send_response(200)
                self.end_headers()
                self.wfile.write(payload)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)
        self.addCleanup(server.server_close)

        with tempfile.TemporaryDirectory() as work:
            repo = Path(work) / "repo"
            snap = Path(work) / "snapshots"
            _seed_repo(repo)
            url = f"http://127.0.0.1:{server.server_address[1]}"
            key = lmc.compute_ch_key(repo, "25.3.1")
            lmc.capture_ch_snapshot(
                snap,
                repo,
                key,
                "25.3.1",
                url,
                "posthog_e2e_1",
                "e2e_1_",
                "127.0.0.1:19092",
                "default",
                "",
            )
            executed.clear()
            mode = lmc.restore_ch_snapshot(
                snap,
                repo,
                key,
                "25.3.1",
                url,
                "posthog_mcp_2",
                "mcp_2_",
                "127.0.0.1:29092",
                "default",
                "",
            )
            self.assertEqual(mode, "exact")
            queries = [q for q, _ in executed]
            self.assertEqual(queries[0], "SYSTEM FLUSH LOGS")
            self.assertEqual(queries[1], "DROP DATABASE IF EXISTS `posthog_mcp_2` SYNC")
            self.assertEqual(queries[2], "CREATE DATABASE IF NOT EXISTS posthog_mcp_2")
            self.assertTrue(any("CREATE TABLE posthog_mcp_2.events (`id` Int64)" in q for q in queries))
            mig_inserts = [b for q, b in executed if "INSERT INTO `posthog_mcp_2`.`infi_clickhouse_orm_migrations`" in q]
            self.assertEqual(len(mig_inserts), 1)
            self.assertIn('"0002_events"', mig_inserts[0])
            seed_inserts = [b for q, b in executed if "INSERT INTO `posthog_mcp_2`.`channel_definition`" in q]
            self.assertEqual(seed_inserts, ['{"k":"direct"}\n'])

    def test_pg_publish_does_not_deadlock_under_caller_migrate_lock(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "snapshots"
            repo = Path(work) / "repo"
            _seed_repo(repo)
            key = "b" * 64
            dump_file = Path(work) / "live-postgres.dump"
            applied_file = Path(work) / "applied.tsv"
            dump_file.write_bytes(b"PGDMP")
            applied_file.write_text("posthog\t0001_initial\nvisual_review\t0001_initial\n", encoding="utf-8")

            with (
                lmc.file_lock(root / "live-v1" / f"{key}.migrate.lock"),
                lmc.file_lock(root / "live-v1" / f"{key}.lock"),
            ):
                pub = subprocess.run(
                    [
                        sys.executable,
                        str(SCRIPTS / "live_migrate_cache.py"),
                        "pg-publish",
                        "--snapshot-root",
                        str(root),
                        "--repo",
                        str(repo),
                        "--key",
                        key,
                        "--pg-major",
                        "15",
                        "--template-key",
                        "tpl_a",
                        "--dump-file",
                        str(dump_file),
                        "--applied-file",
                        str(applied_file),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=False,
                )
            self.assertEqual(pub.returncode, 0, pub.stderr)
            ver = subprocess.run(
                [sys.executable, str(SCRIPTS / "live_migrate_cache.py"), "verify", str(root)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(ver.returncode, 0, ver.stderr)


class ScriptAndFootprintOptimizationsTest(unittest.TestCase):
    def test_pg_and_ch_keys_ignore_runner_script_edits(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            _seed_repo(root)
            pg1 = lmc.compute_pg_key(root, "tpl_a", "15")
            ch1 = lmc.compute_ch_key(root, "25.3.1")
            (root / "showcase/scripts/live_posthog.sh").write_text("# edited\n", encoding="utf-8")
            (root / "showcase/scripts/live_migrate_cache.py").write_text("# edited\n", encoding="utf-8")
            self.assertEqual(pg1, lmc.compute_pg_key(root, "tpl_a", "15"))
            self.assertEqual(ch1, lmc.compute_ch_key(root, "25.3.1"))

    def test_restored_delta_suppresses_unchanged_cache_saves_until_new_entry_or_schedule(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work) / "snapshots"
            runner_temp = Path(work) / "runner-temp"
            delta_dir = runner_temp / "enact-cache-delta"
            delta_dir.mkdir(parents=True)
            key = "b" * 64
            gen = lmc.publish_generation(
                root / "live-v1",
                lmc.PG_FORMAT_PREFIX,
                key,
                "pg15",
                {"live-postgres.dump": b"PGDMP", "live-migrations.json": b'{"applied": [["posthog", "0001"]]}'},
            )
            (root / "live-v1" / f"{key}.migrate.lock").write_text("", encoding="utf-8")
            restored_entries = [
                f"{(root / 'live-v1').as_posix()}/{key}/current-v1",
                f"{gen.as_posix()}/manifest",
                f"{gen.as_posix()}/live-postgres.dump",
                f"{gen.as_posix()}/live-migrations.json",
            ]
            (delta_dir / "cache_live_migrations.restored").write_text(
                "\n".join(restored_entries) + "\n", encoding="utf-8"
            )

            gh_out = Path(work) / "gh-out-unchanged"
            res = subprocess.run(
                [sys.executable, str(SCRIPTS / "live_migrate_cache.py"), "verify", str(root)],
                env={
                    **os.environ,
                    "RUNNER_TEMP": str(runner_temp),
                    "GITHUB_OUTPUT": str(gh_out),
                    "GITHUB_EVENT_NAME": "push",
                },
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(gh_out.read_text(encoding="utf-8").strip(), "eligible=false")

            # Scheduled runs still refresh rolling lineage.
            gh_sched = Path(work) / "gh-out-schedule"
            subprocess.run(
                [sys.executable, str(SCRIPTS / "live_migrate_cache.py"), "verify", str(root)],
                env={
                    **os.environ,
                    "RUNNER_TEMP": str(runner_temp),
                    "GITHUB_OUTPUT": str(gh_sched),
                    "GITHUB_EVENT_NAME": "schedule",
                },
                check=True,
            )
            self.assertEqual(gh_sched.read_text(encoding="utf-8").strip(), "eligible=true")

            # Publishing a new CH generation flips eligible back to true.
            lmc.publish_generation(
                root / "ch-v1",
                lmc.CH_FORMAT_PREFIX,
                "c" * 64,
                "ch25.3",
                {
                    "ddl.json": b'{"database_ddl":"CREATE DATABASE IF NOT EXISTS __ENACT_CH_DB__","statements":[]}',
                    "migrations.json": b'{"applied":[["posthog.clickhouse.migrations","0001"]],"applied_jsonl":"{}"}',
                    "seed_rows.json": b"{}",
                },
            )
            gh_added = Path(work) / "gh-out-added"
            subprocess.run(
                [sys.executable, str(SCRIPTS / "live_migrate_cache.py"), "verify", str(root)],
                env={
                    **os.environ,
                    "RUNNER_TEMP": str(runner_temp),
                    "GITHUB_OUTPUT": str(gh_added),
                    "GITHUB_EVENT_NAME": "push",
                },
                check=True,
            )
            self.assertEqual(gh_added.read_text(encoding="utf-8").strip(), "eligible=true")

    def test_template_publications_skips_unchanged_restored_v3_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            v3 = Path(work) / "v3"
            (v3 / "k1").mkdir(parents=True)
            (v3 / "k1/manifest").write_text("ok\n", encoding="utf-8")
            (v3 / "k1.lock").write_text("", encoding="utf-8")
            runner_temp = Path(work) / "rt"
            (runner_temp / "enact-cache-delta").mkdir(parents=True)
            (runner_temp / "enact-cache-delta/cache_backend_templates.restored").write_text(
                f"{v3.as_posix()}/k1/manifest\n", encoding="utf-8"
            )
            fake_enact = Path(work) / "fake-enact"
            fake_enact.write_text(
                "#!/usr/bin/env bash\n"
                '[ -z "${GITHUB_OUTPUT:-}" ] || echo "eligible=true" >> "$GITHUB_OUTPUT"\n'
                "exit 0\n",
                encoding="utf-8",
            )
            fake_enact.chmod(0o755)
            gh_out = Path(work) / "gh-tpl"
            res = subprocess.run(
                [sys.executable, str(SCRIPTS / "template_publications.py"), str(v3)],
                env={
                    **os.environ,
                    "ENACT_EXE": str(fake_enact),
                    "RUNNER_TEMP": str(runner_temp),
                    "GITHUB_OUTPUT": str(gh_out),
                    "GITHUB_EVENT_NAME": "push",
                },
                check=False,
            )
            self.assertEqual(res.returncode, 0)
            self.assertEqual(gh_out.read_text(encoding="utf-8").strip(), "eligible=false")

    def test_live_footprint_hoists_multi_spec_intersection_and_strips_playwright_artifacts(self) -> None:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from hermetic import helper_env

        with tempfile.TemporaryDirectory() as work:
            repo = Path(work)
            (repo / "frontend/app-esbuild-meta.json").parent.mkdir(parents=True)
            (repo / "frontend/app-esbuild-meta.json").write_text('{"outputs": {}}', encoding="utf-8")
            common_dirs = [f"frontend/src/dir_{i}" for i in range(120)]
            common_files = [f"frontend/src/shared_{i}.tsx" for i in range(80)]
            for rel in common_files:
                p = repo / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("export const x = 1\n", encoding="utf-8")
            recording = repo / "rec"
            (recording / "records").mkdir(parents=True)
            specs = [f"playwright/e2e/spec_{i}.spec.ts" for i in range(12)]
            for idx, spec in enumerate(specs, 1):
                (repo / spec).parent.mkdir(parents=True, exist_ok=True)
                (repo / spec).write_text("test()\n", encoding="utf-8")
                (recording / "records" / f"{idx}.started").write_text(f"{spec}\n", encoding="utf-8")
                (recording / "records" / f"{idx}.json").write_text(
                    json.dumps(
                        {
                            "footprint": {
                                "reads": [
                                    *common_files,
                                    f"unique_{idx}.py",
                                    ".playwright-screenshots/shot.png",
                                    "playwright/test-results/trace.zip",
                                ],
                                "dirs": [*common_dirs, f"dir_unique_{idx}", ".playwright-screenshots"],
                                "code": {"posthog/api/shared_view.py": ["common_fn", f"fn_{idx}"]},
                                "loaded": ["posthog/api/shared_view.py"],
                            }
                        }
                    ),
                    encoding="utf-8",
                )
                node = recording / f"node/{idx}"
                node.mkdir(parents=True)
                (node / "1.started").write_text("node\n", encoding="utf-8")
                (node / "1.json").write_text(json.dumps({"reads": [spec]}), encoding="utf-8")

            out = repo / "maps"
            env = helper_env() | {"ENACT_FOOTPRINT_DIR": str(out), "LIVE_JOB": "run_e2e_tests.sh"}
            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS / "live_footprint.py"),
                    "write",
                    str(recording),
                    *[f"{s}=0" for s in specs],
                ],
                cwd=repo,
                env=env,
                check=True,
            )
            (written,) = [p for p in out.iterdir() if p.suffix == ".json"]
            doc = json.loads(written.read_text(encoding="utf-8"))
            shared = doc["shared"]
            self.assertTrue(set(common_files).issubset(set(shared["files"])))
            self.assertTrue(set(common_dirs).issubset(set(shared["dirs"])))
            self.assertEqual(shared["functions"].get("posthog/api/shared_view.py"), ["common_fn"])
            self.assertIn("posthog/api/shared_view.py", shared["loaded"])
            self.assertNotIn(".playwright-screenshots", shared["dirs"])
            for idx, spec in enumerate(specs, 1):
                t = doc["targets"][spec]
                self.assertFalse(set(common_files) & set(t["files"]))
                self.assertFalse(set(common_dirs) & set(t["dirs"]))
                self.assertEqual(t["functions"].get("posthog/api/shared_view.py"), [f"fn_{idx}"])
                self.assertNotIn(".playwright-screenshots/shot.png", t["files"])
                self.assertNotIn("playwright/test-results/trace.zip", t["files"])

    def test_ci_scripts_runner_caps_auto_traces_and_batches_remaining(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            repo = Path(work)
            (repo / "showcase/scripts").mkdir(parents=True)
            runner = repo / "showcase/scripts/run_ci_scripts_tests.sh"
            runner.write_text((SCRIPTS / "run_ci_scripts_tests.sh").read_text(encoding="utf-8"), encoding="utf-8")
            runner.chmod(0o755)

            venv_bin = repo / ".venv/bin"
            venv_bin.mkdir(parents=True)
            calls_log = repo / "calls.log"
            fake_py = venv_bin / "python"
            fake_py.write_text(
                "#!/usr/bin/env bash\n"
                f'echo "PY:$*" >> "{calls_log}"\n'
                "exit 0\n",
                encoding="utf-8",
            )
            fake_py.chmod(0o755)
            fake_enact = repo / "fake-enact"
            fake_enact.write_text(
                "#!/usr/bin/env bash\n"
                f'echo "TRACE:$*" >> "{calls_log}"\n'
                'while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done\n'
                '[ "$#" -gt 0 ] && shift\n'
                'exec "$@"\n',
                encoding="utf-8",
            )
            fake_enact.chmod(0o755)

            (repo / ".github/scripts").mkdir(parents=True)
            targets = []
            for i in range(6):
                rel = f".github/scripts/test_{i}.py"
                (repo / rel).write_text("def test_ok(): pass\n", encoding="utf-8")
                targets.append(rel)
            targets_file = repo / "wanted.txt"
            targets_file.write_text("\n".join(targets) + "\n", encoding="utf-8")
            fp_dir = repo / "fp"
            fp_dir.mkdir()

            subprocess.run(
                ["bash", str(runner), *targets],
                cwd=repo,
                env={
                    **os.environ,
                    "ENACT_EXE": str(fake_enact),
                    "ENACT_FOOTPRINT_DIR": str(fp_dir),
                    "ENACT_FOOTPRINT_TARGETS": str(targets_file),
                    "ENACT_CI_SCRIPTS_FORCE_TRACE": "Linux",
                    "ENACT_RECORD": "auto",
                    "ENACT_MAX_AUTO_TRACE_FILES": "2",
                },
                check=True,
            )
            lines = calls_log.read_text(encoding="utf-8").splitlines()
            traces = [l for l in lines if l.startswith("TRACE:")]
            pys = [l for l in lines if l.startswith("PY:")]
            self.assertEqual(len(traces), 2, lines)
            # 2 traced individual runs + 1 batched pytest run for the remaining 4 files!
            self.assertEqual(len(pys), 3, lines)
            self.assertIn(".github/scripts/test_2.py .github/scripts/test_3.py .github/scripts/test_4.py .github/scripts/test_5.py", pys[-1])

    def test_frontend_runner_caps_auto_traces_and_preserves_unlimited_explicit_record(self) -> None:
        runner_text = (SCRIPTS / "run_frontend_tests.sh").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as work:
            repo = Path(work).resolve()
            (repo / "showcase/scripts").mkdir(parents=True)
            runner = repo / "showcase/scripts/run_frontend_tests.sh"
            runner.write_text(runner_text, encoding="utf-8")
            runner.chmod(0o755)

            bin_dir = repo / "fake-bin"
            bin_dir.mkdir()
            calls_log = repo / "fe-calls.log"
            for name, body in (
                ("realpath", '#!/usr/bin/env bash\necho "${!#}"\n'),
                (
                    "pnpm",
                    "#!/usr/bin/env bash\n"
                    f'echo "PNPM:$*" >> "{calls_log}"\n'
                    "exit 0\n",
                ),
            ):
                p = bin_dir / name
                p.write_text(body, encoding="utf-8")
                p.chmod(0o755)
            fake_enact = repo / "fake-enact"
            fake_enact.write_text(
                "#!/usr/bin/env bash\n"
                f'echo "TRACE:$*" >> "{calls_log}"\n'
                'while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done\n'
                '[ "$#" -gt 0 ] && shift\n'
                'exec "$@"\n',
                encoding="utf-8",
            )
            fake_enact.chmod(0o755)

            recorders_dir = repo / "recorders/js"
            recorders_dir.mkdir(parents=True)
            (recorders_dir / "jest-attribution.cjs").write_text("", encoding="utf-8")

            targets = [f"frontend/src/t_{i}.test.tsx" for i in range(5)]
            for rel in targets:
                (repo / rel).parent.mkdir(parents=True, exist_ok=True)
                (repo / rel).write_text("test()\n", encoding="utf-8")
            wanted = repo / "wanted.txt"
            wanted.write_text("\n".join(targets) + "\n", encoding="utf-8")
            fp_dir = repo / "fp"
            fp_dir.mkdir()

            base_env = {
                **os.environ,
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "ENACT_EXE": str(fake_enact),
                "ENACT_RECORDERS_DIR": str(repo / "recorders"),
                "ENACT_FOOTPRINT_DIR": str(fp_dir),
                "ENACT_FOOTPRINT_TARGETS": str(wanted),
                "ENACT_FRONTEND_FORCE_TRACE": "Linux",
                "ENACT_MAX_AUTO_TRACE_FILES": "2",
            }

            subprocess.run(["bash", str(runner), *targets], cwd=repo, env={**base_env, "ENACT_RECORD": "auto"}, check=True)
            auto_lines = calls_log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len([l for l in auto_lines if l.startswith("TRACE:")]), 2, auto_lines)
            self.assertTrue(any("--maxWorkers=3" in l and "t_2.test.tsx" in l for l in auto_lines), auto_lines)

            calls_log.write_text("", encoding="utf-8")
            subprocess.run(["bash", str(runner), *targets], cwd=repo, env={**base_env, "ENACT_RECORD": "every"}, check=True)
            every_lines = calls_log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len([l for l in every_lines if l.startswith("TRACE:")]), 5, every_lines)
            self.assertFalse(any("--maxWorkers=3" in l for l in every_lines), every_lines)


def _live_ch_http_url() -> str | None:
    port = os.environ.get("CLICKHOUSE_HTTP_PORT", "")
    host = os.environ.get("CLICKHOUSE_HOST", "127.0.0.1")
    if not port:
        return None
    try:
        socket.create_connection((host, int(port)), timeout=1).close()
    except OSError:
        return None
    return f"http://{host}:{port}"


def _ch_row(name: str, engine: str, ddl: str, deps: list[str] | None = None, rows: str = "0") -> dict:
    return {"name": name, "engine": engine, "create_table_query": ddl, "dependencies_table": deps or [], "total_rows": rows}


class ChV2DanglingMvAndKeeperFixTest(unittest.TestCase):
    def test_ch_v2_manifest_validation_and_dangling_mv_filtering_roundtrip(self) -> None:
        self.assertEqual(lmc.CH_FORMAT_PREFIX, "enact-live-ch-v2")
        executed: list[str] = []
        state = {"db": "posthog_e2e_1", "zk": "/clickhouse/prod/tables/noshard/posthog_e2e_1/infi_clickhouse_orm_migrations"}

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                return

            def do_POST(self) -> None:
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("query", [""])[0]
                if self.headers.get("Content-Length"):
                    self.rfile.read(int(self.headers["Content-Length"]))
                executed.append(q)
                db = state["db"]
                payload = b""
                if "FROM system.tables" in q:
                    payload = json.dumps(
                        {
                            "data": [
                                _ch_row("events", "MergeTree", f"CREATE TABLE {db}.events (`id` Int64) ENGINE = MergeTree()"),
                                _ch_row(
                                    "infi_clickhouse_orm_migrations",
                                    "ReplicatedMergeTree",
                                    f"CREATE TABLE {db}.infi_clickhouse_orm_migrations (`package_name` String, `module_name` String, `applied` Date) ENGINE = ReplicatedMergeTree('{state['zk']}', '{{replica}}-{{shard}}')",
                                    rows="1",
                                ),
                                _ch_row("events_valid_mv", "MaterializedView", f"CREATE MATERIALIZED VIEW `{db}`.`events_valid_mv` TO `{db}`.`events` AS SELECT id FROM {db}.events", [f"{db}.events"]),
                                _ch_row("inner_mv", "MaterializedView", f"CREATE MATERIALIZED VIEW {db}.inner_mv (`id` Int64) ENGINE = MergeTree() ORDER BY id AS SELECT id FROM {db}.events -- want to insert", [f"{db}.events"]),
                                _ch_row("sys_mv", "MaterializedView", f"CREATE MATERIALIZED VIEW {db}.sys_mv TO system.crash_log AS SELECT 1 FROM {db}.events"),
                                _ch_row(
                                    "e2e_1_events_plugin_ingestion_historical_partition_statistics_v2_mv",
                                    "MaterializedView",
                                    f"CREATE MATERIALIZED VIEW `{db}`.e2e_1_events_plugin_ingestion_historical_partition_statistics_v2_mv ON CLUSTER 'posthog' TO `{db}`.events_plugin_ingestion_partition_statistics_v2 AS SELECT 1 FROM {db}.events",
                                ),
                                _ch_row("dangling_bare_mv", "MaterializedView", f"CREATE MATERIALIZED VIEW {db}.dangling_bare_mv TO dropped_target AS SELECT 1 FROM {db}.events"),
                            ]
                        }
                    ).encode("utf-8")
                elif "infi_clickhouse_orm_migrations`" in q and q.startswith("SELECT"):
                    payload = b'{"package_name":"posthog.clickhouse.migrations","module_name":"0001_initial","applied":"2026-01-01"}\n'
                self.send_response(200)
                self.end_headers()
                self.wfile.write(payload)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        self.addCleanup(server.server_close)
        url = f"http://127.0.0.1:{server.server_address[1]}"

        with tempfile.TemporaryDirectory() as work:
            repo, snap = Path(work) / "repo", Path(work) / "snapshots"
            _seed_repo(repo)
            v1_key = "9" * 64
            lmc.publish_generation(
                snap / "ch-v1",
                "enact-live-ch-v1",
                v1_key,
                "ch26.6",
                {
                    "ddl.json": b'{"database_ddl":"CREATE DATABASE IF NOT EXISTS __ENACT_CH_DB__","statements":[]}',
                    "migrations.json": b'{"applied":[["posthog.clickhouse.migrations","0001_initial"]],"applied_jsonl":"{}"}',
                    "seed_rows.json": b"{}",
                },
            )
            self.assertIsNone(lmc.resolve_verified_generation(snap / "ch-v1", lmc.CH_FORMAT_PREFIX, v1_key, lmc.CH_REQUIRED_FILES))
            self.assertIsNone(lmc.select_ch_base(snap / "ch-v1", repo, "26.6.2"))

            key1 = lmc.compute_ch_key(repo, "26.6.2")
            err_buf = io.StringIO()
            with contextlib.redirect_stderr(err_buf):
                gen1 = lmc.capture_ch_snapshot(snap, repo, key1, "26.6.2", url, "posthog_e2e_1", "e2e_1_", "127.0.0.1:19092", "default", "")
            self.assertFalse((snap / "ch-v1" / v1_key).exists(), "retired ch-v1 entry must be pruned")
            self.assertTrue((gen1 / "manifest").read_text(encoding="utf-8").startswith(f"enact-live-ch-v2:{key1} ch26.6"))
            self.assertIn("e2e_1_events_plugin_ingestion_historical_partition_statistics_v2_mv", err_buf.getvalue())
            self.assertIn("dangling_bare_mv", err_buf.getvalue())
            ddl1 = json.loads((gen1 / "ddl.json").read_text(encoding="utf-8"))
            self.assertEqual(sorted(s["name"] for s in ddl1["statements"]), ["events", "events_valid_mv", "infi_clickhouse_orm_migrations", "inner_mv", "sys_mv"])

            (repo / "posthog/clickhouse/migrations/0003_next.py").write_text("# 3\n", encoding="utf-8")
            key2 = lmc.compute_ch_key(repo, "26.6.2")
            poisoned = {**ddl1, "statements": [*ddl1["statements"], {"name": "injected_dangling_mv", "engine": "MaterializedView", "ddl": "CREATE MATERIALIZED VIEW __ENACT_CH_DB__.injected_dangling_mv TO __ENACT_CH_DB__.missing_tbl AS SELECT 1"}]}
            lmc.publish_generation(snap / "ch-v1", lmc.CH_FORMAT_PREFIX, "8" * 64, "ch26.6", {"ddl.json": json.dumps(poisoned).encode("utf-8"), "migrations.json": (gen1 / "migrations.json").read_bytes(), "seed_rows.json": b"{}"})
            shutil.rmtree(snap / "ch-v1" / key1)
            executed.clear()
            restore_err = io.StringIO()
            with contextlib.redirect_stderr(restore_err):
                mode = lmc.restore_ch_snapshot(snap, repo, key2, "26.6.2", url, "posthog_mcp_2", "mcp_2_", "127.0.0.1:29092", "default", "")
            self.assertEqual(mode, "base")
            self.assertIn("injected_dangling_mv", restore_err.getvalue())
            self.assertFalse(any("injected_dangling_mv" in q for q in executed))
            mig_create = [q for q in executed if "CREATE TABLE posthog_mcp_2.infi_clickhouse_orm_migrations" in q][0]
            zk_match = re.search(r"'(/clickhouse/prod/tables/enactzk_[0-9a-f]{12}/noshard/posthog_mcp_2/infi_clickhouse_orm_migrations)'", mig_create)
            self.assertIsNotNone(zk_match, mig_create)
            assert zk_match is not None

            state["db"], state["zk"] = "posthog_mcp_2", zk_match.group(1)
            gen2 = lmc.capture_ch_snapshot(snap, repo, key2, "26.6.2", url, "posthog_mcp_2", "mcp_2_", "127.0.0.1:29092", "default", "")
            ddl2 = json.loads((gen2 / "ddl.json").read_text(encoding="utf-8"))
            mig_ddl2 = [s["ddl"] for s in ddl2["statements"] if s["name"] == "infi_clickhouse_orm_migrations"][0]
            self.assertIn("'/clickhouse/prod/tables/__ENACT_CH_ZK__/noshard/__ENACT_CH_DB__/infi_clickhouse_orm_migrations'", mig_ddl2)
            self.assertNotIn("enactzk_", mig_ddl2)
            self.assertNotIn("posthog_mcp_2", mig_ddl2)

    def test_live_posthog_logs_ch_restore_stderr_and_cleans_keeper_on_cold_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            repo, snap, bin_dir, logs_dir, calls = Path(work) / "repo", Path(work) / "snapshots", Path(work) / "bin", Path(work) / "logs", Path(work) / "calls.log"
            _seed_repo(repo)
            for fname in ("live_migrate_cache.py", "live_posthog.sh", "live_posthog.py"):
                (repo / "showcase/scripts" / fname).write_text((SCRIPTS / fname).read_text(encoding="utf-8"), encoding="utf-8")
            (snap / "ch-v1" / ("f" * 64)).mkdir(parents=True)
            bin_dir.mkdir()
            for name, script in (
                ("flock", "#!/usr/bin/env bash\nexit 0\n"),
                ("clickhouse-client", f'#!/usr/bin/env bash\necho "CH_CLIENT:$*" >> "{calls}"\nif [[ "$*" == *"SELECT version()"* ]]; then echo "26.6.2.158"; fi\n'),
                ("clickhouse", f'#!/usr/bin/env bash\necho "CH_BIN:$*" >> "{calls}"\n'),
                ("uv", f'#!/usr/bin/env bash\necho "UV:$*" >> "{calls}"\n'),
            ):
                p = bin_dir / name
                p.write_text(script, encoding="utf-8")
                p.chmod(0o755)
            res = subprocess.run(
                ["bash", "-euo", "pipefail", "-c", 'source showcase/scripts/live_posthog.sh && live_ch=(clickhouse-client) live_ch_db=posthog_mcp_1 live_worker=mcp_1 live_logs="$LIVE_LOGS" live_run=(env) && (live_migrate_ch || true)'],
                cwd=repo,
                env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "SNAPSHOT_ROOT": str(snap), "LIVE_LOGS": str(logs_dir), "CLICKHOUSE_HTTP_PORT": "9", "KAFKA_HOSTS": "127.0.0.1:19092", "ENVE_SERVICE_CLICKHOUSE_PORT_KEEPER": "29181"},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn("ch-restore.log", res.stderr)
            self.assertIn("ch-restore miss/error:", (logs_dir / "ch-restore.log").read_text(encoding="utf-8"))
            recorded = calls.read_text(encoding="utf-8").splitlines()
            drop_idx = next(i for i, l in enumerate(recorded) if "DROP DATABASE IF EXISTS posthog_mcp_1 SYNC" in l)
            keeper_idx = next(i for i, l in enumerate(recorded) if "keeper-client --port 29181 -q rmr /clickhouse/prod/tables/noshard/posthog_mcp_1" in l)
            mig_idx = next(i for i, l in enumerate(recorded) if "manage.py migrate_clickhouse" in l)
            self.assertLess(drop_idx, keeper_idx)
            self.assertLess(keeper_idx, mig_idx)


@unittest.skipUnless(_live_ch_http_url() is not None, "needs live ClickHouse HTTP service (CLICKHOUSE_HTTP_PORT)")
class LiveClickHouseSnapshotServiceTest(unittest.TestCase):
    def test_live_clickhouse_replicated_keeper_and_dangling_mv_snapshot_roundtrip(self) -> None:
        url = _live_ch_http_url()
        assert url is not None
        user = os.environ.get("CLICKHOUSE_USER", "default")
        pw = os.environ.get("CLICKHOUSE_PASSWORD", "")
        ver = lmc.ch_http_query(url, "SELECT version()", user=user, password=pw).decode("utf-8").strip()
        tag = uuid.uuid4().hex[:8]
        src_db = f"posthog_probe_src_{tag}"
        dst_db = f"posthog_probe_dst_{tag}"
        self.addCleanup(lambda: lmc.ch_http_query(url, f"DROP DATABASE IF EXISTS `{src_db}` SYNC", user=user, password=pw))
        self.addCleanup(lambda: lmc.ch_http_query(url, f"DROP DATABASE IF EXISTS `{dst_db}` SYNC", user=user, password=pw))

        lmc.ch_http_query(url, f"CREATE DATABASE `{src_db}`", user=user, password=pw)
        lmc.ch_http_query(
            url,
            f"CREATE TABLE `{src_db}`.`infi_clickhouse_orm_migrations` "
            "(`package_name` String, `module_name` String, `applied` Date) "
            "ENGINE = ReplicatedMergeTree('/clickhouse/prod/tables/noshard/{database}/{table}', '{replica}-{shard}') "
            "ORDER BY (package_name, module_name)",
            user=user,
            password=pw,
        )
        lmc.ch_http_query(
            url,
            f"INSERT INTO `{src_db}`.`infi_clickhouse_orm_migrations` VALUES ('posthog.clickhouse.migrations', '0001_initial', '2026-01-01')",
            user=user,
            password=pw,
        )
        lmc.ch_http_query(url, f"CREATE TABLE `{src_db}`.`events` (`id` UInt64) ENGINE = MergeTree() ORDER BY id", user=user, password=pw)
        lmc.ch_http_query(url, f"CREATE TABLE `{src_db}`.`gone_stats` (`id` UInt64) ENGINE = MergeTree() ORDER BY id", user=user, password=pw)
        lmc.ch_http_query(
            url,
            f"CREATE MATERIALIZED VIEW `{src_db}`.`src_events_mv` TO `{src_db}`.`events` AS SELECT id FROM `{src_db}`.`events`",
            user=user,
            password=pw,
        )
        lmc.ch_http_query(
            url,
            f"CREATE MATERIALIZED VIEW `{src_db}`.`src_dangling_mv` TO `{src_db}`.`gone_stats` AS SELECT id FROM `{src_db}`.`events`",
            user=user,
            password=pw,
        )
        lmc.ch_http_query(url, f"DROP TABLE `{src_db}`.`gone_stats` SYNC", user=user, password=pw)

        with tempfile.TemporaryDirectory() as work:
            repo = Path(work) / "repo"
            snap = Path(work) / "snapshots"
            _seed_repo(repo)
            key = lmc.compute_ch_key(repo, ver)
            lmc.capture_ch_snapshot(snap, repo, key, ver, url, src_db, "src_", "127.0.0.1:19092", user, pw)
            mode = lmc.restore_ch_snapshot(snap, repo, key, ver, url, dst_db, "dst_", "127.0.0.1:19092", user, pw)
            self.assertEqual(mode, "exact")
            tables = {
                r["name"]
                for r in lmc.ch_http_json_rows(
                    url, f"SELECT name FROM system.tables WHERE database = '{dst_db}'", user=user, password=pw
                )
            }
            self.assertIn("infi_clickhouse_orm_migrations", tables)
            self.assertIn("dst_events_mv", tables)
            self.assertNotIn("dst_dangling_mv", tables)


if __name__ == "__main__":
    unittest.main()
