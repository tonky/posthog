"""Machine-dependent pytest timings; deliberately separate from replay snapshots."""
import json
import os
from pathlib import Path
import time

_loaded = time.perf_counter()
_started_ns = int(os.environ.get("ENACT_PYTEST_STARTED_NS", time.time_ns()))
_report = {"schema": 1, "shard": int(os.environ.get("ENACT_SHARD_INDEX", "1")), "tests": {}}


def pytest_sessionstart(session):
    _report["startup_seconds"] = (time.time_ns() - _started_ns) / 1e9
    _report["collection_started"] = time.perf_counter()


def pytest_collection_finish(session):
    _report["collection_seconds"] = time.perf_counter() - _report.pop("collection_started", _loaded)
    _report["collected"] = len(session.items)


def pytest_runtest_logreport(report):
    test = _report["tests"].setdefault(report.nodeid, {})
    test[report.when] = {"seconds": report.duration, "outcome": report.outcome}


def pytest_sessionfinish(session, exitstatus):
    _report.pop("collection_started", None)
    _report["total_seconds"] = (time.time_ns() - _started_ns) / 1e9
    _report["exit_code"] = int(exitstatus)
    destination = Path(os.environ.get("ENACT_REPLAY_RESULTS", ".enact/pytest"))
    destination.mkdir(parents=True, exist_ok=True)
    (destination / f"timings-shard-{_report['shard']}.json").write_text(json.dumps(_report, sort_keys=True) + "\n")
