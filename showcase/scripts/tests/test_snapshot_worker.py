"""A snapshot recorded upstream matches the SQL a shard prints (pytest_snapshot_worker.py).

The shards share one ClickHouse, each in posthog_test_<worker>, and printed SQL names its
dictionaries by database: web_analytics' and marketing_analytics' channel-type snapshots
failed on `posthog_test_shard6.channel_definition_dict` against upstream's
`posthog_test.channel_definition_dict`, revenue analytics' on the quoted
`` `posthog_test_shard8`.`exchange_rate_dict` ``, and dags' deletes on a list of statements.
The Kafka tables' topics and groups carry the worker as a suffix, and the one Kafka table not on a
named collection prints the run's broker where upstream's says `kafka:9092` (test_schema's snapshots).
Revenue analytics' warehouse tables print the bucket at the run's object store and a folder with
the worker's suffix, where upstream's say `host.docker.internal:19000` and no suffix, and a
cluster query's failure names the run's ClickHouse where upstream's says `clickhouse:9000`.
Runs a real pytest and syrupy session (the backend environment's); skipped without them.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PLUGINS = Path(__file__).resolve().parents[2] / "pytest_plugins"

TEST = '''
import os

def test_channel_sql(snapshot):
    database = os.environ.get("CLICKHOUSE_DATABASE", "posthog_test")
    assert (
        f"SELECT dictGetOrNull('{database}.channel_definition_dict', 'type_if_paid', x), "
        f"dictGetOrDefault(`{database}`.`exchange_rate_dict`, 'rate', 'USD')"
    ) == snapshot


def test_captured_statements(snapshot):
    database = os.environ.get("CLICKHOUSE_DATABASE", "posthog_test")
    assert [f"DELETE FROM {database}.sharded_events IN PARTITION '202408'"] == snapshot


def test_kafka_table(snapshot):
    # The worker whose topic and group this shard prints (another's, in a test).
    worker = os.environ.get("PRINTED_WORKER", os.environ.get("PYTEST_XDIST_WORKER"))
    suffix = f"_{worker}" if worker else ""
    assert (
        f"Kafka(msk_cluster, kafka_topic_list = 'events_dead_letter_queue_test{suffix}', "
        f"kafka_group_name = 'group1{suffix}', kafka_format = 'JSONEachRow')"
    ) == snapshot


def test_kafka_hosts(snapshot):
    hosts = os.environ.get("PRINTED_HOSTS", os.environ.get("KAFKA_HOSTS", "kafka:9092"))
    assert f"ENGINE = Kafka('{hosts}', 'clickhouse_person_override_test')" == snapshot


def test_str_enums(snapshot):
    from enum import StrEnum

    class QueryIndexUsage(StrEnum):
        YES = "yes"

    assert QueryIndexUsage.YES == snapshot
    assert [QueryIndexUsage.YES] == snapshot


def test_cluster_host(snapshot):
    port = os.environ.get("PRINTED_PORT", os.environ.get("CLICKHOUSE_TCP_PORT", "9000"))
    host = "127.0.0.1" if "CLICKHOUSE_TCP_PORT" in os.environ else "clickhouse"
    assert f"* HostInfo(connection_info=ConnectionInfo(host='{host}', port={port}), shard_num=1)" == snapshot


def test_warehouse_bucket(snapshot):
    domain = os.environ.get("PRINTED_DOMAIN", os.environ.get("DATAWAREHOUSE_BUCKET_DOMAIN", "host.docker.internal:19000"))
    worker = os.environ.get("PRINTED_WORKER", os.environ.get("PYTEST_XDIST_WORKER"))
    suffix = f"_{worker}" if worker else ""
    assert f"FROM s3('http://{domain}/posthog/test_storage_bucket-stripe{suffix}/customer/*.csv', 'CSVWithNames')" == snapshot
'''


@unittest.skipUnless(
    importlib.util.find_spec("pytest") and importlib.util.find_spec("syrupy"), "needs pytest and syrupy"
)
class SnapshotWorkerTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        (self.dir / "pytest.ini").write_text("[pytest]\n")
        (self.dir / "test_sql.py").write_text(TEST)
        # Recorded as upstream records it: its own ClickHouse, posthog_test, no worker.
        self.assertEqual(0, self.pytest({}, "--snapshot-update").returncode)

    def pytest(self, env: dict[str, str], *args: str) -> subprocess.CompletedProcess:
        base = {k: v for k, v in os.environ.items() if k not in ("PYTEST_XDIST_WORKER", "CLICKHOUSE_DATABASE", "PRINTED_WORKER", "KAFKA_HOSTS", "PRINTED_HOSTS", "DATAWAREHOUSE_BUCKET_DOMAIN", "PRINTED_DOMAIN", "CLICKHOUSE_TCP_PORT", "CLICKHOUSE_HOST", "CLICKHOUSE_TEST_CLUSTER_HOST", "PRINTED_PORT")}
        return subprocess.run(
            [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "-p", "syrupy",
             "-p", "pytest_snapshot_worker", *args, "test_sql.py"],
            cwd=self.dir,
            env={**base, "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1", "PYTHONPATH": str(PLUGINS), **env},
            capture_output=True,
            text=True,
        )

    def shard(self, worker: str, database: str) -> subprocess.CompletedProcess:
        return self.pytest({"PYTEST_XDIST_WORKER": worker, "CLICKHOUSE_DATABASE": database})

    def test_a_shards_sql_matches_the_upstream_snapshot(self) -> None:
        done = self.shard("shard6", "posthog_test_shard6")
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)

    def test_only_this_workers_database_is_renamed(self) -> None:
        # shard7 prints shard6's database: a real difference, still reported.
        self.assertNotEqual(0, self.shard("shard7", "posthog_test_shard6").returncode)
        # A prefix of another worker's name is not this worker's database.
        self.assertNotEqual(0, self.shard("shard1", "posthog_test_shard10").returncode)

    def test_another_workers_kafka_names_are_reported(self) -> None:
        # shard1 prints shard10's topic and group: not its own suffix, still reported.
        done = self.pytest({"PYTEST_XDIST_WORKER": "shard1", "PRINTED_WORKER": "shard10"}, "-k", "kafka_table")
        self.assertNotEqual(0, done.returncode)
        done = self.pytest({"PYTEST_XDIST_WORKER": "shard1"}, "-k", "kafka_table")
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)

    def test_the_runs_broker_is_upstreams(self) -> None:
        # Upstream's DDL names CI's broker; the run's own, on its port, is the same broker.
        done = self.pytest({"KAFKA_HOSTS": "127.0.0.1:23549"}, "-k", "kafka_hosts")
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)
        # Another broker than the run's is a real difference, still reported.
        done = self.pytest({"KAFKA_HOSTS": "127.0.0.1:23549", "PRINTED_HOSTS": "127.0.0.1:9"}, "-k", "kafka_hosts")
        self.assertNotEqual(0, done.returncode)

    def test_the_runs_clickhouse_is_upstreams_cluster_host(self) -> None:
        own = {"CLICKHOUSE_TEST_CLUSTER_HOST": "127.0.0.1", "CLICKHOUSE_TCP_PORT": "25313"}
        done = self.pytest(own, "-k", "cluster_host")
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)
        # Another port than the run's is a real difference, still reported.
        done = self.pytest({**own, "PRINTED_PORT": "9"}, "-k", "cluster_host")
        self.assertNotEqual(0, done.returncode)

    def test_a_str_enum_is_compared_as_itself(self) -> None:
        # syrupy prints a StrEnum by its type (test_explain's QueryIndexUsage); a plain str of its
        # value is a different snapshot, so a worker's run must not turn one into the other.
        done = self.pytest({"PYTEST_XDIST_WORKER": "shard2"}, "-k", "str_enums")
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)

    def test_the_runs_bucket_is_upstreams(self) -> None:
        # The run's object store and this worker's folder are upstream's Docker host and folder.
        own = {"PYTEST_XDIST_WORKER": "base_test_shard2", "DATAWAREHOUSE_BUCKET_DOMAIN": "127.0.0.1:25879"}
        done = self.pytest(own, "-k", "warehouse_bucket")
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)
        # Another store, or another worker's folder, is a real difference, still reported.
        done = self.pytest({**own, "PRINTED_DOMAIN": "127.0.0.1:9"}, "-k", "warehouse_bucket")
        self.assertNotEqual(0, done.returncode)
        done = self.pytest({**own, "PRINTED_WORKER": "base_test_shard3"}, "-k", "warehouse_bucket")
        self.assertNotEqual(0, done.returncode)


QUEUES = """
import os

