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


if __name__ == "__main__":
    unittest.main()
