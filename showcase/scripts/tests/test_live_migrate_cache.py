"""Unit tests for live Postgres & ClickHouse migration snapshot cache helpers."""

from __future__ import annotations

import hashlib
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
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
            zk_prefix="posthog_mcp_1_deadbeef",
        )
        self.assertIn("CREATE TABLE posthog_mcp_1.events (`uuid` UUID)", rehydrated)
        self.assertIn("'/clickhouse/tables/posthog_mcp_1_deadbeef/noshard/posthog.events'", rehydrated)
        self.assertIn("kafka_broker_list = '127.0.0.1:29092'", rehydrated)
        self.assertIn("kafka_topic_list = 'mcp_1_events_json'", rehydrated)

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


if __name__ == "__main__":
    unittest.main()
