"""pytest plugin: a shard's ClickHouse database is named as upstream's in snapshot comparisons,
and runtime hooks isolate shared services and platform differences without patching upstream tests.

Upstream runs each test job on its own ClickHouse, whose database is posthog_test; the
shards here share one, each in posthog_test_<worker> (test_databases.sh), and printed SQL
names its dictionaries by database, bare or quoted (`posthog_test.channel_definition_dict`,
`` `posthog_test`.`exchange_rate_dict` ``). So before syrupy compares (or writes) a string (or the strings of a list or dict),
this worker's exact `posthog_test_<worker>.` becomes `posthog_test.`, and its quoted
`` `posthog_test_<worker>` `` becomes `` `posthog_test` ``. Its Kafka tables' topics and consumer
groups carry the worker as a suffix too (settings SUFFIX, patch 0001), so a quoted name ending
in `_<worker>'` loses it: `'events_dead_letter_queue_test_<worker>'` and `'group1_<worker>'`
become upstream's `'events_dead_letter_queue_test'` and `'group1'`. Any other text, another
worker's names included, is left as it is. The run's Kafka broker, which the Kafka tables
not on a named collection print quoted (`'127.0.0.1:<port>'`, KAFKA_HOSTS), becomes upstream's
CI broker `'kafka:9092'` (test_schema's `kafka_person_overrides`). A warehouse table's bucket,
which ClickHouse reads at DATAWAREHOUSE_BUCKET_DOMAIN (_rewrite_warehouse_table_url) under a folder carrying the
worker as a suffix (upstream's XDIST_SUFFIX), prints as upstream's
`http://host.docker.internal:19000/<folder>/` (revenue analytics' and the warehouse queries' s3()).
The cluster's host, which a query's failure names by its native address
(`ConnectionInfo(host='127.0.0.1', port=<CLICKHOUSE_TCP_PORT>)`), is upstream's CI host
`ConnectionInfo(host='clickhouse', port=9000)` (test_cluster's test_exception_summary).

A test's id is upstream's too: a parameter ending in this worker's suffix (each worker's own
Temporal task queue, `development-task-queue_<worker>`, patch 0001) is named without it, so
an id is the same on every shard and host. Recorded ids (durations, timings) are matched
across runs, and a shard given another's id would not find it.
run_sharded_pytest.sh loads it for every run.
"""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import pytest
except ImportError:
    pytest = None

_ORDER_BY_START_TIME_RE = re.compile(r"\s+order\s+by\s+StartTime\s+asc\b", re.IGNORECASE)
_MAT_TABLES = ("events", "sharded_events", "person", "groups")
_DATA_TABLES = ("sharded_events", "person", "groups")
_SAFE_IDENT_RE = re.compile(r"^[A-Za-z0-9_$]+$")
_UPSTREAM_INDEX_PREFIXES = ("minmax_", "bloom_filter_", "ngram_bf_lower_", "bloom_filter_lower_")

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


def _configure_syrupy_snapshots() -> None:
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


def _rewrite_warehouse_table_url(sender, instance, **kwargs) -> None:
    """Rewrite hardcoded host.docker.internal:19000 URLs on DataWarehouseTable to
    settings.DATAWAREHOUSE_BUCKET_DOMAIN so ClickHouse reaches the run's object store."""
    url = getattr(instance, "url_pattern", None)
    if sender.__name__ == "DataWarehouseTable" and isinstance(url, str) and url.startswith(UPSTREAM_BUCKET):
        from django.conf import settings

        domain = getattr(settings, "DATAWAREHOUSE_BUCKET_DOMAIN", None)
        if domain:
            instance.url_pattern = f"http://{domain}/{url.removeprefix(UPSTREAM_BUCKET)}"


def _configure_warehouse_bucket_signal() -> None:
    try:
        from django.db.models.signals import pre_save
    except ImportError:
        return
    pre_save.connect(_rewrite_warehouse_table_url, dispatch_uid="enact_warehouse_bucket_domain")


def _wrap_list_workflows(original):
    """Strip `order by StartTime asc` (rejected by Temporal's SQLite visibility store in
    `temporal server start-dev`) and sort workflows by `start_time` in Python."""
    if getattr(original, "enact_sorted_without_order_by", False):
        return original

    def list_workflows(self, query=None, *args, **kwargs):
        if isinstance(query, str) and "order by starttime asc" in query.lower():
            stripped = _ORDER_BY_START_TIME_RE.sub("", query)
            it = original(self, stripped, *args, **kwargs)

            async def _sorted():
                items = [w async for w in it]
                items.sort(key=lambda w: w.start_time)
                for w in items:
                    yield w

            return _sorted()
        if query is None:
            return original(self, *args, **kwargs)
        return original(self, query, *args, **kwargs)

    list_workflows.enact_sorted_without_order_by = True
    return list_workflows


