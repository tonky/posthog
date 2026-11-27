#!/usr/bin/env python3
"""Declarative sharded pytest runner with automatic database isolation.

Core Python orchestration for `run_sharded_pytest.sh`:
  - Resolves test targets from positional arguments, `@argfile`, `*.txt`, or `ENACT_TARGETS_FILE`.
  - Applies macOS `chdb` target exclusions (U31), returning `--ignore=...` for parent dirs.
  - Prepares runtime environment (TZDIR, Linux tzdir-shim, frontend stubs, GeoIP mmdb,
    per-shard DB provisioning via `run_sharded_pytest.sh --provision-db`, ephemeral RSA keys).
  - Plans per-product and core pytest invocations via `product_pytest.py`, executes them
    sequentially through `backend_runtime.py`, runs inter-product ClickHouse cleanup,
    and propagates exit codes (immediate stop on 2/3/4, fail on 5, last non-zero overall).
"""

from __future__ import annotations

import dataclasses
import glob
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, Mapping, Sequence

MACOS_CHDB_EXCLUDED: tuple[str, ...] = (
    "products/web_analytics/backend/hogql_queries/external/test/test_summary_query_runner.py",
    "products/web_analytics/dags/tests/test_web_preaggregated_asset_checks.py",
)

# Exact per-case quarantine matching `base:test` `target_scope.not_run` in `.enact/components.cue`.
# Keeps the other 37 passing node IDs in `test_markdown_safety.py` active while leaving its 1.0s ReDoS timeout untouched.
CORE_CASE_DESELECTS: tuple[tuple[str, str], ...] = (
    (
        "posthog/helpers/test_markdown_safety.py",
        "posthog/helpers/test_markdown_safety.py::TestStripExternalLinks::test_non_posthog_urls_defanged_9_leading_bracket_run",
    ),
)

SIGNALS_PRELOAD_SNIPPET = (
    'import sys, pytest; '
    'P=type("P",(),{"pytest_collection":lambda self: '
    '(__import__("products.signals.backend.scout_harness.tools.emit"), None)[1]}); '
    'raise SystemExit(pytest.main(sys.argv[1:], plugins=[P()]))'
)

