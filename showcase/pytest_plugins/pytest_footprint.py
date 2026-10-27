"""pytest plugin: records which of the repository's functions and files each test file uses,
as an enact reach map (`{"shared": {...}, "targets": {"<test file>": {"files": [...],
"functions": {"<file>": [...]}, "dirs": [...], "probes": [...]}}}`, what every test file
holds written once as `shared`), one file per pytest process in
$ENACT_FOOTPRINT_DIR. run_sharded_pytest.sh loads it when ENACT_FOOTPRINT_DIR is set, which
`enact trace record base:test` and `enact trace sample` do for every task of the job they
run: the suite is recorded with its services, shards and resource limits, and enact merges
the maps and notes each traced file's layout.

A file-open trace can't tell PostHog's tests apart: Django's settings import every app,
core's and the products', before the first test. This records in the process instead
(enact_footprint.py, shared with usecases/odoo): the first call of each function while a
test file is collected or its tests run (their fixtures, setup and teardown included) joins
that file's footprint, as do the files it reads, the directories it lists, the paths it
finds missing and its Python child processes. A function is named as enact's scanner names
it (`co_qualname` up to `.<locals>`); code outside functions (module and class bodies) is no
function: its file joins the footprint alone. Each footprint also says which of the
repository's modules the process had loaded when its file's tests ended (`loaded`, its
Python children's too): a change outside a module's functions runs only the test files
that loaded it. A test file's own module is its tests' and its importers' alone, though
collection imports every file before any test runs (`own_modules`).

What serves every test file is every footprint's: start-up (Django's setup), every module's
import (whenever it happens), `functools` cache computations and session- or package-scoped
fixtures (setup and teardown), which run once, for the first test needing them. A test file
that starts a program the recorder can't follow is opaque: its outcome is partial, so it
runs for any change (the reasons go to the `.stats` file beside the map).

`enact run` records only the test files its map lacks or holds stale: it lists them in
$ENACT_FOOTPRINT_TARGETS, and the others run unmonitored (start-up, imports and session
fixtures are recorded still, as every footprint holds them). The map says each file's
outcome (`"outcomes": true`): a file with a failed test, or one whose tests didn't all run,
is incomplete (failed), so a failing shard lands only its passing files' footprints. A file
with a skipped test (or skipped whole) says the platform that skipped it (`skipped_on`): its
footprint holds what the skip read, so planning on another platform runs it on every change.
"""

import atexit
import os
import sys

import enact_footprint as core
import pytest

OUT_DIR = os.environ.get("ENACT_FOOTPRINT_DIR")
# Under a recording already (a test's own pytest child): that recorder has this process.
RECORDING = bool(OUT_DIR) and not os.environ.get(core.ENV_CHILDREN) and not core.child

# The repository: run_sharded_pytest.sh runs a product from its own directory.
root = os.path.realpath(os.environ.get("POSTHOG_REPO_ROOT") or os.getcwd()) + os.sep


def wanted_files() -> set[str] | None:
    """The test files to record ($ENACT_FOOTPRINT_TARGETS, targets or test ids); None: all."""
    listed = os.environ.get("ENACT_FOOTPRINT_TARGETS")
    if not listed:
        return None
    with open(listed) as f:
        return {line.strip().split("::", 1)[0] for line in f if line.strip()}


WANTED = wanted_files() if RECORDING else None
# Per recorded test file: its tests collected, those that ran, and whether one failed.
collected: dict[str, int] = {}
finished: dict[str, int] = {}
failed: set[str] = set()
# Recorded test files with a test skipped (xfail aside: its test ran), or skipped whole.
skipped: set[str] = set()
# The platform as enact names it (`linux`, `darwin`).
PLATFORM = "linux" if sys.platform.startswith("linux") else sys.platform


def relative(path) -> str | None:
    rel = core.relative(str(path))
    return rel or None


def target_of(node) -> str | None:
    """The footprint `node` records into: its test file's, SHARED outside a file (a
    directory's collection), None for a test file not recorded."""
    rel = relative(node.path)
    if not rel or not rel.endswith(".py"):
        return core.SHARED
    return rel if WANTED is None or rel in WANTED else None


def recorded_file(item) -> str | None:
    key = target_of(item)
    return None if key in (None, core.SHARED) else key