def _configure_temporal_list_workflows() -> None:
    try:
        import temporalio.client
    except ImportError:
        return
    temporalio.client.Client.list_workflows = _wrap_list_workflows(temporalio.client.Client.list_workflows)


def pytest_configure(config):
    _configure_syrupy_snapshots()
    _configure_warehouse_bucket_signal()
    _configure_temporal_list_workflows()


def _xdist_suffix() -> str:
    try:
        from django.conf import settings

        suffix = getattr(settings, "XDIST_SUFFIX", None)
        if suffix is not None:
            return suffix
    except Exception:
        pass
    worker = os.environ.get("PYTEST_XDIST_WORKER")
    return f"_{worker}" if worker else ""


def _hookwrapper(fn):
    return pytest.hookimpl(hookwrapper=True)(fn) if pytest is not None else fn


def _quote_ch_ident(name: str) -> str:
    return "`" + name.replace("`", "``") + "`"


def _clickhouse_baseline_path(ch_db: str) -> Path | None:
    raw = os.environ.get("ENACT_CH_MAT_BASELINE_FILE")
    if not raw:
        return None
    return Path(raw)


def _query_materialized_columns(exec_fn, ch_db: str) -> dict[str, list[str]]:
    """Current materialized columns (`mat_*`, `pmat_*`, `dmat_*`) on `_MAT_TABLES` in `ch_db`."""
    tables_sql = ", ".join(f"'{t}'" for t in _MAT_TABLES)
    rows = exec_fn(
        "SELECT table, name FROM system.columns "
        f"WHERE database = %(db)s AND table IN ({tables_sql}) "
        "AND (name LIKE 'mat\\_%' OR name LIKE 'pmat\\_%' OR name LIKE 'dmat\\_%') "
        "ORDER BY table, name",
        {"db": ch_db},
    )
    cols: dict[str, list[str]] = {t: [] for t in _MAT_TABLES}
    for table, col in rows:
        if table in cols:
            cols[table].append(col)
    return cols


def _query_skip_indexes(exec_fn, ch_db: str) -> list[list[str]]:
    """Current skip-index identities `[table, name, expr]` on `_DATA_TABLES` in `ch_db`."""
    tables_sql = ", ".join(f"'{t}'" for t in _DATA_TABLES)
    rows = exec_fn(
        "SELECT table, name, expr FROM system.data_skipping_indices "
        f"WHERE database = %(db)s AND table IN ({tables_sql}) "
        "ORDER BY table, name",
        {"db": ch_db},
    )
    return [[str(table), str(name), str(expr)] for table, name, expr in rows]


def _expr_references_column(expr: str, col: str) -> bool:
    """Whether ClickHouse index expression `expr` references `col` as a whole identifier
    (backtick-quoted, double-quoted, or bare token — never as a prefix/substring of a sibling
    column such as `mat_$browser` inside `mat_$browser_version`)."""
    escaped = re.escape(col)
    quoted_bt = re.escape(col.replace("`", "``"))
    quoted_dq = re.escape(col.replace('"', '""'))
    pattern = (
        rf"(?<!`)`{quoted_bt}`(?!`)"
        rf'|(?<!")"{quoted_dq}"(?!")'
        rf"|(?<![A-Za-z0-9_$`'\"]){escaped}(?![A-Za-z0-9_$`'\"])"
    )
    return re.search(pattern, expr) is not None


def _index_references_leaked_column(idx_name: str, expr: str, col: str) -> bool:
    """Whether a non-baseline skip index targets the exact leaked column `col` (by whole-token
    identifier match in `expr` or upstream's exact index-naming pattern for `col`)."""
    if any(idx_name == f"{prefix}{col}" for prefix in _UPSTREAM_INDEX_PREFIXES):
        return True
    return _expr_references_column(expr, col)


def _clickhouse_events_exists(exec_fn, ch_db: str) -> bool:
    rows = exec_fn(
        "SELECT count() FROM system.tables WHERE database = %(db)s AND name = 'events'",
        {"db": ch_db},
    )
    return bool(rows and rows[0] and int(rows[0][0]) > 0)