TZ_SHIM_C = r"""#define _GNU_SOURCE
#include <dlfcn.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static const char *enact_tz_remap(const char *p, char *b, size_t cap) {
    const char *pfx = "/usr/share/zoneinfo";
    if (!p || strncmp(p, pfx, 19) != 0 || (p[19] != '\0' && p[19] != '/')) return p;
    const char *tz = getenv("TZDIR");
    if (!tz || !*tz) return p;
    int n = snprintf(b, cap, "%s%s", tz, p + 19);
    return (n > 0 && (size_t)n < cap) ? b : p;
}
int __xstat(int v, const char *p, struct stat *s) {
    static int (*fn)(int, const char *, struct stat *);
    if (!fn) fn = dlsym(RTLD_NEXT, "__xstat");
    char b[4096]; return fn(v, enact_tz_remap(p, b, sizeof b), s);
}
int __xstat64(int v, const char *p, struct stat64 *s) {
    static int (*fn)(int, const char *, struct stat64 *);
    if (!fn) fn = dlsym(RTLD_NEXT, "__xstat64");
    char b[4096]; return fn(v, enact_tz_remap(p, b, sizeof b), s);
}
int stat(const char *p, struct stat *s) {
    static int (*fn)(const char *, struct stat *);
    if (!fn) fn = dlsym(RTLD_NEXT, "stat");
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b), s);
}
int stat64(const char *p, struct stat64 *s) {
    static int (*fn)(const char *, struct stat64 *);
    if (!fn) fn = dlsym(RTLD_NEXT, "stat64");
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b), s);
}
int newfstatat(int fd, const char *p, struct stat *s, int f) {
    static int (*fn)(int, const char *, struct stat *, int);
    if (!fn) fn = dlsym(RTLD_NEXT, "newfstatat");
    char b[4096]; return fn(fd, enact_tz_remap(p, b, sizeof b), s, f);
}
int fstatat(int fd, const char *p, struct stat *s, int f) {
    static int (*fn)(int, const char *, struct stat *, int);
    if (!fn) fn = dlsym(RTLD_NEXT, "fstatat");
    char b[4096]; return fn(fd, enact_tz_remap(p, b, sizeof b), s, f);
}
int fstatat64(int fd, const char *p, struct stat64 *s, int f) {
    static int (*fn)(int, const char *, struct stat64 *, int);
    if (!fn) fn = dlsym(RTLD_NEXT, "fstatat64");
    char b[4096]; return fn(fd, enact_tz_remap(p, b, sizeof b), s, f);
}
DIR *opendir(const char *p) {
    static DIR *(*fn)(const char *);
    if (!fn) fn = dlsym(RTLD_NEXT, "opendir");
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b));
}
FILE *fopen(const char *p, const char *m) {
    static FILE *(*fn)(const char *, const char *);
    if (!fn) fn = dlsym(RTLD_NEXT, "fopen");
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b), m);
}
FILE *fopen64(const char *p, const char *m) {
    static FILE *(*fn)(const char *, const char *);
    if (!fn) fn = dlsym(RTLD_NEXT, "fopen64");
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b), m);
}
int open(const char *p, int f, ...) {
    static int (*fn)(const char *, int, mode_t);
    if (!fn) fn = dlsym(RTLD_NEXT, "open");
    mode_t m = 0; if (f & O_CREAT) { va_list a; va_start(a, f); m = va_arg(a, int); va_end(a); }
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b), f, m);
}
int open64(const char *p, int f, ...) {
    static int (*fn)(const char *, int, mode_t);
    if (!fn) fn = dlsym(RTLD_NEXT, "open64");
    mode_t m = 0; if (f & O_CREAT) { va_list a; va_start(a, f); m = va_arg(a, int); va_end(a); }
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b), f, m);
}
int openat(int fd, const char *p, int f, ...) {
    static int (*fn)(int, const char *, int, mode_t);
    if (!fn) fn = dlsym(RTLD_NEXT, "openat");
    mode_t m = 0; if (f & O_CREAT) { va_list a; va_start(a, f); m = va_arg(a, int); va_end(a); }
    char b[4096]; return fn(fd, enact_tz_remap(p, b, sizeof b), f, m);
}
"""


@dataclasses.dataclass(frozen=True)
class PlannedRun:
    group: str
    directory: str
    args: tuple[str, ...]


class TargetResolutionError(RuntimeError):
    """Raised when no valid targets are supplied to a shard."""


