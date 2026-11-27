"""Unit tests for live_posthog.py orchestration and E2E PW=2 worker cap."""

from __future__ import annotations

import contextlib
import fcntl
import io
import json
import os
import re
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
OVERLAY = SCRIPTS.parents[1]
sys.path.insert(0, str(SCRIPTS))

import live_posthog as lp  # noqa: E402


class E2EWorkerCapTest(unittest.TestCase):
    def test_caps_pw_workers_at_2_for_four_or_fewer_effective_cpus(self) -> None:
        self.assertEqual(lp.compute_e2e_workers(reserved_cpus=4, live_cpus=4).pw_workers, 2)
        self.assertEqual(lp.compute_e2e_workers(reserved_cpus=4, live_cpus=8).pw_workers, 2)
        self.assertEqual(lp.compute_e2e_workers(reserved_cpus=3, live_cpus=8).pw_workers, 2)
        self.assertEqual(lp.compute_e2e_workers(reserved_cpus=2, live_cpus=8).pw_workers, 2)
        self.assertEqual(lp.compute_e2e_workers(reserved_cpus=1, live_cpus=8).pw_workers, 1)

    def test_bounds_effective_cpus_by_min_of_reserved_and_live(self) -> None:
        # live_cpus < reserved_cpus -> bounded by live_cpus
        plan = lp.compute_e2e_workers(reserved_cpus="8", live_cpus=4)
        self.assertEqual(plan.reserved_cpus, "8")
        self.assertEqual(plan.live_cpus, 4)
        self.assertEqual(plan.effective_cpus, 4)
        self.assertEqual(plan.pw_workers, 2)
        self.assertEqual(plan.granian_workers, 2)

        # reserved_cpus < live_cpus (float string) -> bounded by reserved_cpus
        plan2 = lp.compute_e2e_workers(reserved_cpus="4.0", live_cpus=16)
        self.assertEqual(plan2.effective_cpus, 4)
        self.assertEqual(plan2.pw_workers, 2)
        self.assertEqual(plan2.granian_workers, 2)

        # reserved_cpus unset -> uses live_cpus
        plan3 = lp.compute_e2e_workers(reserved_cpus=None, live_cpus=4)
        self.assertEqual(plan3.reserved_cpus, "none")
        self.assertEqual(plan3.effective_cpus, 4)
        self.assertEqual(plan3.pw_workers, 2)

    def test_scales_above_four_effective_cpus_up_to_six(self) -> None:
        plan6 = lp.compute_e2e_workers(reserved_cpus=6, live_cpus=8)
        self.assertEqual(plan6.effective_cpus, 6)
        self.assertEqual(plan6.pw_workers, 4)
        self.assertEqual(plan6.granian_workers, 3)

        plan8 = lp.compute_e2e_workers(reserved_cpus=8, live_cpus=8)
        self.assertEqual(plan8.effective_cpus, 8)
        self.assertEqual(plan8.pw_workers, 6)
        self.assertEqual(plan8.granian_workers, 4)

        plan16 = lp.compute_e2e_workers(reserved_cpus=16, live_cpus=16)
        self.assertEqual(plan16.pw_workers, 6)
        self.assertEqual(plan16.granian_workers, 4)

    def test_respects_explicit_env_overrides(self) -> None:
        plan = lp.compute_e2e_workers(
            reserved_cpus=4, live_cpus=4, playwright_override="3", granian_override="1"
        )
        self.assertEqual(plan.pw_workers, 3)
        self.assertEqual(plan.granian_workers, 1)

    def test_detect_live_cpus_reads_cgroup_cpu_max(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cg = Path(tmp) / "cpu.max"
            cg.write_text("400000 100000\n", encoding="utf-8")
            self.assertEqual(lp.detect_live_cpus(cg, cpu_count_fn=lambda: 16), 4)

            cg.write_text("max 100000\n", encoding="utf-8")
            self.assertEqual(lp.detect_live_cpus(cg, cpu_count_fn=lambda: 16), 16)

            cg.write_text("50000 100000\n", encoding="utf-8")
            self.assertEqual(lp.detect_live_cpus(cg, cpu_count_fn=lambda: 16), 1)

            cg.write_text("1600000 100000\n", encoding="utf-8")
            self.assertEqual(lp.detect_live_cpus(cg, cpu_count_fn=lambda: 4), 4)

    def test_cli_e2e_workers_shell_and_log_line(self) -> None:
        res = subprocess.run(
            [sys.executable, str(SCRIPTS / "live_posthog.py"), "e2e-workers", "--shell"],
            env={**os.environ, "ENACT_WORKER_CPUS": "4", "PLAYWRIGHT_WORKERS": "", "GRANIAN_WORKERS": ""},
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("PW_WORKERS=2", res.stdout)
        self.assertIn("PLAYWRIGHT_WORKERS=2", res.stdout)
        self.assertIn("reserved_cpus=4", res.stderr)
        self.assertIn("live_cpus=", res.stderr)
        self.assertIn("effective_cpus=", res.stderr)
        self.assertIn("PW_WORKERS=2", res.stderr)

    def test_e2e_runner_wiring_and_github_worker_pin(self) -> None:
        run_e2e = (SCRIPTS / "run_e2e_tests.sh").read_text(encoding="utf-8")
        self.assertIn("live_posthog.py", run_e2e)
        self.assertIn("e2e-workers --shell", run_e2e)
        self.assertIn('--workers="$workers"', run_e2e)
        self.assertIn('e2e_run_batch "${PW_WORKERS:-2}"', run_e2e)
        self.assertIn('e2e_run_batch 1 "${serial_specs[@]}"', run_e2e)

        # Per Opus 230: e2e:test must stay pinned to hosted ubuntu-24.04 (`worker: "github"`).
        components = (OVERLAY / ".enact/components.cue").read_text(encoding="utf-8")
        m = re.search(r'"e2e":\s*\{.*?test:\s*\{(.*?)\n\t\t\t\t\}', components, re.DOTALL)
        self.assertIsNotNone(m, "could not locate e2e:test block in components.cue")
        assert m is not None
        self.assertIn('worker:           "github"', m.group(1))

    def test_notebooks_spec_isolated_to_one_worker_on_four_cpus(self) -> None:
        run_e2e = (SCRIPTS / "run_e2e_tests.sh").read_text(encoding="utf-8")
        m = re.search(r"(e2e_run\(\) \{.*?\n\})", run_e2e, re.DOTALL)
        self.assertIsNotNone(m, "could not locate e2e_run() in run_e2e_tests.sh")
        assert m is not None
        fn_src = m.group(1)

        def run_case(eff_cpus: int, pw_workers: int, specs: list[str]) -> list[str]:
            script = (
                "set -euo pipefail\n"
                "e2e_run_batch() { printf 'BATCH:%s\\n' \"$*\"; }\n"
                f"{fn_src}\n"
                f"PW_EFFECTIVE_CPUS={eff_cpus} PW_WORKERS={pw_workers} e2e_run \"$@\"\n"
            )
            res = subprocess.run(
                ["bash", "-c", script, "_", *specs],
                capture_output=True,
                text=True,
                check=True,
            )
            return [line for line in res.stdout.splitlines() if line.startswith("BATCH:")]

        nb = "playwright/e2e/product-analytics/notebooks.spec.ts"
        other = "playwright/e2e/product-analytics/insights.spec.ts"
        self.assertEqual(
            run_case(4, 2, [other, nb]),
            [f"BATCH:2 {other}", f"BATCH:1 {nb}"],
        )
        self.assertEqual(
            run_case(4, 2, [nb]),
            [f"BATCH:1 {nb}"],
        )
        self.assertEqual(
            run_case(8, 6, [other, nb]),
            [f"BATCH:6 {other} {nb}"],
        )


class LivePosthogLockAndReadinessTest(unittest.TestCase):
    def test_exclusive_file_lock_does_not_leak_fd_to_child_daemons(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            lock_path = Path(tmp) / "live-v1" / "abc.migrate.lock"
            child_pid_file = Path(tmp) / "daemon.pid"

            with lp.exclusive_file_lock(lock_path) as fd:
                self.assertFalse(os.get_inheritable(fd), "lock FD must be O_CLOEXEC / non-inheritable")
                # Spawn a child that launches a detached background sleeper (modeling a
                # daemon or grandchild that outlives the lock holder). With bash `7>lock`,
                # the grandchild inherited FD 7 and deadlocked subsequent lockers.
                subprocess.run(
                    [
                        sys.executable,
                        "-c",
                        (
                            "import pathlib, subprocess, sys; "
                            "p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], "
                            "start_new_session=True, stdin=subprocess.DEVNULL, "
                            "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
                            f"pathlib.Path({str(child_pid_file)!r}).write_text(str(p.pid))"
                        ),
                    ],
                    close_fds=True,
                    check=True,
                )

            daemon_pid = int(child_pid_file.read_text(encoding="utf-8").strip())
            try:
                # Immediately after exiting `exclusive_file_lock`, a non-blocking exclusive
                # flock MUST succeed even while the background grandchild is still alive.
                probe_fd = os.open(str(lock_path), os.O_RDWR)
                try:
                    fcntl.flock(probe_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(probe_fd, fcntl.LOCK_UN)
                finally:
                    os.close(probe_fd)
            finally:
                try:
                    os.kill(daemon_pid, 9)
                except ProcessLookupError:
                    pass

    def test_live_posthog_sh_has_no_bash_flock_calls(self) -> None:
        sh_text = (SCRIPTS / "live_posthog.sh").read_text(encoding="utf-8")
        self.assertNotRegex(sh_text, r"^\s*flock\b", "live_posthog.sh must delegate locking to live_posthog.py")

    def test_resolve_snapshot_root_precedence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            hc = base / "host-cache"
            (hc / "repo").mkdir(parents=True)
            home = base / "home"
            home.mkdir()

            # 1. Explicit SNAPSHOT_ROOT wins over all
            self.assertEqual(
                lp.resolve_snapshot_root(
                    {
                        "SNAPSHOT_ROOT": str(base / "snap"),
                        "ENACT_TEMPLATE_SNAPSHOT_DIR": str(base / "tpl"),
                        "ENACT_HOST_CACHE": str(hc),
                        "HOME": str(home),
                    }
                ),
                base / "snap",
            )
            # 2. Explicit ENACT_TEMPLATE_SNAPSHOT_DIR wins over ENACT_HOST_CACHE
            self.assertEqual(
                lp.resolve_snapshot_root(
                    {
                        "ENACT_TEMPLATE_SNAPSHOT_DIR": str(base / "tpl"),
                        "ENACT_HOST_CACHE": str(hc),
                        "HOME": str(home),
                    }
                ),
                base / "tpl",
            )
            # 3. Writable ENACT_HOST_CACHE/repo -> pg-templates
            self.assertEqual(
                lp.resolve_snapshot_root({"ENACT_HOST_CACHE": str(hc), "HOME": str(home)}),
                hc / "repo" / "pg-templates",
            )
            # 4. Unwritable ENACT_HOST_CACHE/repo falls back to HOME/.cache/enact/snapshots
            (hc / "repo").chmod(stat.S_IRUSR | stat.S_IXUSR)
            try:
                self.assertEqual(
                    lp.resolve_snapshot_root({"ENACT_HOST_CACHE": str(hc), "HOME": str(home)}),
                    home / ".cache" / "enact" / "snapshots",
                )
            finally:
                (hc / "repo").chmod(0o755)
            # 5. Hosted/local fallback
            self.assertEqual(
                lp.resolve_snapshot_root({"HOME": str(home)}),
                home / ".cache" / "enact" / "snapshots",
            )

    def test_wait_ready_http_tcp_dead_pid_and_timeout(self) -> None:
        # Dead PID fails immediately without sleeping
        sleeps: list[float] = []
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            ok = lp.wait_ready(
                "svc",
                pid=999999,
                port=8000,
                url="http://127.0.0.1:8000",
                tries=5,
                pid_alive_fn=lambda _: False,
                sleep_fn=sleeps.append,
            )
        self.assertFalse(ok)
        self.assertEqual(sleeps, [])
        self.assertIn("svc exited unexpectedly", stderr.getvalue())

        # HTTP becomes ready on 3rd attempt
        attempts = {"n": 0}
        sleeps.clear()

        def _http(_url: str) -> bool:
            attempts["n"] += 1
            return attempts["n"] >= 3

        self.assertTrue(
            lp.wait_ready(
                "web",
                pid=os.getpid(),
                port=8000,
                url="http://127.0.0.1:8000",
                tries=5,
                pid_alive_fn=lambda _: True,
                http_probe_fn=_http,
                sleep_fn=sleeps.append,
            )
        )
        self.assertEqual(len(sleeps), 2)

        # Real TCP port probe succeeds against an ephemeral listener
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
            srv.bind(("127.0.0.1", 0))
            srv.listen(1)
            port = srv.getsockname()[1]
            self.assertTrue(
                lp.wait_ready("tcp-svc", pid=os.getpid(), port=port, url="-", tries=2, interval=0.05)
            )

        # Timeout fails and logs message
        stderr = io.StringIO()
        sleeps.clear()
        with contextlib.redirect_stderr(stderr):
            ok = lp.wait_ready(
                "slow",
                pid=os.getpid(),
                port=8000,
                url="http://127.0.0.1:8000",
                tries=2,
                interval=1.5,
                pid_alive_fn=lambda _: True,
                http_probe_fn=lambda _: False,
                sleep_fn=sleeps.append,
            )
        self.assertFalse(ok)
        self.assertEqual(len(sleeps), 2)
        self.assertIn("slow is not ready after 3 s", stderr.getvalue())

    def test_wait_db_free_and_pg_template_ready(self) -> None:
        responses = iter(["2", "0"])
        sleeps: list[float] = []
        self.assertTrue(
            lp.wait_db_free(
                "tpl_db",
                timeout=10,
                query_fn=lambda _db, _sql, **_kw: next(responses),
                sleep_fn=sleeps.append,
            )
        )
        self.assertEqual(len(sleeps), 1)

        # Template ready requires both matching comment and posthog_organization table
        self.assertTrue(
            lp.pg_template_ready(
                "tpl_db",
                "enact-live-pg-v1:abc",
                query_fn=lambda db, _sql, **_kw: "1" if db == "postgres" else "t",
            )
        )
        self.assertFalse(
            lp.pg_template_ready(
                "tpl_db",
                "enact-live-pg-v1:abc",
                query_fn=lambda db, _sql, **_kw: "0" if db == "postgres" else "t",
            )
        )

    def test_migrate_pg_cluster_hit_and_cold_publish_lock(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            snap = Path(tmp) / "snapshots"
            repo.mkdir()
            sql_log: list[tuple[str, str]] = []

            def fake_query(db: str, sql: str, **_kw) -> str:
                sql_log.append((db, sql))
                if "SHOW server_version_num" in sql:
                    return "150013"
                if "pg_database" in sql:
                    return "1"
                if "posthog_organization" in sql:
                    return "t"
                if "pg_stat_activity" in sql:
                    return "0"
                return ""

            def fake_runner(cmd, **_kw):
                if "pg-key" in cmd:
                    return subprocess.CompletedProcess(cmd, 0, stdout="deadbeef12345678\n", stderr="")
                raise AssertionError(f"unexpected command on cluster hit: {cmd}")

            result = lp.migrate_pg(
                repo=repo,
                snapshot_root=snap,
                live_db="test_posthog_e2e_1",
                template_key="tplkey123",
                env={"PGHOST": "127.0.0.1", "PGPORT": "5432", "PGUSER": "posthog"},
                runner=fake_runner,
                query_fn=fake_query,
            )
            self.assertEqual(result, "cluster_hit")
            self.assertTrue((snap / "live-v1" / "deadbeef12345678.migrate.lock").is_file())
            self.assertTrue(
                any("CREATE DATABASE test_posthog_e2e_1 TEMPLATE posthog_live_template_deadbeef1234;" in s for _, s in sql_log)
            )

    def test_migrate_pg_default_query_fn_forwards_env_without_duplicate_kwarg(self) -> None:
        """Regression for ibp8 live smoke: query_fn=None must not pass duplicate env= to pg_query."""
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            snap = Path(tmp) / "snapshots"
            repo.mkdir()
            cmds: list[list[str]] = []

            def fake_runner(cmd, **_kw):
                cmds.append(list(cmd))
                if "pg-key" in cmd:
                    return subprocess.CompletedProcess(cmd, 0, stdout="cafebabe12345678\n", stderr="")
                sql = cmd[-1]
                if "SHOW server_version_num" in sql:
                    return subprocess.CompletedProcess(cmd, 0, stdout="150013\n", stderr="")
                if "pg_database" in sql:
                    return subprocess.CompletedProcess(cmd, 0, stdout="1\n", stderr="")
                if "posthog_organization" in sql:
                    return subprocess.CompletedProcess(cmd, 0, stdout="t\n", stderr="")
                if "pg_stat_activity" in sql:
                    return subprocess.CompletedProcess(cmd, 0, stdout="0\n", stderr="")
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            result = lp.migrate_pg(
                repo=repo,
                snapshot_root=snap,
                live_db="test_posthog_e2e_2",
                template_key="tplkey123",
                env={"PGHOST": "127.0.0.1", "PGPORT": "5432", "PGUSER": "posthog"},
                runner=fake_runner,
                query_fn=None,
            )
            self.assertEqual(result, "cluster_hit")
            self.assertTrue(any(c[0] == "psql" and "CREATE DATABASE test_posthog_e2e_2" in c[-1] for c in cmds))

    def test_merge_prebuilt_rust_footprint(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            built = base / "built.json"
            src_map = base / "spec.json"
            out_dir = base / "out"
            built.write_text(
                json.dumps({"shared": {"files": ["rust/capture/src/main.rs"], "recorders": ["rust_footprint.py/3"]}}),
                encoding="utf-8",
            )
            src_map.write_text(
                json.dumps(
                    {
                        "shared": {"files": ["posthog/settings.py"], "recorders": ["live_footprint.py/3"]},
                        "targets": {"playwright/e2e/a.spec.ts": {"files": ["a.ts"], "recorders": ["live_footprint.py/3"]}},
                    }
                ),
                encoding="utf-8",
            )
            lp.merge_prebuilt_rust_footprint(built, out_dir, [src_map])
            merged = json.loads((out_dir / "spec.json").read_text(encoding="utf-8"))
            self.assertEqual(merged["shared"]["files"], ["posthog/settings.py", "rust/capture/src/main.rs"])
            self.assertEqual(merged["shared"]["recorders"], ["live_footprint.py/3", "rust_footprint.py/3"])
            self.assertEqual(
                merged["targets"]["playwright/e2e/a.spec.ts"]["recorders"],
                ["live_footprint.py/3", "rust_footprint.py/3"],
            )


if __name__ == "__main__":
    unittest.main()