def _drop_leaked_materialized_columns(
    exec_fn,
    ch_db: str,
    baseline_columns: dict[str, list[str]],
    baseline_indexes: list[list[str]] | None = None,
) -> list[str]:
    """Drop materialized columns present in `ch_db` beyond `baseline_columns` (plus only
    non-baseline skip indexes referencing those exact leaked columns) and return the dropped
    `<table>.<column>` list."""
    current = _query_materialized_columns(exec_fn, ch_db)
    extras: dict[str, list[str]] = {}
    for table in _MAT_TABLES:
        base_set = set(baseline_columns.get(table, []))
        extra = [c for c in current.get(table, []) if c not in base_set]
        if extra:
            extras[table] = extra
    if not extras:
        return []

    base_idx_set = {
        (str(entry[0]), str(entry[1]), str(entry[2]))
        for entry in (baseline_indexes or [])
        if len(entry) == 3
    }
    db_q = _quote_ch_ident(ch_db)
    # Drop only non-baseline skip indexes on physical data tables referencing a leaked column.
    for data_table in _DATA_TABLES:
        cols_to_drop = set(extras.get(data_table, []))
        if data_table == "sharded_events":
            cols_to_drop |= set(extras.get("events", []))
        if not cols_to_drop:
            continue
        idx_rows = exec_fn(
            "SELECT name, expr FROM system.data_skipping_indices "
            "WHERE database = %(db)s AND table = %(tbl)s",
            {"db": ch_db, "tbl": data_table},
        )
        for idx_name, expr in idx_rows:
            identity = (data_table, str(idx_name), str(expr))
            if identity in base_idx_set:
                continue
            if any(_index_references_leaked_column(str(idx_name), str(expr), col) for col in cols_to_drop):
                exec_fn(
                    f"ALTER TABLE {db_q}.{_quote_ch_ident(data_table)} "
                    f"DROP INDEX IF EXISTS {_quote_ch_ident(str(idx_name))} SETTINGS mutations_sync = 2",
                    None,
                )

    dropped: list[str] = []
    for table in _MAT_TABLES:
        cols = extras.get(table)
        if not cols:
            continue
        drops = ", ".join(f"DROP COLUMN IF EXISTS {_quote_ch_ident(c)}" for c in cols)
        exec_fn(
            f"ALTER TABLE {db_q}.{_quote_ch_ident(table)} {drops} SETTINGS mutations_sync = 2",
            None,
        )
        dropped.extend(f"{table}.{c}" for c in cols)
    return dropped


def _clear_posthog_materialized_cache() -> None:
    try:
        mod = sys.modules.get("ee.clickhouse.materialized_columns.columns")
        if mod is not None:
            for table in mod.MATERIALIZATION_VALID_TABLES:
                mod._clear_materialized_columns_cache(table)
            return
        cache_mod = sys.modules.get("django.core.cache")
        if cache_mod is not None:
            for table in ("events", "person", "groups"):
                cache_mod.cache.delete(f"materialized_columns:v3:{table}")
    except Exception:
        pass


def _sync_materialized_columns_via_django(phase: str) -> None:
    """Capture the clean worker-DB baseline once (right after `django_db_setup`), or restore
    ClickHouse to that baseline before/after product pytest runs without touching pure non-DB
    tests or migrated defaults on `events`, `person`, and `groups`."""
    ch_db = os.environ.get("CLICKHOUSE_DATABASE")
    if not ch_db:
        return
    baseline_path = _clickhouse_baseline_path(ch_db)
    # On finish without a baseline file, only act if this process actually imported ClickHouse.
    if phase == "finish" and (baseline_path is None or not baseline_path.is_file()):
        if "posthog.clickhouse.client" not in sys.modules:
            return
    try:
        from posthog.clickhouse.client import sync_execute

        def _exec(sql: str, params):
            return sync_execute(sql, params) if params is not None else sync_execute(sql)

        if not _clickhouse_events_exists(_exec, ch_db):
            return
        if baseline_path is not None:
            if not baseline_path.is_file():
                # Capture the clean fresh-migration baseline ONCE before the first DB test runs.
                if phase != "start":
                    return
                baseline = _query_materialized_columns(_exec, ch_db)
                baseline_indexes = _query_skip_indexes(_exec, ch_db)
                baseline_path.parent.mkdir(parents=True, exist_ok=True)
                tmp = baseline_path.with_suffix(f".tmp.{os.getpid()}")
                tmp.write_text(
                    json.dumps(
                        {"database": ch_db, "columns": baseline, "indexes": baseline_indexes},
                        sort_keys=True,
                    )
                )
                tmp.replace(baseline_path)
                return
            saved = json.loads(baseline_path.read_text())
            if saved.get("database") != ch_db:
                return
            dropped = _drop_leaked_materialized_columns(
                _exec, ch_db, saved.get("columns", {}), saved.get("indexes", [])
            )
            if dropped:
                _clear_posthog_materialized_cache()
                print(
                    f"pytest_snapshot_worker: dropped {len(dropped)} leaked materialized column(s) "
                    f"in {ch_db} ({phase}): {', '.join(dropped)}",
                    file=sys.stderr,
                )
        elif phase == "finish":
            from posthog.test.base import cleanup_materialized_columns

            cleanup_materialized_columns()
    except Exception as exc:
        print(f"pytest_snapshot_worker: materialized-column cleanup skipped ({phase}): {exc}", file=sys.stderr)