import pytest

QUEUE = "development-task-queue" + (f"_{os.environ['PYTEST_XDIST_WORKER']}" if os.environ.get("PYTEST_XDIST_WORKER") else "")


@pytest.mark.parametrize("queue,other", [(QUEUE, "plain"), ("caf\\u00e9", "x_shard10")])
def test_queue(queue, other):
    pass
"""


@unittest.skipUnless(importlib.util.find_spec("pytest"), "needs pytest")
class StableIdsTest(unittest.TestCase):
    """A parameter holding a worker's own queue name is named as upstream's: the ids a shard
    records are every shard's (test_start_temporal_worker's ids carried
    `development-task-queue_base_test_shard4`, which shard 1 couldn't find)."""

    def collect(self, worker: str | None) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "pytest.ini").write_text("[pytest]\n")
            (Path(tmp) / "test_queues.py").write_text(QUEUES)
            env = {k: v for k, v in os.environ.items() if k != "PYTEST_XDIST_WORKER"}
            if worker:
                env["PYTEST_XDIST_WORKER"] = worker
            done = subprocess.run(
                [sys.executable, "-m", "pytest", "--collect-only", "-q", "-p", "no:cacheprovider",
                 "-p", "pytest_snapshot_worker", "test_queues.py"],
                cwd=tmp,
                env={**env, "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1", "PYTHONPATH": str(PLUGINS)},
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, done.returncode, done.stdout + done.stderr)
            return [line for line in done.stdout.splitlines() if "::" in line]

    def test_every_shard_records_upstreams_ids(self) -> None:
        upstream = self.collect(None)
        self.assertEqual(
            ["test_queues.py::test_queue[development-task-queue-plain]", "test_queues.py::test_queue[caf\\xe9-x_shard10]"],
            upstream,
        )
        self.assertEqual(upstream, self.collect("base_test_shard4"))
        self.assertEqual(upstream, self.collect("shard1"), "shard10's suffix isn't shard1's")