def _read_nonempty_lines(path: Path) -> list[str]:
    return [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def resolve_targets(argv: Sequence[str], env: Mapping[str, str], shard: str) -> list[str]:
    """Resolve test targets from positional args, `@argfile`, `*.txt`, or `ENACT_TARGETS_FILE`."""
    raw = list(argv)
    if len(raw) == 1 and raw[0] in ("", "@"):
        raw = []

    targets_file = env.get("ENACT_TARGETS_FILE", "")
    if not raw and not targets_file:
        raise TargetResolutionError(
            "✗ run_sharded_pytest.sh: no test targets (arguments, @file or ENACT_TARGETS_FILE)"
        )

    targets: list[str] = []
    if len(raw) == 1 and raw[0].startswith("@"):
        file_path = raw[0][1:]
        if not file_path or not Path(file_path).is_file():
            raise TargetResolutionError(f"✗ run_sharded_pytest.sh: no test targets in {file_path or raw[0]}")
        targets = _read_nonempty_lines(Path(file_path))
        if not targets:
            raise TargetResolutionError(f"✗ run_sharded_pytest.sh: no test targets in {file_path}")
    elif len(raw) == 1 and raw[0].endswith(".txt") and Path(raw[0]).is_file():
        targets = _read_nonempty_lines(Path(raw[0]))
        if not targets:
            raise TargetResolutionError(f"✗ run_sharded_pytest.sh: no test targets in {raw[0]}")
    elif raw:
        targets = raw
    elif targets_file and Path(targets_file).is_file():
        targets = _read_nonempty_lines(Path(targets_file))
        if not targets:
            raise TargetResolutionError(f"✗ run_sharded_pytest.sh: no test targets in {targets_file}")

    if not targets:
        raise TargetResolutionError(f"✗ run_sharded_pytest.sh: shard {shard} has no test targets")
    return targets


def filter_macos_targets(
    targets: Sequence[str],
    root: Path,
    os_name: str,
) -> tuple[list[str], list[str], list[str]]:
    """Filter out macOS chdb-importing targets (U31).

    Returns (kept_targets, left_out_ignore_flags, dropped_targets).
    """
    if os_name != "Darwin":
        return list(targets), [], []

    current = list(targets)
    left_out: list[str] = []
    dropped: list[str] = []
    for excluded in MACOS_CHDB_EXCLUDED:
        kept: list[str] = []
        held = False
        for target in current:
            if target.split("::", 1)[0] == excluded:
                dropped.append(target)
                continue
            kept.append(target)
            if target.startswith("-"):
                continue
            if target == "." or excluded.startswith(target.rstrip("/") + "/"):
                held = True
        current = kept
        if held:
            left_out.append(f"--ignore={root / excluded}")
    return current, left_out, dropped


def product_object_storage_endpoint(endpoint: str | None) -> str:
    """Rewrite http://localhost:<port> -> http://localhost.:<port> for product pytest runs."""
    if endpoint and endpoint.startswith("http://localhost:"):
        return "http://localhost.:" + endpoint[len("http://localhost:") :]
    return ""


def parse_planned_runs(output: str) -> list[PlannedRun]:
    """Parse tab-separated `group\\tdir\\tshlex_args` lines from `product_pytest.py`."""
    runs: list[PlannedRun] = []
    for line in output.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t", 2)
        if len(parts) != 3:
            raise ValueError(f"Malformed product_pytest.py plan line: {line!r}")
        group, directory, raw_args = parts
        runs.append(PlannedRun(group=group, directory=directory, args=tuple(shlex.split(raw_args))))
    return runs


def build_plugins(env: Mapping[str, str]) -> list[str]:
    plugins = [
        "-p",
        "pytest_timings",
        "-p",
        "pytest_snapshot_worker",
        "-p",
        "pytest_fail_early",
        "-p",
        "pytest_unmarked_db_setup",
        "-p",
        "pytest_query_tags",
    ]
    if env.get("ENACT_FOOTPRINT_DIR"):
        plugins.extend(["-p", "pytest_footprint"])
    return plugins


def is_services_active(env: Mapping[str, str]) -> bool:
    if not env.get("PGPORT"):
        return False
    if env.get("ENACT_SERVICES_ACTIVE", "1") == "0":
        return False
    if env.get("ENACT_COLLECT_ONLY", "0") == "1":
        return False
    return True


def detect_os_name(env: Mapping[str, str]) -> str:
    """Query `uname -s` (honoring PATH overrides in unit tests), falling back to platform.system()."""
    try:
        res = subprocess.run(
            ["uname", "-s"],
            env=dict(env),
            capture_output=True,
            text=True,
            close_fds=True,
            check=True,
        )
        name = res.stdout.strip()
        if name:
            return name
    except OSError:
        pass
    return platform.system()


def resolve_tzdir(root: Path, env: Mapping[str, str]) -> str | None:
    if env.get("TZDIR") or Path("/usr/share/zoneinfo/tzdata.zi").is_file():
        return None
    enve_store = env.get("ENVE_STORE_DIR", "")
    if not enve_store:
        py_bin = shutil.which("python3", path=env.get("PATH")) or ""
        parts = Path(py_bin).parts
        if len(parts) >= 4:
            enve_store = str(Path(*parts[:-3]))
    candidates: list[str] = []
    if enve_store:
        candidates.extend(glob.glob(f"{enve_store}/*-tzdata-*/share/zoneinfo"))
    candidates.extend(glob.glob("/nix/store/*-tzdata-*/share/zoneinfo"))
    candidates.extend(glob.glob(f"{root}/.venv/lib/python*/site-packages/tzdata/zoneinfo"))
    for marker in ("tzdata.zi", "UTC"):
        for tzdir in candidates:
            if (Path(tzdir) / marker).is_file():
                return tzdir
    return None


def maybe_build_tz_shim(root: Path, env: Mapping[str, str], os_name: str) -> str:
    if Path("/usr/share/zoneinfo").is_dir() or not env.get("TZDIR") or os_name != "Linux":
        return ""
    if not shutil.which("cc", path=env.get("PATH")):
        return ""
    state_dir = root / ".enact" / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    hosttype = env.get("HOSTTYPE") or platform.machine() or "linux"
    tz_so = state_dir / f"tzdir-shim-v2-{hosttype}.so"
    if not (tz_so.is_file() and tz_so.stat().st_size > 0):
        tz_tmp = Path(f"{tz_so}.{os.getpid()}")
        try:
            res = subprocess.run(
                ["cc", "-shared", "-fPIC", "-O2", "-fno-stack-protector", "-x", "c", "-", "-o", str(tz_tmp)],
                input=TZ_SHIM_C,
                text=True,
                env=dict(env),
                stderr=subprocess.DEVNULL,
                close_fds=True,
                check=False,
            )
            if res.returncode == 0 and tz_tmp.is_file():
                tz_tmp.replace(tz_so)
            else:
                tz_tmp.unlink(missing_ok=True)
        except OSError:
            tz_tmp.unlink(missing_ok=True)
    return str(tz_so) if (tz_so.is_file() and tz_so.stat().st_size > 0) else ""


def ensure_needed_files(root: Path, env: Mapping[str, str]) -> None:
    dist_dir = root / "frontend" / "dist"
    dist_dir.mkdir(parents=True, exist_ok=True)
    for page in ("index", "layout", "exporter"):
        stub = dist_dir / f"{page}.html"
        if not stub.exists():
            stub.touch()

    mmdb = root / "share" / "GeoLite2-City.mmdb"
    if mmdb.is_file():
        return
    host_cache = env.get("ENACT_HOST_CACHE", "")
    cached = Path(host_cache) / "shared" / "GeoLite2-City.mmdb" if host_cache else None
    if cached is not None and cached.is_file() and cached.stat().st_size > 0:
        mmdb.parent.mkdir(parents=True, exist_ok=True)
        tmp = mmdb.parent / f"GeoLite2-City.mmdb.tmp.{os.getpid()}"
        shutil.copy2(cached, tmp)
        tmp.replace(mmdb)
        return

    subprocess.run(
        ["showcase/scripts/exclusive.sh", "geoip", "./bin/download-mmdb"],
        cwd=str(root),
        env=dict(env),
        close_fds=True,
        check=True,
    )
    if cached is not None and mmdb.is_file() and mmdb.stat().st_size > 0:
        cached.parent.mkdir(parents=True, exist_ok=True)
        tmp = cached.parent / f"GeoLite2-City.mmdb.tmp.{os.getpid()}"
        shutil.copy2(mmdb, tmp)
        tmp.replace(cached)


def _bootstrap_postgres_if_unmanaged(env: Mapping[str, str]) -> None:
    if env.get("ENVE_SERVICE_POSTGRES_PORT"):
        return
    pg_host = env["PGHOST"]
    pg_port = env["PGPORT"]
    pg_user = env["PGUSER"]
    while True:
        res = subprocess.run(
            ["pg_isready", "-h", pg_host, "-p", pg_port, "-q"],
            env=dict(env),
            close_fds=True,
            check=False,
        )
        if res.returncode == 0:
            break
        time.sleep(0.1)

    whoami = ""
    try:
        whoami = subprocess.run(
            ["whoami"], env=dict(env), capture_output=True, text=True, close_fds=True, check=False
        ).stdout.strip()
    except OSError:
        pass
    for admin_user in ("postgres", env.get("USER", ""), "runner", whoami):
        if not admin_user:
            continue
        probe = subprocess.run(
            ["psql", "-h", pg_host, "-p", pg_port, "-U", admin_user, "-d", "postgres", "-c", "SELECT 1;"],
            env=dict(env),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            check=False,
        )
        if probe.returncode == 0:
            role_sql = (
                f"DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '{pg_user}') "
                f"THEN CREATE ROLE {pg_user} WITH SUPERUSER LOGIN CREATEDB PASSWORD 'posthog'; "
                f"ELSE ALTER ROLE {pg_user} WITH SUPERUSER CREATEDB; END IF; END $$;"
            )
            subprocess.run(
                ["psql", "-h", pg_host, "-p", pg_port, "-U", admin_user, "-d", "postgres", "-c", role_sql],
                env=dict(env),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                check=False,
            )
            subprocess.run(
                ["psql", "-h", pg_host, "-p", pg_port, "-U", admin_user, "-d", "postgres", "-c", f"CREATE DATABASE {pg_user} OWNER {pg_user};"],
                env=dict(env),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                check=False,
            )
            break


def provision_worker_databases(
    root: Path,
    env: dict[str, str],
    shard: str,
    *,
    provision_runner: Callable[[list[str], Path, Mapping[str, str]], subprocess.CompletedProcess[str]] | None = None,
) -> str:
    """Provision per-shard databases via `run_sharded_pytest.sh --provision-db` and merge exported env vars."""
    with tempfile.TemporaryDirectory() as tmp_dir:
        out_json = Path(tmp_dir) / "db-env.json"
        cmd = [
            "bash",
            str(root / "showcase" / "scripts" / "run_sharded_pytest.sh"),
            "--provision-db",
            str(out_json),
            shard,
        ]
        if provision_runner is not None:
            res = provision_runner(cmd, root, env)
            if res.returncode != 0:
                raise subprocess.CalledProcessError(res.returncode, cmd)
        else:
            subprocess.run(cmd, cwd=str(root), env=env, close_fds=True, check=True)
        exported = json.loads(out_json.read_text(encoding="utf-8"))
        env.update({k: str(v) for k, v in exported.items()})
        return env["ENACT_WORKER_ID"]


def _maybe_generate_shard_rsa_keys(root: Path, env: dict[str, str]) -> None:
    if env.get("OIDC_RSA_PRIVATE_KEY") and env.get("SANDBOX_JWT_PRIVATE_KEY"):
        return
    venv_py = root / ".venv" / "bin" / "python"
    if not (venv_py.is_file() and os.access(venv_py, os.X_OK)):
        return
    code = (
        "from cryptography.hazmat.primitives import serialization as s\n"
        "from cryptography.hazmat.primitives.asymmetric import rsa\n"
        "key = rsa.generate_private_key(public_exponent=65537, key_size=2048)\n"
        "print(key.private_bytes(s.Encoding.PEM, s.PrivateFormat.TraditionalOpenSSL, s.NoEncryption()).decode())"
    )
    res = subprocess.run(
        [str(venv_py), "-c", code],
        cwd=str(root),
        env=env,
        capture_output=True,
        text=True,
        close_fds=True,
        check=False,
    )
    key = res.stdout.strip()
    if res.returncode == 0 and key:
        env.setdefault("OIDC_RSA_PRIVATE_KEY", key)
        env.setdefault("SANDBOX_JWT_PRIVATE_KEY", key)


def _args_may_collect(args: Sequence[str], file_path: str) -> bool:
    """Return True if pytest operands may collect `file_path` (directly, via an ancestor dir, or whole-suite)."""
    operands = [a for a in args if not a.startswith("-")]
    if not operands:
        return True
    target = Path(file_path)
    for op in operands:
        base = op.split("::", 1)[0].rstrip("/")
        if not base or base == "." or base == file_path:
            return True
        if not base.endswith(".py") and (target == Path(base) or Path(base) in target.parents):
            return True
    return False


def build_pytest_command(
    run: PlannedRun,
    *,
    plugins: Sequence[str],
    left_out: Sequence[str],
    reuse_db_arg: Sequence[str],
    python_exe: str = "python3",
) -> list[str]:
    base = [python_exe, "showcase/scripts/backend_runtime.py", "exec", "uv", "run", "--no-sync"]
    tail = [*plugins, *left_out, "-o", "pythonhashseed=0", *reuse_db_arg, *run.args]
    if run.directory == ".":
        deselects = [
            f"--deselect={node_id}"
            for file_path, node_id in CORE_CASE_DESELECTS
            if _args_may_collect(run.args, file_path)
        ]
        return [*base, "python", "-m", "pytest", *deselects, *tail]
    if run.group == "signals":
        return [*base, "--directory", run.directory, "python", "-c", SIGNALS_PRELOAD_SNIPPET, *tail]
    return [*base, "--directory", run.directory, "pytest", *tail]


def execute_planned_runs(
    runs: Sequence[PlannedRun],
    *,
    root: Path,
    base_env: Mapping[str, str],
    plugins: Sequence[str],
    left_out: Sequence[str],
    reuse_db_arg: Sequence[str],
    services_active: bool,
    tz_ld_preload: str,
    product_endpoint: str,
    run_cmd_fn: Callable[[list[str], Path, Mapping[str, str]], int] | None = None,
) -> int:
    """Execute planned pytest runs sequentially and propagate exit codes cleanly."""

    def _default_run_cmd(cmd: list[str], cwd: Path, env: Mapping[str, str]) -> int:
        return subprocess.run(cmd, cwd=str(cwd), env=dict(env), close_fds=True, check=False).returncode

    runner = run_cmd_fn or _default_run_cmd
    overall = 0
    for run in runs:
        if len(runs) > 1:
            print(f"▶ pytest [{run.group}] in {run.directory}: {len(run.args)} arguments", flush=True)
        run_env = dict(base_env)
        run_env["ENACT_PYTEST_GROUP"] = run.group
        if tz_ld_preload:
            run_env["LD_PRELOAD"] = tz_ld_preload
        if run.directory != ".":
            if product_endpoint:
                run_env["OBJECT_STORAGE_ENDPOINT"] = product_endpoint
            if run.group == "signals":
                existing_pp = run_env.get("PYTHONPATH", "")
                run_env["PYTHONPATH"] = f"{root}:{existing_pp}" if existing_pp else str(root)

        cmd = build_pytest_command(
            run,
            plugins=plugins,
            left_out=left_out,
            reuse_db_arg=reuse_db_arg,
        )
        code = runner(cmd, root, run_env)

        if services_active and len(runs) > 1:
            ch_db = base_env.get("CLICKHOUSE_DATABASE", "")
            baseline = base_env.get("ENACT_CH_MAT_BASELINE_FILE", "")
            if ch_db and baseline and Path(baseline).is_file() and Path(baseline).stat().st_size > 0:
                runner(
                    [
                        "python3",
                        str(root / "showcase" / "pytest_plugins" / "pytest_snapshot_worker.py"),
                        "cleanup-clickhouse",
                        ch_db,
                        baseline,
                    ],
                    root,
                    base_env,
                )
            else:
                baseline_exists = "yes" if (baseline and Path(baseline).is_file() and Path(baseline).stat().st_size > 0) else "no"
                print(
                    f"pytest_snapshot_worker: inter-product ClickHouse cleanup skipped in "
                    f"run_sharded_pytest.sh after [{run.group}]: "
                    f"CLICKHOUSE_DATABASE={ch_db or '<unset>'} "
                    f"baseline_exists={baseline_exists} ({baseline or '<unset>'})",
                    file=sys.stderr,
                )

        if code == 5:
            print(f"✗ pytest [{run.group}] in {run.directory} collected no tests from its targets", file=sys.stderr)
        if code in (2, 3, 4):
            return code
        if code != 0:
            overall = code
    return overall


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    root = Path.cwd()
    env = dict(os.environ)

    # Environment hygiene
    env.pop("LD_PRELOAD", None)
    env.pop("AWS_ENDPOINT_URL", None)
    env.pop("AWS_ENDPOINT_URL_S3", None)
    env["PATH"] = f"{root / 'bin'}:{env.get('PATH', '')}"

    shard = env.get("ENACT_SHARD_INDEX") or env.get("SHARD") or "1"
    plugins_dir = str(root / "showcase" / "pytest_plugins")
    existing_pp = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = f"{plugins_dir}:{existing_pp}" if existing_pp else plugins_dir
    env["POSTHOG_REPO_ROOT"] = str(root)
    env.setdefault("ENACT_REPLAY_RESULTS", str(root / ".enact" / "state" / "pytest"))

    tzdir = resolve_tzdir(root, env)
    if tzdir:
        env["TZDIR"] = tzdir

    plugins = build_plugins(env)

    # Validate target args early (before touching services/files)
    try:
        targets = resolve_targets(args, env, shard)
    except TargetResolutionError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    services_active = is_services_active(env)
    if services_active:
        pg_host = env.get("PGHOST") or "127.0.0.1"
        pg_port = env["PGPORT"]
        pg_user = env.get("PGUSER") or "posthog"
        env["PGHOST"] = pg_host
        env["PGPORT"] = pg_port
        env["PGUSER"] = pg_user
        env["PGPASSWORD"] = "posthog"
        env["POSTHOG_DB_USER"] = pg_user
        env["POSTHOG_DB_PASSWORD"] = "posthog"
        env["POSTHOG_POSTGRES_PORT"] = pg_port
        env["POSTHOG_POSTGRES_HOST"] = pg_host
        _bootstrap_postgres_if_unmanaged(env)

    ensure_needed_files(root, env)

    if services_active:
        worker_id = provision_worker_databases(root, env, shard)
        baseline_file = root / ".enact" / "state" / f"ch-mat-baseline-{worker_id}.json"
        env["ENACT_CH_MAT_BASELINE_FILE"] = str(baseline_file)
        baseline_file.unlink(missing_ok=True)
        env["WAREHOUSE_SOURCES_DATABASE_URL"] = (
            f"postgres://{env['PGUSER']}:{env.get('PGPASSWORD', 'posthog')}"
            f"@{env['PGHOST']}:{env['PGPORT']}/test_posthog_{worker_id}"
        )
        _maybe_generate_shard_rsa_keys(root, env)

    env.pop("LD_PRELOAD", None)
    os_name = detect_os_name(env)
    tz_ld_preload = maybe_build_tz_shim(root, env, os_name)

    for key, default in (
        ("PYTHONNODEBUGRANGES", "1"),
        ("PYTHONDONTWRITEBYTECODE", "1"),
        ("MALLOC_ARENA_MAX", "2"),
        ("MALLOC_TRIM_THRESHOLD_", "131072"),
        ("MALLOC_MMAP_THRESHOLD_", "131072"),
        ("PYTHON_GC_THRESHOLD_0", "10000"),
        ("PYTHON_GC_THRESHOLD_1", "10"),
        ("PYTHON_GC_THRESHOLD_2", "10"),
        ("AWS_DEFAULT_REGION", "us-east-1"),
        ("AWS_REGION", "us-east-1"),
        ("AWS_S3_ADDRESSING_STYLE", "path"),
    ):
        env.setdefault(key, default)

    targets, left_out, dropped = filter_macos_targets(targets, root, os_name)
    for target in dropped:
        print(f"⊘ {target}: left out on macOS (chdb won't load there, U31)", file=sys.stderr)
    if not targets:
        print(f"⊘ run_sharded_pytest.sh: shard {shard}'s every target is left out on macOS", file=sys.stderr)
        return 0

    if env.get("ENACT_COLLECT_ONLY", "0") == "1":
        collect_env = dict(env)
        if tz_ld_preload:
            collect_env["LD_PRELOAD"] = tz_ld_preload
        cmd = [
            "python3",
            "showcase/scripts/backend_runtime.py",
            "exec",
            "uv",
            "run",
            "--no-sync",
            "python",
            "-m",
            "pytest",
            *plugins,
            *left_out,
            "-o",
            "pythonhashseed=0",
            "--collect-only",
            "-q",
            *targets,
        ]
        return subprocess.run(cmd, cwd=str(root), env=collect_env, close_fds=True, check=False).returncode

    plan_res = subprocess.run(
        ["python3", "showcase/scripts/product_pytest.py", "-"],
        input="\n".join(targets) + "\n",
        cwd=str(root),
        env=env,
        capture_output=True,
        text=True,
        close_fds=True,
        check=True,
    )
    runs = parse_planned_runs(plan_res.stdout)
    if not runs:
        print(
            f"✗ run_sharded_pytest.sh: product_pytest.py planned no pytest run for {len(targets)} target(s)",
            file=sys.stderr,
        )
        return 1

    reuse_db_arg = ["--reuse-db"] if services_active else []
    product_endpoint = product_object_storage_endpoint(env.get("OBJECT_STORAGE_ENDPOINT"))
    return execute_planned_runs(
        runs,
        root=root,
        base_env=env,
        plugins=plugins,
        left_out=left_out,
        reuse_db_arg=reuse_db_arg,
        services_active=services_active,
        tz_ld_preload=tz_ld_preload,
        product_endpoint=product_endpoint,
    )


if __name__ == "__main__":
    raise SystemExit(main())