def cleanup_clickhouse_via_cli(ch_db: str, baseline_file: str) -> int:
    """Inter-process ClickHouse materialized-column cleanup called by `run_sharded_pytest.sh`
    between product subprocesses (zero Django import cost; recovers even after SIGKILL/OOM)."""
    path = Path(baseline_file)
    if not path.is_file() or not _SAFE_IDENT_RE.match(ch_db):
        return 0
    saved = json.loads(path.read_text())
    if saved.get("database") != ch_db:
        return 0
    port = os.environ.get("CLICKHOUSE_TCP_PORT")
    if not port:
        return 0
    host = os.environ.get("CLICKHOUSE_HOST", "127.0.0.1")

    def _exec(sql: str, params):
        rendered = sql
        if params:
            for k, v in params.items():
                escaped = str(v).replace("\\", "\\\\").replace("'", "\\'")
                rendered = rendered.replace(f"%({k})s", f"'{escaped}'")
        res = subprocess.run(
            ["clickhouse-client", "--host", host, "--port", str(port), "-q", rendered],
            capture_output=True,
            text=True,
            check=True,
        )
        rows = []
        for line in res.stdout.splitlines():
            if line:
                rows.append(tuple(line.split("\t")))
        return rows

    if not _clickhouse_events_exists(_exec, ch_db):
        return 0
    dropped = _drop_leaked_materialized_columns(
        _exec, ch_db, saved.get("columns", {}), saved.get("indexes", [])
    )
    if dropped:
        print(
            f"pytest_snapshot_worker: dropped {len(dropped)} leaked materialized column(s) "
            f"in {ch_db} (inter-product): {', '.join(dropped)}",
            file=sys.stderr,
        )
    return len(dropped)


@_hookwrapper
def pytest_fixture_setup(fixturedef, request):
    """Suffix the Postgres batch-export test database per xdist worker so concurrent shards
    sharing one Postgres server do not drop each other's `exports_test_database` schema, and
    capture or enforce the per-worker ClickHouse materialized-column baseline right after
    `django_db_setup` finishes (surviving prior SIGKILL/OOM writers)."""
    outcome = yield
    argname = getattr(fixturedef, "argname", None)
    if argname == "django_db_setup":
        _sync_materialized_columns_via_django("start")
        return
    if argname != "postgres_config":
        return
    try:
        res = outcome.get_result()
    except Exception:
        return
    if isinstance(res, dict) and res.get("database") == "exports_test_database":
        res["database"] = f"exports_test_database{_xdist_suffix()}"


def pytest_collection_modifyitems(config, items):
    """Skip platform-bound tests where the host environment differs from upstream's Linux Docker CI."""
    if pytest is None:
        return
    is_darwin = sys.platform == "darwin"
    is_multicall_coreutils = os.path.basename(os.path.realpath(shutil.which("true") or "")) == "coreutils"
    for item in items:
        if is_darwin and item.name == "test_exception_summary" and "test_cluster.py" in item.nodeid:
            item.add_marker(pytest.mark.skip(reason="ClickHouse stack frames are Linux build's"))
        elif (
            is_multicall_coreutils
            and item.name == "test_executable_overrides_binary"
            and "test_command_exec_audit.py" in item.nodeid
        ):
            item.add_marker(pytest.mark.skip(reason="true is a multicall coreutils binary"))


def pytest_runtest_teardown(item):
    """Clean up materialized columns after `test_compile_hogql_predicate_emits_unqualified_materialized_column`
    so `mat_$current_url` does not leak into subsequent tests in the same shard."""
    if item.name == "test_compile_hogql_predicate_emits_unqualified_materialized_column":
        from posthog.test.base import cleanup_materialized_columns

        cleanup_materialized_columns()


def pytest_sessionfinish(session, exitstatus):
    """Enforce the ClickHouse materialized-column baseline at normal pytest process exit too."""
    _sync_materialized_columns_via_django("finish")


def pytest_make_parametrize_id(config, val, argname):
    """A str parameter ending in this worker's suffix, named as pytest names upstream's value
    (without it). Another worker's suffix (`_shard10` to `shard1`) is left as it is."""
    worker = os.environ.get("PYTEST_XDIST_WORKER")
    if not worker or not isinstance(val, str) or not val.endswith(f"_{worker}"):
        return None
    return val.removesuffix(f"_{worker}").encode("unicode_escape").decode("ascii")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "cleanup-clickhouse":
        try:
            cleanup_clickhouse_via_cli(sys.argv[2], sys.argv[3])
        except Exception as exc:
            print(f"pytest_snapshot_worker: inter-product ClickHouse cleanup skipped: {exc}", file=sys.stderr)
        sys.exit(0)
    print("usage: pytest_snapshot_worker.py cleanup-clickhouse <clickhouse_db> <baseline_file>", file=sys.stderr)
    sys.exit(64)