def pytest_collection_finish(session):
    for item in session.items:
        rel = recorded_file(item)
        if rel:
            collected[rel] = collected.get(rel, 0) + 1


@pytest.hookimpl(wrapper=True)
def pytest_make_collect_report(collector):
    """A test file's collection (its module's import aside, which is shared) is its own."""
    if not RECORDING:
        return (yield)
    previous = core.current_key
    core.switch(target_of(collector))
    try:
        report = yield
        rel = recorded_file(collector)
        if rel and isinstance(collector, pytest.Module):
            core.own_modules.add(rel)
        if rel and report.skipped:
            skipped.add(rel)
        return report
    finally:
        core.switch(previous)


@pytest.hookimpl(wrapper=True)
def pytest_runtest_protocol(item, nextitem):
    if RECORDING:
        core.switch(target_of(item))
    try:
        return (yield)
    finally:
        rel = recorded_file(item)
        if rel:
            finished[rel] = finished.get(rel, 0) + 1


@pytest.hookimpl(wrapper=True)
def pytest_runtest_makereport(item, call):
    report = yield
    rel = recorded_file(item)
    if rel and report.failed:
        failed.add(rel)
    elif rel and report.skipped and not hasattr(report, "wasxfail"):
        skipped.add(rel)
    return report


@pytest.hookimpl(wrapper=True)
def pytest_fixture_setup(fixturedef, request):
    """A session or package fixture runs once, for all its tests: what it runs is shared."""
    if not RECORDING or fixturedef.scope not in ("session", "package"):
        return (yield)
    core.enter_shared()
    try:
        return (yield)
    finally:
        core.leave_shared()


@pytest.hookimpl(tryfirst=True)
def pytest_sessionfinish(session):
    if RECORDING:
        core.switch(None)  # reporting: no test's


def patch_pytest() -> None:
    """pytest's own module loading (test files and conftests, rewritten) and session fixture
    teardown are shared, as the import system's and setup are."""
    from _pytest import fixtures
    from _pytest.assertion import rewrite

    rewrite.AssertionRewritingHook.exec_module = core.extent(core.noting(rewrite.AssertionRewritingHook.exec_module))
    finish = fixtures.FixtureDef.finish

    def finish_fixture(self, request):
        if self.scope not in ("session", "package"):
            return finish(self, request)
        core.enter_shared()
        try:
            return finish(self, request)
        finally:
            core.leave_shared()

    fixtures.FixtureDef.finish = finish_fixture


def write() -> None:
    shared, entries = core.finish()
    targets, opaque = {}, {}
    for target, (entry, why) in sorted(entries.items()):
        if target not in entry["files"]:
            entry["files"] = sorted({*entry["files"], target})
            entry["functions"].setdefault(target, [])
        if why:
            opaque[target] = why
        if target in failed or finished.get(target, 0) < collected.get(target, 0):
            entry["outcome"] = {"incomplete": {"exit": 1}}
        elif why:
            entry["outcome"] = "partial"
        if target in skipped:
            entry["skipped_on"] = [PLATFORM]
        targets[target] = entry
    if not targets:
        return
    shard = os.environ.get("ENACT_SHARD_INDEX", "1")
    group = os.environ.get("ENACT_PYTEST_GROUP", "")
    prefix = f"shard{shard}-{group}-" if group else f"shard{shard}-"
    out = core.write_map(os.path.abspath(OUT_DIR), prefix, shared, targets)
    core.write_stats(out, len(targets), opaque)
    print(
        f"pytest_footprint: {len(targets)} test files ({len(opaque)} opaque), "
        f"{os.path.getsize(out) >> 20} MB -> {out}",
        file=sys.stderr,
    )


if RECORDING:
    core.start(
        root,
        recorders=(__file__,),
        unlisted_callers=(f"{os.sep}_pytest{os.sep}",),
        # posthog/conftest.py's persons database: `sqlx migrate run --source
        # rust/persons_migrations` reads that directory, and sqlx reads `.env` (and a
        # `sqlx.toml`, its default `migrations/`) where it runs.
        readers={"sqlx": (".env", "sqlx.toml", "migrations")},
    )
    patch_pytest()
    atexit.register(write)
