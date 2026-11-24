#!/usr/bin/env python3
"""Python orchestration for live PostHog stacks (run_e2e_tests.sh, run_mcp_integration.sh).

Replaces the bash flock / readiness / migration / worker-sizing logic that previously
lived in live_posthog.sh and run_e2e_tests.sh:
  - Uses fcntl.flock on O_CLOEXEC descriptors with subprocess(..., close_fds=True) so
    child processes and background daemons never inherit lock FDs (eliminating the bash
    FD-7 inheritance deadlock).
  - Preserves 100% of the ENACT_TEMPLATE_SNAPSHOT_DIR (1e85fa03a) and B4a per-key
    template_lock.sh contracts.
  - Caps Playwright E2E workers to PW=2 when effective CPUs <= 4, bounded by
    min(ENACT_WORKER_CPUS, live_cpus), and logs CPU inputs + chosen workers.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import fcntl
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable, Iterator, Mapping, Sequence

SCRIPTS_DIR = Path(__file__).resolve().parent


# ---------------------------------------------------------------------------
# Snapshot root & file locking (no FD inheritance to children)
# ---------------------------------------------------------------------------


def resolve_snapshot_root(env: Mapping[str, str] | None = None) -> Path:
    """Resolve the PostHog database snapshot root with the exact snapshot_root.sh precedence:

    1. Explicit SNAPSHOT_ROOT (if already set by caller)
    2. Explicit ENACT_TEMPLATE_SNAPSHOT_DIR
    3. Managed self-hosted runner with writable $ENACT_HOST_CACHE/repo:
         $ENACT_HOST_CACHE/repo/pg-templates
    4. Hosted / local fallback:
         $HOME/.cache/enact/snapshots
    """
    e = os.environ if env is None else env
    if e.get("SNAPSHOT_ROOT"):
        return Path(e["SNAPSHOT_ROOT"])
    if e.get("ENACT_TEMPLATE_SNAPSHOT_DIR"):
        return Path(e["ENACT_TEMPLATE_SNAPSHOT_DIR"])
    host = (e.get("ENACT_HOST_CACHE") or "").rstrip("/")
    if host:
        repo_dir = Path(host) / "repo"
        if repo_dir.is_dir() and os.access(repo_dir, os.W_OK):
            return repo_dir / "pg-templates"
    home = (e.get("HOME") or os.path.expanduser("~")).rstrip("/")
    return Path(home) / ".cache" / "enact" / "snapshots"


@contextlib.contextmanager
def exclusive_file_lock(lock_path: Path) -> Iterator[int]:
    """Acquire an exclusive flock on lock_path with O_CLOEXEC set.

    Because O_CLOEXEC is set (and os.set_inheritable(fd, False) is enforced), child
    processes spawned via subprocess.run(..., close_fds=True) never inherit the lock FD.
    """
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(str(lock_path), flags, 0o644)
    try:
        os.set_inheritable(fd, False)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            yield fd
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# E2E Playwright & Granian worker sizing (PW=2 cap on <= 4 effective CPUs)
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class E2EWorkerPlan:
    reserved_cpus: str
    live_cpus: int
    effective_cpus: int
    pw_workers: int
    granian_workers: int

    def log_line(self) -> str:
        return (
            f"e2e: reserved_cpus={self.reserved_cpus} live_cpus={self.live_cpus} "
            f"effective_cpus={self.effective_cpus} PW_WORKERS={self.pw_workers} "
            f"GRANIAN_WORKERS={self.granian_workers}"
        )


def detect_live_cpus(
    cgroup_cpu_max_path: str | Path = "/sys/fs/cgroup/cpu.max",
    cpu_count_fn: Callable[[], int | None] = os.cpu_count,
) -> int:
    """Return the live available CPU count, respecting Linux cgroup v2 cpu.max."""
    raw = cpu_count_fn()
    cpus = raw if isinstance(raw, int) and raw >= 1 else 4
    try:
        text = Path(cgroup_cpu_max_path).read_text(encoding="utf-8").strip()
    except OSError:
        return cpus
    parts = text.split()
    if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
        quota, period = int(parts[0]), int(parts[1])
        if period > 0:
            cg_cpus = max(1, quota // period)
            if cg_cpus < cpus:
                cpus = cg_cpus
    return cpus


_POSITIVE_NUM_RE = re.compile(r"^[0-9]+(?:\.[0-9]+)?$")


def compute_e2e_workers(
    reserved_cpus: str | int | float | None = None,
    live_cpus: int | None = None,
    playwright_override: str | int | None = None,
    granian_override: str | int | None = None,
) -> E2EWorkerPlan:
    """Compute Playwright and Granian worker counts for PostHog E2E.

    effective_cpus = min(ENACT_WORKER_CPUS, live_cpus) when ENACT_WORKER_CPUS is positive.
    When effective_cpus <= 4, Playwright workers are capped at 2 (1 on 1c) per G1 proof
    (229/230: PW=2 passes 37/37 under 4c/10GiB, PW=3 fails notebooks.spec.ts 0/3).
    """
    live = live_cpus if live_cpus is not None and live_cpus >= 1 else detect_live_cpus()
    reserved_str = "" if reserved_cpus is None else str(reserved_cpus).strip()
    effective = live
    reserved_label = "none"
    if reserved_str and _POSITIVE_NUM_RE.match(reserved_str):
        reserved_label = reserved_str
        reserved_int = int(reserved_str.split(".", 1)[0])
        if reserved_int >= 1 and reserved_int < effective:
            effective = reserved_int

    pw_override_str = "" if playwright_override is None else str(playwright_override).strip()
    if pw_override_str and pw_override_str.isdigit() and int(pw_override_str) >= 1:
        pw_workers = int(pw_override_str)
    elif effective <= 4:
        pw_workers = min(2, max(1, effective))
    else:
        pw_workers = min(6, max(1, (effective * 3) // 4))

    gr_override_str = "" if granian_override is None else str(granian_override).strip()
    if gr_override_str and gr_override_str.isdigit() and int(gr_override_str) >= 1:
        granian_workers = int(gr_override_str)
    else:
        granian_workers = min(4, max(1, effective // 2))

    return E2EWorkerPlan(
        reserved_cpus=reserved_label,
        live_cpus=live,
        effective_cpus=effective,
        pw_workers=pw_workers,
        granian_workers=granian_workers,
    )


# ---------------------------------------------------------------------------
# Ports & readiness probes
# ---------------------------------------------------------------------------


def allocate_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _default_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _default_http_probe(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=2.0):
            return True
    except urllib.error.HTTPError:
        # Matches `curl -s -o /dev/null <url>` (without -f): any HTTP response means ready.
        return True
    except (urllib.error.URLError, OSError, ValueError):
        return False


def _default_tcp_probe(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1.0):
            return True
    except OSError:
        return False


def wait_ready(
    name: str,
    pid: int,
    port: int,
    url: str,
    tries: int = 60,
    interval: float = 2.0,
    *,
    pid_alive_fn: Callable[[int], bool] = _default_pid_alive,
    http_probe_fn: Callable[[str], bool] = _default_http_probe,
    tcp_probe_fn: Callable[[int], bool] = _default_tcp_probe,
    sleep_fn: Callable[[float], None] = time.sleep,
) -> bool:
    """Wait until <url> answers or <port> accepts, failing immediately if <pid> exits."""
    for _ in range(max(1, tries)):
        if not pid_alive_fn(pid):
            print(f"{name} exited unexpectedly", file=sys.stderr)
            return False
        ready = http_probe_fn(url) if url != "-" else tcp_probe_fn(port)
        if ready:
            return True
        sleep_fn(interval)
    print(f"{name} is not ready after {int(tries * interval)} s", file=sys.stderr)
    return False


# ---------------------------------------------------------------------------
# Subprocess helpers (close_fds=True always)
# ---------------------------------------------------------------------------


def _run(
    cmd: Sequence[str],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    capture_output: bool = False,
    check: bool = True,
    stdout=None,
    stderr=None,
) -> subprocess.CompletedProcess[str]:
    kwargs: dict = {
        "cwd": str(cwd) if cwd is not None else None,
        "env": dict(env) if env is not None else None,
        "text": True,
        "close_fds": True,
        "check": check,
    }
    if capture_output:
        kwargs["capture_output"] = True
    else:
        if stdout is not None:
            kwargs["stdout"] = stdout
        if stderr is not None:
            kwargs["stderr"] = stderr
    return subprocess.run(list(cmd), **kwargs)


def pg_query(
    db: str,
    sql: str,
    *,
    env: Mapping[str, str] | None = None,
    field_sep: str | None = None,
    runner: Callable[..., subprocess.CompletedProcess[str]] = _run,
) -> str:
    e = os.environ if env is None else env
    cmd = [
        "psql",
        "-h",
        e.get("PGHOST", "127.0.0.1"),
        "-p",
        e["PGPORT"],
        "-U",
        e.get("PGUSER", "posthog"),
        "-d",
        db,
        "-X",
        "-t",
        "-A",
        "-v",
        "ON_ERROR_STOP=1",
    ]
    if field_sep is not None:
        cmd.extend(["-F", field_sep])
    cmd.extend(["-c", sql])
    res = runner(cmd, env=e, capture_output=True, check=True)
    return res.stdout.strip()


def wait_db_free(
    db: str,
    *,
    timeout: int | None = None,
    env: Mapping[str, str] | None = None,
    query_fn: Callable[..., str] = pg_query,
    sleep_fn: Callable[[float], None] = time.sleep,
    monotonic_fn: Callable[[], float] = time.monotonic,
) -> bool:
    e = os.environ if env is None else env
    limit = timeout if timeout is not None else int(e.get("ENACT_TEMPLATE_FREE_TIMEOUT", "60"))
    deadline = monotonic_fn() + limit
    while True:
        sessions = query_fn("postgres", f"SELECT count(*) FROM pg_stat_activity WHERE datname = '{db}'", env=e) or "0"
        if sessions == "0":
            return True
        if monotonic_fn() >= deadline:
            print(f"{db} still has {sessions} sessions", file=sys.stderr)
            return False
        sleep_fn(1.0)


def pg_template_ready(
    template_db: str,
    format_comment: str,
    *,
    env: Mapping[str, str] | None = None,
    query_fn: Callable[..., str] = pg_query,
) -> bool:
    count = query_fn(
        "postgres",
        f"SELECT count(*) FROM pg_database WHERE datname = '{template_db}' "
        f"AND shobj_description(oid, 'pg_database') = '{format_comment}'",
        env=env,
    )
    if count != "1":
        return False
    exists = query_fn(
        template_db,
        "SELECT to_regclass('public.posthog_organization') IS NOT NULL",
        env=env,
    )
    return exists == "t"


# ---------------------------------------------------------------------------
# Postgres & ClickHouse live migration orchestration
# ---------------------------------------------------------------------------


def _pg_restore(db: str, dump_file: str, env: Mapping[str, str], runner=_run) -> bool:
    cmd = [
        "pg_restore",
        "-h",
        env.get("PGHOST", "127.0.0.1"),
        "-p",
        env["PGPORT"],
        "-U",
        env.get("PGUSER", "posthog"),
        "--no-owner",
        "--no-privileges",
        "-d",
        db,
        dump_file,
    ]
    res = runner(cmd, env=env, stdout=subprocess.DEVNULL, check=False)
    return res.returncode == 0


def _pg_dump(db: str, dump_file: str, env: Mapping[str, str], runner=_run) -> None:
    cmd = [
        "pg_dump",
        "-h",
        env.get("PGHOST", "127.0.0.1"),
        "-p",
        env["PGPORT"],
        "-U",
        env.get("PGUSER", "posthog"),
        "-Fc",
        "-f",
        dump_file,
        db,
    ]
    runner(cmd, env=env, check=True)


def _fresh_django_clone_via_templates(repo: Path, live_db: str, env: Mapping[str, str], runner=_run) -> None:
    """Fallback to test_databases.sh + template_lock.sh (`with_templates fresh_django_clone`)."""
    script = (
        "set -euo pipefail; "
        'if [ -f showcase/scripts/snapshot_root.sh ]; then source showcase/scripts/snapshot_root.sh; fi; '
        "source showcase/scripts/test_databases.sh; "
        'if [ -f showcase/scripts/template_lock.sh ]; then source showcase/scripts/template_lock.sh; fi; '
        'with_templates fresh_django_clone "$1"'
    )
    runner(["bash", "-c", script, "_", live_db], cwd=repo, env=env, check=True)


def migrate_pg(
    *,
    repo: Path,
    snapshot_root: Path,
    live_db: str,
    template_key: str,
    env: Mapping[str, str] | None = None,
    runner: Callable[..., subprocess.CompletedProcess[str]] = _run,
    query_fn: Callable[..., str] | None = None,
    fresh_clone_fn: Callable[[Path, str, Mapping[str, str]], None] | None = None,
) -> str:
    """Run live Postgres migrations with cluster template + snapshot caching under an O_CLOEXEC lock.

    Returns a status tag: "cluster_hit", "snapshot_hit", "incremental", or "cold".
    """
    e = dict(os.environ if env is None else env)
    q = query_fn or (lambda db, sql, **kw: pg_query(db, sql, env=kw.pop("env", e), runner=runner, **kw))
    clone_fallback = fresh_clone_fn or (lambda r, d, ev: _fresh_django_clone_via_templates(r, d, ev, runner=runner))
    cache_script = str(repo / "showcase" / "scripts" / "live_migrate_cache.py")

    version_num = int(q("postgres", "SHOW server_version_num").split()[0])
    pg_major = str(version_num // 10000)

    key = runner(
        [sys.executable, cache_script, "pg-key", "--repo", ".", "--template-key", template_key, "--pg-major", pg_major],
        cwd=repo,
        env=e,
        capture_output=True,
        check=True,
    ).stdout.strip()
    tpl = f"posthog_live_template_{key[:12]}"
    fmt = f"enact-live-pg-v1:{key}"
    lock_path = snapshot_root / "live-v1" / f"{key}.migrate.lock"

    with exclusive_file_lock(lock_path):
        if pg_template_ready(tpl, fmt, env=e, query_fn=q):
            if not wait_db_free(tpl, env=e, query_fn=q):
                raise RuntimeError(f"template {tpl} remained busy")
            q("postgres", f"DROP DATABASE IF EXISTS {live_db} WITH (FORCE);")
            q("postgres", f"CREATE DATABASE {live_db} TEMPLATE {tpl};")
            print(f"live-pg cluster hit: {tpl}", file=sys.stderr)
            return "cluster_hit"

        verify_res = runner(
            [
                sys.executable,
                cache_script,
                "pg-verify",
                "--snapshot-root",
                str(snapshot_root),
                "--key",
                key,
                "--pg-major",
                pg_major,
            ],
            cwd=repo,
            env=e,
            capture_output=True,
            check=False,
        )
        if verify_res.returncode == 0 and verify_res.stdout.strip():
            gen_dir = verify_res.stdout.strip()
            if not wait_db_free(tpl, env=e, query_fn=q):
                raise RuntimeError(f"template {tpl} remained busy")
            q("postgres", f"DROP DATABASE IF EXISTS {tpl} WITH (FORCE);")
            q("postgres", f"CREATE DATABASE {tpl};")
            if _pg_restore(tpl, os.path.join(gen_dir, "live-postgres.dump"), e, runner=runner):
                q("postgres", f"COMMENT ON DATABASE {tpl} IS '{fmt}';")
                if not wait_db_free(tpl, env=e, query_fn=q):
                    raise RuntimeError(f"template {tpl} remained busy")
                q("postgres", f"DROP DATABASE IF EXISTS {live_db} WITH (FORCE);")
                q("postgres", f"CREATE DATABASE {live_db} TEMPLATE {tpl};")
                print(f"live-pg snapshot hit: {gen_dir}", file=sys.stderr)
                return "snapshot_hit"
            try:
                q("postgres", f"DROP DATABASE IF EXISTS {tpl} WITH (FORCE);")
            except Exception:
                pass

        migrated = False
        base_res = runner(
            [
                sys.executable,
                cache_script,
                "pg-base",
                "--snapshot-root",
                str(snapshot_root),
                "--repo",
                ".",
                "--template-key",
                template_key,
                "--pg-major",
                pg_major,
            ],
            cwd=repo,
            env=e,
            capture_output=True,
            check=False,
        )
        base_dir = base_res.stdout.strip() if base_res.returncode == 0 else ""
        if base_dir:
            q("postgres", f"DROP DATABASE IF EXISTS {live_db} WITH (FORCE);")
            q("postgres", f"CREATE DATABASE {live_db};")
            if _pg_restore(live_db, os.path.join(base_dir, "live-postgres.dump"), e, runner=runner):
                mig_res = runner(
                    ["uv", "run", "--no-sync", "python", "manage.py", "migrate", "--noinput"],
                    cwd=repo,
                    env=e,
                    check=False,
                )
                if mig_res.returncode == 0:
                    migrated = True
                    print(f"live-pg incremental top-up succeeded from {base_dir}", file=sys.stderr)
            if not migrated:
                print(
                    f"live-pg incremental top-up failed from {base_dir}; falling back to template clone",
                    file=sys.stderr,
                )
                clone_fallback(repo, live_db, e)

        if not migrated:
            apps = runner(
                [sys.executable, cache_script, "routed-apps", "--repo", "."],
                cwd=repo,
                env=e,
                capture_output=True,
                check=True,
            ).stdout.strip()
            if apps:
                q(live_db, f"DELETE FROM django_migrations WHERE app IN ({apps});")
            runner(
                ["uv", "run", "--no-sync", "python", "manage.py", "migrate", "--noinput"],
                cwd=repo,
                env=e,
                check=True,
            )

        runner(
            ["uv", "run", "--no-sync", "python", "manage.py", "migrate", "--check", "--noinput"],
            cwd=repo,
            env=e,
            stdout=subprocess.DEVNULL,
            check=True,
        )

        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_dump = os.path.join(tmp_dir, "live-postgres.dump")
            tmp_applied = os.path.join(tmp_dir, "applied.tsv")
            _pg_dump(live_db, tmp_dump, e, runner=runner)
            applied_text = q(
                live_db,
                "SELECT app, name FROM django_migrations ORDER BY app, name",
                field_sep="\t",
            )
            Path(tmp_applied).write_text(applied_text + ("\n" if applied_text else ""), encoding="utf-8")
            published_dir = runner(
                [
                    sys.executable,
                    cache_script,
                    "pg-publish",
                    "--snapshot-root",
                    str(snapshot_root),
                    "--repo",
                    ".",
                    "--key",
                    key,
                    "--pg-major",
                    pg_major,
                    "--template-key",
                    template_key,
                    "--dump-file",
                    tmp_dump,
                    "--applied-file",
                    tmp_applied,
                ],
                cwd=repo,
                env=e,
                capture_output=True,
                check=True,
            ).stdout.strip()
            print(f"live-pg published snapshot: {published_dir}", file=sys.stderr)

        if not wait_db_free(live_db, env=e, query_fn=q):
            raise RuntimeError(f"database {live_db} remained busy")
        if not wait_db_free(tpl, env=e, query_fn=q):
            raise RuntimeError(f"template {tpl} remained busy")
        q("postgres", f"DROP DATABASE IF EXISTS {tpl} WITH (FORCE);")
        q("postgres", f"CREATE DATABASE {tpl} TEMPLATE {live_db};")
        q("postgres", f"COMMENT ON DATABASE {tpl} IS '{fmt}';")
        return "incremental" if migrated else "cold"


def clean_ch_keeper(
    ch_db: str,
    *,
    env: Mapping[str, str] | None = None,
    runner: Callable[..., subprocess.CompletedProcess[str]] = _run,
) -> None:
    e = os.environ if env is None else env
    keeper_port = e.get("ENVE_SERVICE_CLICKHOUSE_PORT_KEEPER")
    if keeper_port and shutil.which("clickhouse", path=e.get("PATH")):
        runner(
            [
                "clickhouse",
                "keeper-client",
                "--port",
                keeper_port,
                "-q",
                f"rmr /clickhouse/prod/tables/noshard/{ch_db}",
            ],
            env=e,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )


def migrate_ch(
    *,
    repo: Path,
    snapshot_root: Path,
    ch_cmd: Sequence[str],
    ch_db: str,
    live_worker: str,
    logs_dir: Path,
    env: Mapping[str, str] | None = None,
    runner: Callable[..., subprocess.CompletedProcess[str]] = _run,
) -> str:
    """Run ClickHouse live migrations with snapshot caching under an O_CLOEXEC lock.

    Returns a status tag: "exact_hit", "locked_hit", "incremental", or "cold".
    """
    e = dict(os.environ if env is None else env)
    cache_script = str(repo / "showcase" / "scripts" / "live_migrate_cache.py")
    logs_dir.mkdir(parents=True, exist_ok=True)
    ch_restore_log = logs_dir / "ch-restore.log"

    ch_version = "".join(
        runner([*ch_cmd, "-q", "SELECT version()"], cwd=repo, env=e, capture_output=True, check=True).stdout.split()
    )
    ch_http_port = e.get("CLICKHOUSE_HTTP_PORT")
    if not ch_http_port:
        raise RuntimeError("CLICKHOUSE_HTTP_PORT: the env ClickHouse HTTP port is required")
    kafka_hosts = e.get("KAFKA_HOSTS")
    if not kafka_hosts:
        raise RuntimeError("KAFKA_HOSTS: the env Kafka bootstrap is required")
    ch_http_url = f"http://{e.get('CLICKHOUSE_HOST', '127.0.0.1')}:{ch_http_port}"
    ch_user = e.get("CLICKHOUSE_USER", "default")
    ch_password = e.get("CLICKHOUSE_PASSWORD", "")

    ch_key = runner(
        [sys.executable, cache_script, "ch-key", "--repo", ".", "--ch-version", ch_version],
        cwd=repo,
        env=e,
        capture_output=True,
        check=True,
    ).stdout.strip()

    restore_common = [
        sys.executable,
        cache_script,
        "ch-restore",
        "--snapshot-root",
        str(snapshot_root),
        "--repo",
        ".",
        "--key",
        ch_key,
        "--ch-version",
        ch_version,
        "--http-url",
        ch_http_url,
        "--ch-db",
        ch_db,
        "--kafka-prefix",
        f"{live_worker}_",
        "--kafka-broker",
        kafka_hosts,
        "--user",
        ch_user,
        "--password",
        ch_password,
    ]

    mode = ""
    res = runner(restore_common, cwd=repo, env=e, capture_output=True, check=False)
    ch_restore_log.write_text(res.stderr or "", encoding="utf-8")
    if res.returncode == 0:
        mode = (res.stdout or "").strip()
    else:
        ch_v1_dir = snapshot_root / "ch-v1"
        if ch_v1_dir.is_dir() and any(ch_v1_dir.iterdir()):
            print(f"live-ch restore miss/failed (see {ch_restore_log})", file=sys.stderr)

    if mode == "exact":
        chk = runner(
            ["uv", "run", "--no-sync", "python", "manage.py", "migrate_clickhouse", "--check"],
            cwd=repo,
            env=e,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if chk.returncode == 0:
            print(f"live-ch snapshot hit: {ch_key}", file=sys.stderr)
            return "exact_hit"
        print("live-ch snapshot failed migrate_clickhouse --check; rebuilding cold", file=sys.stderr)
        mode = ""

    lock_path = snapshot_root / "ch-v1" / f"{ch_key}.migrate.lock"
    with exclusive_file_lock(lock_path):
        if mode != "base":
            res2 = runner([*restore_common, "--exact-only"], cwd=repo, env=e, capture_output=True, check=False)
            if res2.stderr:
                with ch_restore_log.open("a", encoding="utf-8") as fh:
                    fh.write(res2.stderr)
            if res2.returncode == 0:
                chk2 = runner(
                    ["uv", "run", "--no-sync", "python", "manage.py", "migrate_clickhouse", "--check"],
                    cwd=repo,
                    env=e,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )
                if chk2.returncode == 0:
                    print(f"live-ch snapshot hit after lock: {ch_key}", file=sys.stderr)
                    return "locked_hit"

        def _cold_rebuild() -> None:
            runner([*ch_cmd, "-q", f"DROP DATABASE IF EXISTS {ch_db} SYNC"], cwd=repo, env=e, stdout=subprocess.DEVNULL, check=True)
            clean_ch_keeper(ch_db, env=e, runner=runner)
            runner([*ch_cmd, "-q", "SYSTEM FLUSH LOGS"], cwd=repo, env=e, stdout=subprocess.DEVNULL, check=True)
            runner(["uv", "run", "--no-sync", "python", "manage.py", "migrate_clickhouse"], cwd=repo, env=e, check=True)

        result_tag = "cold"
        if mode == "base":
            print("live-ch incremental top-up from subset base", file=sys.stderr)
            inc = runner(["uv", "run", "--no-sync", "python", "manage.py", "migrate_clickhouse"], cwd=repo, env=e, check=False)
            if inc.returncode == 0:
                result_tag = "incremental"
            else:
                print("live-ch incremental top-up failed; rebuilding cold", file=sys.stderr)
                _cold_rebuild()
        else:
            _cold_rebuild()

        runner(
            ["uv", "run", "--no-sync", "python", "manage.py", "migrate_clickhouse", "--check"],
            cwd=repo,
            env=e,
            stdout=subprocess.DEVNULL,
            check=True,
        )
        runner(
            [
                sys.executable,
                cache_script,
                "ch-capture",
                "--snapshot-root",
                str(snapshot_root),
                "--repo",
                ".",
                "--key",
                ch_key,
                "--ch-version",
                ch_version,
                "--http-url",
                ch_http_url,
                "--ch-db",
                ch_db,
                "--kafka-prefix",
                f"{live_worker}_",
                "--kafka-broker",
                kafka_hosts,
                "--user",
                ch_user,
                "--password",
                ch_password,
            ],
            cwd=repo,
            env=e,
            stdout=subprocess.DEVNULL,
            check=True,
        )
        return result_tag


# ---------------------------------------------------------------------------
# Prebuilt Rust footprint merge & Kafka topic creation
# ---------------------------------------------------------------------------


def merge_prebuilt_rust_footprint(built_path: Path, out_dir: Path, map_paths: Sequence[Path]) -> None:
    built_doc = json.loads(built_path.read_text(encoding="utf-8"))
    built_shared = built_doc.get("shared") or {}
    built_files = set(built_shared.get("files") or ())
    built_recs = set(built_shared.get("recorders") or ("rust_footprint.py/3",))
    out_dir.mkdir(parents=True, exist_ok=True)
    for map_path in map_paths:
        doc = json.loads(map_path.read_text(encoding="utf-8"))
        shared = doc.setdefault("shared", {})
        shared["files"] = sorted(set(shared.get("files") or ()) | built_files)
        shared["recorders"] = sorted(set(shared.get("recorders") or ()) | built_recs)
        for fp in (doc.get("targets") or {}).values():
            if isinstance(fp, dict):
                fp["recorders"] = sorted(set(fp.get("recorders") or ()) | built_recs)
        dst = out_dir / map_path.name
        dst.write_text(json.dumps(doc, separators=(",", ":")), encoding="utf-8")


def create_kafka_topics() -> int:
    """Create the live stack's prefixed Kafka topics (runs under uv run --no-sync python)."""
    sys.path.insert(0, str(SCRIPTS_DIR))
    from confluent_kafka.admin import AdminClient, NewTopic  # type: ignore[import-not-found]
    import create_test_kafka_topics as topics  # type: ignore[import-not-found]

    prefix = os.environ["KAFKA_PREFIX"]
    admin = AdminClient({"bootstrap.servers": os.environ["KAFKA_HOSTS"]})
    existing = set(admin.list_topics(timeout=30).topics)
    wanted = sorted({prefix + t for t in set(topics.topic_names()) | topics.listed_topics()} - existing)
    if wanted:
        for future in admin.create_topics([NewTopic(t, num_partitions=1, replication_factor=1) for t in wanted]).values():
            future.result()
    print(f"created {len(wanted)} Kafka topics under {prefix}")
    return len(wanted)


