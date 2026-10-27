"""Machine-dependent pytest timings; deliberately separate from replay snapshots.

Each pytest process writes, into $ENACT_REPLAY_RESULTS (.enact/state/pytest):
  timings-shard-<n>[-<group>].json    its phases and each test's, for reading
  durations-shard-<n>[-<group>].json  what each test cost the shard, for enact's shard
                                      balancing (analysis.durations): setup, call and
                                      teardown, plus an even share of the process's start-up
                                      and collection, so a product run's ~15s of its own is
                                      counted where its tests go. The host's load per CPU
                                      while it ran is the entries' `contention`.
<group> is the product run_sharded_pytest.sh runs (ENACT_PYTEST_GROUP), one process each.

A durations file is the history of every test its shard and group ever ran: a run updates
the tests it ran and keeps the others (a selected run runs a few), under a lock, and
replaces the file whole, so a plan reading it meanwhile reads the old rows or the new ones.
Rewriting it with the run's tests alone left the next plan without the rest's seconds, and
a plan reading it mid-write lost the file: forecasts flipped between runs.
"""
import fcntl
import json
import os
from pathlib import Path
import tempfile
import time

_loaded = time.perf_counter()
_started_ns = int(os.environ.get("ENACT_PYTEST_STARTED_NS", time.time_ns()))
_report = {"schema": 1, "shard": int(os.environ.get("ENACT_SHARD_INDEX", "1")), "tests": {}}
_group = os.environ.get("ENACT_PYTEST_GROUP", "")


def _load_per_cpu() -> float | None:
    try:
        return os.getloadavg()[0] / (os.cpu_count() or 1)
    except OSError:
        return None


_load_start = _load_per_cpu()


def pytest_sessionstart(session):
    _report["startup_seconds"] = (time.time_ns() - _started_ns) / 1e9
    _report["collection_started"] = time.perf_counter()


def pytest_collection_finish(session):
    _report["collection_seconds"] = time.perf_counter() - _report.pop("collection_started", _loaded)
    _report["collected"] = len(session.items)


def pytest_runtest_logreport(report):
    test = _report["tests"].setdefault(report.nodeid, {})
    test[report.when] = {"seconds": report.duration, "outcome": report.outcome}


def durations(report: dict, contention: float | None) -> dict:
    """Each test's cost to its shard: its phases plus its share of the process's own time."""
    tests = report["tests"]
    if not tests:
        return {}
    overhead = report.get("startup_seconds", 0.0) + report.get("collection_seconds", 0.0)
    share = overhead / len(tests)
    out = {}
    for node, phases in sorted(tests.items()):
        entry = {"seconds": round(sum(p["seconds"] for p in phases.values()) + share, 6)}
        if contention is not None:
            entry["contention"] = round(contention, 3)
        out[node] = entry
    return out


def pytest_sessionfinish(session, exitstatus):
    _report.pop("collection_started", None)
    _report["total_seconds"] = (time.time_ns() - _started_ns) / 1e9
    _report["exit_code"] = int(exitstatus)
    destination = Path(os.environ.get("ENACT_REPLAY_RESULTS", ".enact/state/pytest"))
    destination.mkdir(parents=True, exist_ok=True)
    name = f"shard-{_report['shard']}" + (f"-{_group}" if _group else "")
    (destination / f"timings-{name}.json").write_text(json.dumps(_report, sort_keys=True) + "\n")
    loads = [x for x in (_load_start, _load_per_cpu()) if x is not None]
    contention = sum(loads) / len(loads) if loads else None
    rows = durations(_report, contention)
    if rows:
        record(destination / f"durations-{name}.json", rows)


def record(path: Path, rows: dict) -> None:
    """Lays `rows` over the durations `path` holds, under a lock, and replaces it whole."""
    with open(path.parent / f".{path.stem}.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            merged = json.loads(path.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            merged = {}
        if not isinstance(merged, dict):
            merged = {}
        merged.update(rows)
        fd, temp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
        with os.fdopen(fd, "w") as out:
            out.write(json.dumps(merged, sort_keys=True) + "\n")
        os.replace(temp, path)