class RuntimeHooksTest(unittest.TestCase):
    """Unit tests for the runtime hooks in pytest_snapshot_worker that replace patches
    0011, 0012, 0015, 0016, and 0018."""

    @classmethod
    def setUpClass(cls) -> None:
        if str(PLUGINS) not in sys.path:
            sys.path.insert(0, str(PLUGINS))
        import pytest_snapshot_worker

        cls.plugin = pytest_snapshot_worker

    def test_warehouse_table_url_rewrites_host_docker_internal(self) -> None:
        from types import ModuleType, SimpleNamespace
        from unittest.mock import patch

        django_mod = ModuleType("django")
        conf_mod = ModuleType("django.conf")
        conf_mod.settings = SimpleNamespace(DATAWAREHOUSE_BUCKET_DOMAIN="127.0.0.1:29000")
        django_mod.conf = conf_mod

        class DataWarehouseTable:
            pass

        class OtherModel:
            pass

        instance = SimpleNamespace(url_pattern="http://host.docker.internal:19000/test/*.parquet")
        other = SimpleNamespace(url_pattern="http://host.docker.internal:19000/test/*.parquet")
        with patch.dict(sys.modules, {"django": django_mod, "django.conf": conf_mod}):
            self.plugin._rewrite_warehouse_table_url(DataWarehouseTable, instance)
            self.plugin._rewrite_warehouse_table_url(OtherModel, other)
        self.assertEqual("http://127.0.0.1:29000/test/*.parquet", instance.url_pattern)
        self.assertEqual("http://host.docker.internal:19000/test/*.parquet", other.url_pattern)

    def test_postgres_config_fixture_suffixes_exports_test_database(self) -> None:
        from types import ModuleType, SimpleNamespace
        from unittest.mock import patch

        django_mod = ModuleType("django")
        conf_mod = ModuleType("django.conf")
        conf_mod.settings = SimpleNamespace(XDIST_SUFFIX="_shard3")
        django_mod.conf = conf_mod

        res = {"database": "exports_test_database", "host": "127.0.0.1"}
        fixturedef = SimpleNamespace(argname="postgres_config")
        outcome = SimpleNamespace(get_result=lambda: res)
        with patch.dict(sys.modules, {"django": django_mod, "django.conf": conf_mod}):
            gen = self.plugin.pytest_fixture_setup(fixturedef, None)
            next(gen)
            with self.assertRaises(StopIteration):
                gen.send(outcome)
        self.assertEqual("exports_test_database_shard3", res["database"])

    def test_collection_modifyitems_skips_platform_bound_tests(self) -> None:
        from types import SimpleNamespace
        from unittest.mock import patch

        class FakeItem:
            def __init__(self, name: str, nodeid: str) -> None:
                self.name = name
                self.nodeid = nodeid
                self.markers: list[str] = []

            def add_marker(self, marker: str) -> None:
                self.markers.append(marker)

        fake_pytest = SimpleNamespace(mark=SimpleNamespace(skip=lambda reason: f"skip:{reason}"))
        items = [
            FakeItem("test_exception_summary", "posthog/clickhouse/test/test_cluster.py::test_exception_summary"),
            FakeItem(
                "test_executable_overrides_binary",
                "posthog/security/test/test_command_exec_audit.py::test_executable_overrides_binary",
            ),
            FakeItem("test_other", "posthog/clickhouse/test/test_cluster.py::test_other"),
        ]
        with (
            patch.object(self.plugin, "pytest", fake_pytest),
            patch.object(sys, "platform", "darwin"),
            patch("shutil.which", return_value="/nix/store/xxx/bin/true"),
            patch("os.path.realpath", return_value="/nix/store/xxx/bin/coreutils"),
        ):
            self.plugin.pytest_collection_modifyitems(None, items)
        self.assertEqual(["skip:ClickHouse stack frames are Linux build's"], items[0].markers)
        self.assertEqual(["skip:true is a multicall coreutils binary"], items[1].markers)
        self.assertEqual([], items[2].markers)

    def test_runtest_teardown_cleans_up_materialized_columns(self) -> None:
        from types import ModuleType, SimpleNamespace
        from unittest.mock import patch

        calls: list[str] = []
        base_mod = ModuleType("posthog.test.base")
        base_mod.cleanup_materialized_columns = lambda: calls.append("cleaned")
        posthog_mod = ModuleType("posthog")
        test_mod = ModuleType("posthog.test")
        with patch.dict(
            sys.modules,
            {"posthog": posthog_mod, "posthog.test": test_mod, "posthog.test.base": base_mod},
        ):
            self.plugin.pytest_runtest_teardown(SimpleNamespace(name="test_other"))
            self.assertEqual([], calls)
            self.plugin.pytest_runtest_teardown(
                SimpleNamespace(name="test_compile_hogql_predicate_emits_unqualified_materialized_column")
            )
            self.assertEqual(["cleaned"], calls)

    def test_sessionfinish_cleans_materialized_columns_only_when_clickhouse_events_exist(self) -> None:
        import json
        from types import ModuleType, SimpleNamespace
        from unittest.mock import patch

        executed: list[str] = []
        table_count = [1]
        columns: dict[str, set[str]] = {
            "events": {"mat_$current_url"},
            "sharded_events": {"mat_$current_url"},
            "person": {"pmat_default"},
            "groups": set(),
        }
        skip_indexes: dict[str, list[tuple[str, str]]] = {
            "sharded_events": [],
            "person": [],
            "groups": [],
        }

        def fake_sync_execute(sql: str, params=None):
            if params is not None:
                # Match clickhouse_driver's `%`-formatting (`query % params`): any unescaped `%`
                # (such as `LIKE 'mat\_%'`) must fail here instead of silently breaking in CI.
                sql = sql % params
            executed.append(sql)
            if "FROM system.tables" in sql:
                return [(table_count[0],)]
            if "FROM system.columns" in sql:
                return [
                    (tbl, col)
                    for tbl in ("events", "sharded_events", "person", "groups")
                    for col in sorted(columns[tbl])
                ]
            if "FROM system.data_skipping_indices" in sql:
                if "SELECT table, name, expr" in sql:
                    return [
                        (tbl, name, expr)
                        for tbl in ("sharded_events", "person", "groups")
                        for name, expr in sorted(skip_indexes.get(tbl, []))
                    ]
                return list(skip_indexes.get(params["tbl"], []))
            if "DROP INDEX IF EXISTS" in sql:
                for tbl in skip_indexes:
                    if f".`{tbl}`" in sql:
                        skip_indexes[tbl] = [(n, e) for n, e in skip_indexes[tbl] if f"`{n}`" not in sql]
                return []
            if "DROP COLUMN IF EXISTS" in sql:
                for tbl in columns:
                    if f".`{tbl}`" in sql:
                        for col in list(columns[tbl]):
                            if f"`{col}`" in sql:
                                columns[tbl].remove(col)
                return []
            return []

        client_mod = ModuleType("posthog.clickhouse.client")
        client_mod.sync_execute = fake_sync_execute
        posthog_mod = ModuleType("posthog")
        clickhouse_mod = ModuleType("posthog.clickhouse")
        clickhouse_mod.client = client_mod
        posthog_mod.clickhouse = clickhouse_mod

        with tempfile.TemporaryDirectory() as tmp:
            baseline_file = Path(tmp) / "ch-mat-baseline-w1.json"

            # (1) Pure non-DB test (no baseline file, client not imported): zero queries on finish.
            with patch.dict(
                os.environ,
                {"CLICKHOUSE_DATABASE": "posthog_test_w1", "ENACT_CH_MAT_BASELINE_FILE": str(baseline_file)},
            ):
                sys.modules.pop("posthog.clickhouse.client", None)
                self.plugin.pytest_sessionfinish(None, 0)
            self.assertEqual([], executed)
            self.assertFalse(baseline_file.exists())

            mods = {
                "posthog": posthog_mod,
                "posthog.clickhouse": clickhouse_mod,
                "posthog.clickhouse.client": client_mod,
            }
            # (2) First DB-using process (`django_db_setup`): captures baseline ONCE, drops nothing.
            with (
                patch.dict(sys.modules, mods),
                patch.dict(
                    os.environ,
                    {"CLICKHOUSE_DATABASE": "posthog_test_w1", "ENACT_CH_MAT_BASELINE_FILE": str(baseline_file)},
                ),
            ):
                gen = self.plugin.pytest_fixture_setup(SimpleNamespace(argname="django_db_setup"), None)
                next(gen)
                with self.assertRaises(StopIteration):
                    gen.send(SimpleNamespace(get_result=lambda: None))
            self.assertTrue(baseline_file.is_file())
            saved = json.loads(baseline_file.read_text())
            self.assertEqual("posthog_test_w1", saved["database"])
            self.assertEqual(["mat_$current_url"], saved["columns"]["events"])
            self.assertEqual(["pmat_default"], saved["columns"]["person"])

            # (3) Simulate SIGKILL/OOM writer leak (`sessionfinish` skipped!): next process's
            #     `django_db_setup` drops leaked columns + skip index while preserving baseline defaults.
            columns["events"].add("mat_$exception_issue_id")
            columns["sharded_events"].add("mat_$exception_issue_id")
            columns["person"].add("pmat_leaked")
            skip_indexes["sharded_events"].append(("idx_exception_issue_id", "mat_$exception_issue_id"))

            with (
                patch.dict(sys.modules, mods),
                patch.dict(
                    os.environ,
                    {"CLICKHOUSE_DATABASE": "posthog_test_w1", "ENACT_CH_MAT_BASELINE_FILE": str(baseline_file)},
                ),
            ):
                gen = self.plugin.pytest_fixture_setup(SimpleNamespace(argname="django_db_setup"), None)
                next(gen)
                with self.assertRaises(StopIteration):
                    gen.send(SimpleNamespace(get_result=lambda: None))
            self.assertEqual({"mat_$current_url"}, columns["events"])
            self.assertEqual({"mat_$current_url"}, columns["sharded_events"])
            self.assertEqual({"pmat_default"}, columns["person"])
            self.assertEqual([], skip_indexes["sharded_events"])

            # (4) Normal `pytest_sessionfinish` drops any columns leaked during the process.
            columns["events"].add("mat_$other_leak")
            with (
                patch.dict(sys.modules, mods),
                patch.dict(
                    os.environ,
                    {"CLICKHOUSE_DATABASE": "posthog_test_w1", "ENACT_CH_MAT_BASELINE_FILE": str(baseline_file)},
                ),
            ):
                self.plugin.pytest_sessionfinish(None, 0)
            self.assertEqual({"mat_$current_url"}, columns["events"])

            # (5) Inter-product CLI cleanup (`clickhouse-client` path) also drops leaked columns.
            columns["events"].add("mat_$cli_leak")

            def fake_run(cmd, **_kwargs):
                sql = cmd[-1]
                rows = fake_sync_execute(sql, {"tbl": "sharded_events"} if "sharded_events" in sql else {"tbl": "person"})
                out = "\n".join("\t".join(str(x) for x in r) for r in rows)
                return SimpleNamespace(stdout=out, returncode=0)

            with (
                patch.object(subprocess, "run", side_effect=fake_run),
                patch.dict(os.environ, {"CLICKHOUSE_TCP_PORT": "9000"}),
            ):
                dropped = self.plugin.cleanup_clickhouse_via_cli("posthog_test_w1", str(baseline_file))
            self.assertEqual(1, dropped)
            self.assertEqual({"mat_$current_url"}, columns["events"])

            # (6) Errors are caught so test exit status is never masked.
            client_mod.sync_execute = lambda *_a, **_kw: (_ for _ in ()).throw(RuntimeError("ch down"))
            with (
                patch.dict(sys.modules, mods),
                patch.dict(
                    os.environ,
                    {"CLICKHOUSE_DATABASE": "posthog_test_w1", "ENACT_CH_MAT_BASELINE_FILE": str(baseline_file)},
                ),
            ):
                self.plugin.pytest_sessionfinish(None, 0)

    def test_skip_index_cleanup_preserves_prefix_siblings_and_drops_writer_indexes(self) -> None:
        import json
        from types import ModuleType, SimpleNamespace
        from unittest.mock import patch

        columns: dict[str, set[str]] = {
            "events": {"mat_foo_long", "mat_$browser_version"},
            "sharded_events": {"mat_foo_long", "mat_$browser_version"},
            "person": set(),
            "groups": set(),
        }
        skip_indexes: dict[str, list[tuple[str, str]]] = {
            "sharded_events": [
                ("idx_kept", "lower(mat_foo_long)"),
                ("bloom_filter_mat_$browser_version", "`mat_$browser_version`"),
            ],
            "person": [],
            "groups": [],
        }

        def fake_sync_execute(sql: str, params=None):
            if params is not None:
                sql = sql % params
            if "FROM system.tables" in sql:
                return [(1,)]
            if "FROM system.columns" in sql:
                return [
                    (tbl, col)
                    for tbl in ("events", "sharded_events", "person", "groups")
                    for col in sorted(columns[tbl])
                ]
            if "FROM system.data_skipping_indices" in sql:
                if "SELECT table, name, expr" in sql:
                    return [
                        (tbl, name, expr)
                        for tbl in ("sharded_events", "person", "groups")
                        for name, expr in sorted(skip_indexes.get(tbl, []))
                    ]
                return list(skip_indexes.get(params["tbl"], []))
            if "DROP INDEX IF EXISTS" in sql:
                for tbl in skip_indexes:
                    if f".`{tbl}`" in sql:
                        skip_indexes[tbl] = [(n, e) for n, e in skip_indexes[tbl] if f"`{n}`" not in sql]
                return []
            if "DROP COLUMN IF EXISTS" in sql:
                for tbl in columns:
                    if f".`{tbl}`" in sql:
                        for col in list(columns[tbl]):
                            if f"`{col}`" in sql:
                                columns[tbl].remove(col)
                return []
            return []

        client_mod = ModuleType("posthog.clickhouse.client")
        client_mod.sync_execute = fake_sync_execute
        posthog_mod = ModuleType("posthog")
        clickhouse_mod = ModuleType("posthog.clickhouse")
        clickhouse_mod.client = client_mod
        posthog_mod.clickhouse = clickhouse_mod
        mods = {
            "posthog": posthog_mod,
            "posthog.clickhouse": clickhouse_mod,
            "posthog.clickhouse.client": client_mod,
        }

        with tempfile.TemporaryDirectory() as tmp:
            baseline_file = Path(tmp) / "ch-mat-baseline-prefix.json"
            env = {
                "CLICKHOUSE_DATABASE": "posthog_test_prefix",
                "ENACT_CH_MAT_BASELINE_FILE": str(baseline_file),
            }
            with patch.dict(sys.modules, mods), patch.dict(os.environ, env):
                # Capture baseline columns + baseline skip indexes once at start.
                gen = self.plugin.pytest_fixture_setup(SimpleNamespace(argname="django_db_setup"), None)
                next(gen)
                with self.assertRaises(StopIteration):
                    gen.send(SimpleNamespace(get_result=lambda: None))
                saved = json.loads(baseline_file.read_text())
                baseline_idx_snapshot = list(skip_indexes["sharded_events"])
                self.assertEqual(
                    [
                        ["sharded_events", "bloom_filter_mat_$browser_version", "`mat_$browser_version`"],
                        ["sharded_events", "idx_kept", "lower(mat_foo_long)"],
                    ],
                    saved["indexes"],
                )

                # (1) Prefix collision: writer leaks `mat_foo` beside baseline `mat_foo_long` (`idx_kept`).
                columns["events"].add("mat_foo")
                columns["sharded_events"].add("mat_foo")
                self.plugin.pytest_sessionfinish(None, 0)
                self.assertEqual({"mat_foo_long", "mat_$browser_version"}, columns["events"])
                self.assertEqual({"mat_foo_long", "mat_$browser_version"}, columns["sharded_events"])
                self.assertEqual(baseline_idx_snapshot, skip_indexes["sharded_events"])

                # (2) Real PostHog pair: writer leaks `mat_$browser` beside baseline `mat_$browser_version`.
                columns["events"].add("mat_$browser")
                columns["sharded_events"].add("mat_$browser")
                # Also simulate a non-baseline sibling index on `mat_$browser_version` to prove whole-token matching.
                skip_indexes["sharded_events"].append(("idx_extra_bv", "lower(mat_$browser_version)"))
                self.plugin.pytest_sessionfinish(None, 0)
                self.assertEqual({"mat_foo_long", "mat_$browser_version"}, columns["events"])
                self.assertIn(("bloom_filter_mat_$browser_version", "`mat_$browser_version`"), skip_indexes["sharded_events"])
                self.assertIn(("idx_extra_bv", "lower(mat_$browser_version)"), skip_indexes["sharded_events"])
                skip_indexes["sharded_events"].remove(("idx_extra_bv", "lower(mat_$browser_version)"))

                # (3) Writer-created indexes on a leaked column are dropped cleanly while baseline indexes stay intact.
                columns["events"].add("mat_$exception_issue_id")
                columns["sharded_events"].add("mat_$exception_issue_id")
                skip_indexes["sharded_events"].append(
                    ("bloom_filter_mat_$exception_issue_id", "lower(`mat_$exception_issue_id`)")
                )
                skip_indexes["sharded_events"].append(("idx_custom_ex", "lower(mat_$exception_issue_id)"))
                self.plugin.pytest_sessionfinish(None, 0)
                self.assertEqual({"mat_foo_long", "mat_$browser_version"}, columns["events"])
                self.assertEqual({"mat_foo_long", "mat_$browser_version"}, columns["sharded_events"])
                self.assertEqual(baseline_idx_snapshot, skip_indexes["sharded_events"])

    def test_temporal_list_workflows_strips_order_by_and_sorts_by_start_time(self) -> None:
        import asyncio
        from types import SimpleNamespace

        recorded_queries: list[str | None] = []

        class FakeClient:
            def list_workflows(self, query: str | None = None):
                recorded_queries.append(query)

                async def _iter():
                    yield SimpleNamespace(id="w2", start_time=20)
                    yield SimpleNamespace(id="w1", start_time=10)
                    yield SimpleNamespace(id="w3", start_time=30)

                return _iter()

        FakeClient.list_workflows = self.plugin._wrap_list_workflows(FakeClient.list_workflows)
        client = FakeClient()

        async def _run():
            q = 'TemporalScheduledById="sched-1" order by StartTime asc'
            return [w.id async for w in client.list_workflows(query=q)]

        ids = asyncio.run(_run())
        self.assertEqual(["w1", "w2", "w3"], ids)
        self.assertEqual(['TemporalScheduledById="sched-1"'], recorded_queries)

    def test_materialized_column_sync_percent_formatting_and_stderr_diagnostics(self) -> None:
        import io
        from contextlib import redirect_stderr
        from types import ModuleType, SimpleNamespace
        from unittest.mock import patch

        columns: dict[str, set[str]] = {
            "events": {"dmat_string_0"},
            "sharded_events": {"dmat_string_0"},
            "person": set(),
            "groups": set(),
        }
        cache_clears: list[str] = []

        def fake_sync_execute(sql: str, params=None):
            if params is not None:
                sql = sql % params
            if "FROM system.tables" in sql:
                return [(1,)]
            if "FROM system.columns" in sql:
                return [
                    (tbl, col)
                    for tbl in ("events", "sharded_events", "person", "groups")
                    for col in sorted(columns[tbl])
                ]
            if "FROM system.data_skipping_indices" in sql:
                return []
            if "DROP COLUMN IF EXISTS" in sql:
                for tbl in columns:
                    if f".`{tbl}`" in sql:
                        for col in list(columns[tbl]):
                            if f"`{col}`" in sql:
                                columns[tbl].remove(col)
                return []
            return []

        client_mod = ModuleType("posthog.clickhouse.client")
        client_mod.sync_execute = fake_sync_execute
        posthog_mod = ModuleType("posthog")
        clickhouse_mod = ModuleType("posthog.clickhouse")
        clickhouse_mod.client = client_mod
        posthog_mod.clickhouse = clickhouse_mod

        ee_mod = ModuleType("ee")
        ee_ch_mod = ModuleType("ee.clickhouse")
        ee_mat_mod = ModuleType("ee.clickhouse.materialized_columns")
        ee_cols_mod = ModuleType("ee.clickhouse.materialized_columns.columns")
        ee_cols_mod.MATERIALIZATION_VALID_TABLES = ("events", "person", "groups")
        ee_cols_mod._clear_materialized_columns_cache = lambda tbl: cache_clears.append(tbl)

        mods = {
            "posthog": posthog_mod,
            "posthog.clickhouse": clickhouse_mod,
            "posthog.clickhouse.client": client_mod,
            "ee": ee_mod,
            "ee.clickhouse": ee_ch_mod,
            "ee.clickhouse.materialized_columns": ee_mat_mod,
            "ee.clickhouse.materialized_columns.columns": ee_cols_mod,
        }

        with tempfile.TemporaryDirectory() as tmp:
            baseline_file = Path(tmp) / "ch-mat-baseline-s57.json"
            env = {
                "CLICKHOUSE_DATABASE": "posthog_test_products_test_shard6",
                "ENACT_CH_MAT_BASELINE_FILE": str(baseline_file),
            }

            # (1) Skip when CLICKHOUSE_DATABASE is unset emits explicit stderr line.
            buf = io.StringIO()
            with patch.dict(os.environ, {}, clear=False), redirect_stderr(buf):
                os.environ.pop("CLICKHOUSE_DATABASE", None)
                self.plugin._sync_materialized_columns_via_django("start")
            self.assertIn("CLICKHOUSE_DATABASE not set", buf.getvalue())

            with patch.dict(sys.modules, mods), patch.dict(os.environ, env):
                # (2) Baseline capture on start succeeds under `%`-formatting and logs capture line.
                buf = io.StringIO()
                with redirect_stderr(buf):
                    self.plugin._sync_materialized_columns_via_django("start")
                self.assertTrue(baseline_file.is_file())
                self.assertIn("captured ClickHouse baseline", buf.getvalue())

                # (3) Writer leaks mat_$exception_issue_id; finish drops it and logs drop line.
                columns["events"].add("mat_$exception_issue_id")
                columns["sharded_events"].add("mat_$exception_issue_id")
                buf = io.StringIO()
                with redirect_stderr(buf):
                    self.plugin._sync_materialized_columns_via_django("finish")
                self.assertIn("dropped 2 leaked materialized column(s)", buf.getvalue())
                self.assertIn("events.mat_$exception_issue_id", buf.getvalue())
                self.assertEqual({"dmat_string_0"}, columns["events"])
                self.assertEqual({"dmat_string_0"}, columns["sharded_events"])

                # (4) Observer start with 0 leaked columns logs clean AND still clears Redis mat cache.
                cache_clears.clear()
                buf = io.StringIO()
                with redirect_stderr(buf):
                    self.plugin._sync_materialized_columns_via_django("start")
                self.assertIn("materialized-column sync clean", buf.getvalue())
                self.assertEqual(["events", "person", "groups"], cache_clears)

            # (5) CLI cleanup skip diagnostics (missing baseline / missing port).
            buf = io.StringIO()
            with redirect_stderr(buf):
                self.plugin.cleanup_clickhouse_via_cli("posthog_test_products_test_shard6", str(Path(tmp) / "missing.json"))
            self.assertIn("baseline file missing", buf.getvalue())

            buf = io.StringIO()
            with patch.dict(os.environ, {}, clear=False), redirect_stderr(buf):
                os.environ.pop("CLICKHOUSE_TCP_PORT", None)
                self.plugin.cleanup_clickhouse_via_cli("posthog_test_products_test_shard6", str(baseline_file))
            self.assertIn("CLICKHOUSE_TCP_PORT not set", buf.getvalue())

            # (6) CLI cleanup clean diagnostic.
            def fake_run(cmd, **_kwargs):
                sql = cmd[-1]
                rows = fake_sync_execute(sql)
                out = "\n".join("\t".join(str(x) for x in r) for r in rows)
                return SimpleNamespace(stdout=out, returncode=0)

            buf = io.StringIO()
            with (
                patch.object(subprocess, "run", side_effect=fake_run),
                patch.dict(os.environ, {"CLICKHOUSE_TCP_PORT": "9000"}),
                redirect_stderr(buf),
            ):
                dropped = self.plugin.cleanup_clickhouse_via_cli("posthog_test_products_test_shard6", str(baseline_file))
            self.assertEqual(0, dropped)
            self.assertIn("inter-product ClickHouse cleanup clean", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