# ---------------------------------------------------------------------------
# CLI entrypoint
# ---------------------------------------------------------------------------


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="live_posthog.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("snapshot-root")
    sub.add_parser("free-port")
    sub.add_parser("create-topics")

    p_e2e = sub.add_parser("e2e-workers")
    p_e2e.add_argument("--shell", action="store_true", help="Emit shell assignments to stdout and log line to stderr")

    p_wait = sub.add_parser("wait-ready")
    p_wait.add_argument("--name", required=True)
    p_wait.add_argument("--pid", type=int, required=True)
    p_wait.add_argument("--port", type=int, required=True)
    p_wait.add_argument("--url", required=True)
    p_wait.add_argument("--tries", type=int, default=60)
    p_wait.add_argument("--interval", type=float, default=2.0)

    p_db_free = sub.add_parser("wait-db-free")
    p_db_free.add_argument("--db", required=True)

    p_pg_ready = sub.add_parser("pg-template-ready")
    p_pg_ready.add_argument("--template-db", required=True)
    p_pg_ready.add_argument("--format-comment", required=True)

    p_mig_pg = sub.add_parser("migrate-pg")
    p_mig_pg.add_argument("--repo", default=".")
    p_mig_pg.add_argument("--snapshot-root", required=True)
    p_mig_pg.add_argument("--live-db", required=True)
    p_mig_pg.add_argument("--template-key", required=True)

    p_keeper = sub.add_parser("clean-ch-keeper")
    p_keeper.add_argument("--ch-db", required=True)

    p_mig_ch = sub.add_parser("migrate-ch")
    p_mig_ch.add_argument("--repo", default=".")
    p_mig_ch.add_argument("--snapshot-root", required=True)
    p_mig_ch.add_argument("--ch-cmd-json", required=True)
    p_mig_ch.add_argument("--ch-db", required=True)
    p_mig_ch.add_argument("--live-worker", required=True)
    p_mig_ch.add_argument("--logs-dir", required=True)

    p_merge = sub.add_parser("merge-prebuilt-rust-footprint")
    p_merge.add_argument("--built", required=True)
    p_merge.add_argument("--out-dir", required=True)
    p_merge.add_argument("maps", nargs="+")

    args = parser.parse_args(list(argv) if argv is not None else None)

    if args.cmd == "snapshot-root":
        print(resolve_snapshot_root())
        return 0

    if args.cmd == "free-port":
        print(allocate_free_port())
        return 0

    if args.cmd == "create-topics":
        create_kafka_topics()
        return 0

    if args.cmd == "e2e-workers":
        plan = compute_e2e_workers(
            reserved_cpus=os.environ.get("ENACT_WORKER_CPUS"),
            playwright_override=os.environ.get("PLAYWRIGHT_WORKERS"),
            granian_override=os.environ.get("GRANIAN_WORKERS"),
        )
        print(plan.log_line(), file=sys.stderr)
        if args.shell:
            print(f"PW_WORKERS={plan.pw_workers}")
            print(f"PLAYWRIGHT_WORKERS={plan.pw_workers}")
            print(f"GRANIAN_WORKERS={plan.granian_workers}")
            print(f"PW_RESERVED_CPUS={plan.reserved_cpus}")
            print(f"PW_LIVE_CPUS={plan.live_cpus}")
            print(f"PW_EFFECTIVE_CPUS={plan.effective_cpus}")
        else:
            print(json.dumps(dataclasses.asdict(plan)))
        return 0

    if args.cmd == "wait-ready":
        ok = wait_ready(args.name, args.pid, args.port, args.url, tries=args.tries, interval=args.interval)
        return 0 if ok else 1

    if args.cmd == "wait-db-free":
        return 0 if wait_db_free(args.db) else 1

    if args.cmd == "pg-template-ready":
        return 0 if pg_template_ready(args.template_db, args.format_comment) else 1

    if args.cmd == "migrate-pg":
        migrate_pg(
            repo=Path(args.repo).resolve(),
            snapshot_root=Path(args.snapshot_root),
            live_db=args.live_db,
            template_key=args.template_key,
        )
        return 0

    if args.cmd == "clean-ch-keeper":
        clean_ch_keeper(args.ch_db)
        return 0

    if args.cmd == "migrate-ch":
        ch_cmd = json.loads(args.ch_cmd_json)
        migrate_ch(
            repo=Path(args.repo).resolve(),
            snapshot_root=Path(args.snapshot_root),
            ch_cmd=ch_cmd,
            ch_db=args.ch_db,
            live_worker=args.live_worker,
            logs_dir=Path(args.logs_dir),
        )
        return 0

    if args.cmd == "merge-prebuilt-rust-footprint":
        merge_prebuilt_rust_footprint(
            Path(args.built),
            Path(args.out_dir),
            [Path(m) for m in args.maps],
        )
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
