"""pytest plugin: a shard's ClickHouse database is named as upstream's in snapshot comparisons.

Upstream runs each test job on its own ClickHouse, whose database is posthog_test; the
shards here share one, each in posthog_test_<worker> (test_databases.sh), and printed SQL
names its dictionaries by database, bare or quoted (`posthog_test.channel_definition_dict`,
`` `posthog_test`.`exchange_rate_dict` ``). So before syrupy compares (or writes) a string (or the strings of a list or dict),
this worker's exact `posthog_test_<worker>.` becomes `posthog_test.`, and its quoted
`` `posthog_test_<worker>` `` becomes `` `posthog_test` ``. Its Kafka tables' topics and consumer
groups carry the worker as a suffix too (settings SUFFIX, patch 0006), so a quoted name ending
in `_<worker>'` loses it: `'events_dead_letter_queue_test_<worker>'` and `'group1_<worker>'`
become upstream's `'events_dead_letter_queue_test'` and `'group1'`. Any other text, another
worker's names included, is left as it is. The run's Kafka broker, which the Kafka tables
not on a named collection print quoted (`'127.0.0.1:<port>'`, KAFKA_HOSTS), becomes upstream's
CI broker `'kafka:9092'` (test_schema's `kafka_person_overrides`). A warehouse table's bucket,
which ClickHouse reads at DATAWAREHOUSE_BUCKET_DOMAIN (patch 0011) under a folder carrying the
worker as a suffix (upstream's XDIST_SUFFIX), prints as upstream's
`http://host.docker.internal:19000/<folder>/` (revenue analytics' and the warehouse queries' s3()).
The cluster's host, which a query's failure names by its native address
(`ConnectionInfo(host='127.0.0.1', port=<CLICKHOUSE_TCP_PORT>)`), is upstream's CI host
`ConnectionInfo(host='clickhouse', port=9000)` (test_cluster's test_exception_summary).

A test's id is upstream's too: a parameter ending in this worker's suffix (each worker's own
Temporal task queue, `development-task-queue_<worker>`, patch 0013) is named without it, so
an id is the same on every shard and host. Recorded ids (durations, timings) are matched
across runs, and a shard given another's id would not find it.
run_sharded_pytest.sh loads it for every run.
"""

import os

def worker_names(worker: str | None) -> list[tuple[str, str]]:
    """This worker's names as SQL prints them, and upstream's: its database bare (before a `.`)
    and quoted, and a quoted Kafka topic or consumer group carrying its suffix."""
    if not worker:
        return []
    return [
        (f"posthog_test_{worker}.", "posthog_test."),
        (f"`posthog_test_{worker}`", "`posthog_test`"),
        (f"_{worker}'", "'"),
        (f"_{worker}/", "/"),
    ]


UPSTREAM_BROKER = "kafka:9092"


def broker_names(hosts: str | None) -> list[tuple[str, str]]:
    """The run's Kafka brokers as a Kafka engine's quoted hosts argument prints them, and
    upstream's (CI reaches its broker as `kafka:9092`)."""
    if not hosts or hosts == UPSTREAM_BROKER:
        return []
    return [(f"'{hosts}'", f"'{UPSTREAM_BROKER}'")]


UPSTREAM_BUCKET = "http://host.docker.internal:19000/"


def bucket_names(domain: str | None) -> list[tuple[str, str]]:
    """The bucket as ClickHouse reaches it in a warehouse table's url, and upstream's (its test
    helpers name the Docker host's object store)."""
    if not domain or f"http://{domain}/" == UPSTREAM_BUCKET:
        return []
    return [(f"http://{domain}/", UPSTREAM_BUCKET)]


UPSTREAM_CLUSTER_HOST = "ConnectionInfo(host='clickhouse', port=9000)"


def cluster_host_names(host: str | None, port: str | None) -> list[tuple[str, str]]:
    """The run's ClickHouse as the cluster's HostInfo prints it, and upstream's CI host."""
    if not host or not port:
        return []
    ours = f"ConnectionInfo(host='{host}', port={port})"
    return [] if ours == UPSTREAM_CLUSTER_HOST else [(ours, UPSTREAM_CLUSTER_HOST)]


def this_workers_names() -> list[tuple[str, str]]:
    return (
        worker_names(os.environ.get("PYTEST_XDIST_WORKER"))
        + broker_names(os.environ.get("KAFKA_HOSTS"))
        + bucket_names(os.environ.get("DATAWAREHOUSE_BUCKET_DOMAIN"))
        + cluster_host_names(
            os.environ.get("CLICKHOUSE_TEST_CLUSTER_HOST", os.environ.get("CLICKHOUSE_HOST")),
            os.environ.get("CLICKHOUSE_TCP_PORT"),
        )
    )


def normalized(data, names: list[tuple[str, str]]):
    """`data` with this worker's database renamed in its strings, in lists, tuples and dicts too
    (dags' delete tests snapshot the statements they captured as a list). Anything it renames
    nothing in is returned as it was: a str subclass (a StrEnum such as test_explain's
    QueryIndexUsage) stays itself, as syrupy serializes it by its type."""
    if isinstance(data, str):
        renamed = data
        for ours, upstream in names:
            renamed = renamed.replace(ours, upstream)
        return data if renamed == data else renamed
    if isinstance(data, (list, tuple)):
        items = [normalized(item, names) for item in data]
        if all(new is old for new, old in zip(items, data)):
            return data
        return type(data)(items)
    if isinstance(data, dict):
        values = {key: normalized(value, names) for key, value in data.items()}
        if all(values[key] is value for key, value in data.items()):
            return data
        return values
    return data


def pytest_configure(config):
    names = this_workers_names()
    if not names:
        return
    try:
        from syrupy.assertion import SnapshotAssertion
    except ImportError:
        return
    original = SnapshotAssertion._assert
    if getattr(original, "upstream_database", False):
        return

    def _assert(self, data):
        return original(self, normalized(data, names))

    _assert.upstream_database = True
    SnapshotAssertion._assert = _assert


def pytest_make_parametrize_id(config, val, argname):
    """A str parameter ending in this worker's suffix, named as pytest names upstream's value
    (without it). Another worker's suffix (`_shard10` to `shard1`) is left as it is."""
    worker = os.environ.get("PYTEST_XDIST_WORKER")
    if not worker or not isinstance(val, str) or not val.endswith(f"_{worker}"):
        return None
    return val.removesuffix(f"_{worker}").encode("unicode_escape").decode("ascii")
