"""Unit tests for run_sharded_pytest.py orchestration."""

from __future__ import annotations

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import run_sharded_pytest as rsp  # noqa: E402


class TargetResolutionTest(unittest.TestCase):
    def test_positional_args(self) -> None:
        self.assertEqual(
            rsp.resolve_targets(["posthog/test_a.py", "posthog/test_b.py"], {}, "1"),
            ["posthog/test_a.py", "posthog/test_b.py"],
        )

    def test_at_argfile_and_txt_file_and_env_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "targets.txt"
            f.write_text("\nposthog/test_a.py\n   \nproducts/alpha/test_b.py\n", encoding="utf-8")

            self.assertEqual(
                rsp.resolve_targets([f"@{f}"], {}, "1"),
                ["posthog/test_a.py", "products/alpha/test_b.py"],
            )
            self.assertEqual(
                rsp.resolve_targets([str(f)], {}, "1"),
                ["posthog/test_a.py", "products/alpha/test_b.py"],
            )
            self.assertEqual(
                rsp.resolve_targets([], {"ENACT_TARGETS_FILE": str(f)}, "1"),
                ["posthog/test_a.py", "products/alpha/test_b.py"],
            )
            # Empty `@` arg falls back to ENACT_TARGETS_FILE
            self.assertEqual(
                rsp.resolve_targets(["@"], {"ENACT_TARGETS_FILE": str(f)}, "1"),
                ["posthog/test_a.py", "products/alpha/test_b.py"],
            )

    def test_rejects_missing_or_empty_targets(self) -> None:
        with self.assertRaises(rsp.TargetResolutionError):
            rsp.resolve_targets([], {}, "1")
        with self.assertRaises(rsp.TargetResolutionError):
            rsp.resolve_targets(["@"], {}, "1")
        with tempfile.TemporaryDirectory() as tmp:
            empty = Path(tmp) / "empty.txt"
            empty.write_text("   \n\n", encoding="utf-8")
            with self.assertRaises(rsp.TargetResolutionError):
                rsp.resolve_targets([f"@{empty}"], {}, "1")
            with self.assertRaises(rsp.TargetResolutionError):
                rsp.resolve_targets([str(empty)], {}, "1")
            with self.assertRaises(rsp.TargetResolutionError):
                rsp.resolve_targets([], {"ENACT_TARGETS_FILE": str(empty)}, "1")


class MacosTargetFilteringTest(unittest.TestCase):
    def test_linux_keeps_all_targets(self) -> None:
        targets = [rsp.MACOS_CHDB_EXCLUDED[0], "posthog/test_a.py"]
        kept, left_out, dropped = rsp.filter_macos_targets(targets, Path("/repo"), "Linux")
        self.assertEqual(kept, targets)
        self.assertEqual(left_out, [])
        self.assertEqual(dropped, [])

    def test_darwin_drops_direct_files_and_adds_ignore_for_parent_dirs(self) -> None:
        ex0, ex1 = rsp.MACOS_CHDB_EXCLUDED
        kept, left_out, dropped = rsp.filter_macos_targets(
            [f"{ex0}::TestSummary", "products/web_analytics/dags", "-k", "fast"],
            Path("/repo"),
            "Darwin",
        )
        self.assertEqual(kept, ["products/web_analytics/dags", "-k", "fast"])
        self.assertEqual(dropped, [f"{ex0}::TestSummary"])
        self.assertEqual(left_out, [f"--ignore=/repo/{ex1}"])

    def test_darwin_dot_target_ignores_all_excluded(self) -> None:
        kept, left_out, dropped = rsp.filter_macos_targets(["."], Path("/repo"), "Darwin")
        self.assertEqual(kept, ["."])
        self.assertEqual(dropped, [])
        self.assertEqual(left_out, [f"--ignore=/repo/{p}" for p in rsp.MACOS_CHDB_EXCLUDED])


class ShardExecutionAndExitCodesTest(unittest.TestCase):
    def test_parse_planned_runs_and_endpoint_rewrite(self) -> None:
        plan_text = (
            "core\t.\tposthog/test_a.py\n"
            "alpha\tproducts/alpha\t-m 'not slow' backend/tests/test_x.py\n"
        )
        runs = rsp.parse_planned_runs(plan_text)
        self.assertEqual(len(runs), 2)
        self.assertEqual(runs[0], rsp.PlannedRun("core", ".", ("posthog/test_a.py",)))
        self.assertEqual(
            runs[1],
            rsp.PlannedRun("alpha", "products/alpha", ("-m", "not slow", "backend/tests/test_x.py")),
        )
        self.assertEqual(rsp.product_object_storage_endpoint("http://localhost:19000"), "http://localhost.:19000")
        self.assertEqual(rsp.product_object_storage_endpoint("http://127.0.0.1:19000"), "")

    def test_build_pytest_command_variants(self) -> None:
        plugins = ["-p", "pytest_timings"]
        core_cmd = rsp.build_pytest_command(
            rsp.PlannedRun("core", ".", ("posthog/test_a.py",)),
            plugins=plugins,
            left_out=[],
            reuse_db_arg=["--reuse-db"],
        )
        self.assertIn("python", core_cmd)
        self.assertIn("-m", core_cmd)
        self.assertIn("pytest", core_cmd)
        self.assertIn("--reuse-db", core_cmd)

        prod_cmd = rsp.build_pytest_command(
            rsp.PlannedRun("alpha", "products/alpha", ("backend/test_x.py",)),
            plugins=plugins,
            left_out=[],
            reuse_db_arg=[],
        )
        self.assertIn("--directory", prod_cmd)
        self.assertIn("products/alpha", prod_cmd)

        sig_cmd = rsp.build_pytest_command(
            rsp.PlannedRun("signals", "products/signals", ("backend/test_s.py",)),
            plugins=plugins,
            left_out=[],
            reuse_db_arg=[],
        )
        self.assertIn(rsp.SIGNALS_PRELOAD_SNIPPET, sig_cmd)

    def test_execute_planned_runs_exit_codes_and_ch_cleanup(self) -> None:
        runs = [
            rsp.PlannedRun("alpha", "products/alpha", ("backend/test_a.py",)),
            rsp.PlannedRun("beta", "products/beta", ("backend/test_b.py",)),
            rsp.PlannedRun("gamma", "products/gamma", ("backend/test_c.py",)),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            baseline = root / "baseline.json"
            baseline.write_text('{"events": []}', encoding="utf-8")

            # Case 1: first fails (1), second collects none (5), third passes (0) -> overall 5 + CH cleanup called
            invoked: list[tuple[list[str], str, str | None]] = []
            codes = iter([1, 5, 0])

            def fake_run(cmd, _cwd, env):
                if "cleanup-clickhouse" in cmd:
                    invoked.append((cmd, "cleanup", None))
                    return 0
                invoked.append((cmd, env["ENACT_PYTEST_GROUP"], env.get("OBJECT_STORAGE_ENDPOINT")))
                return next(codes)

            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                rc = rsp.execute_planned_runs(
                    runs,
                    root=root,
                    base_env={
                        "CLICKHOUSE_DATABASE": "posthog_test_w1",
                        "ENACT_CH_MAT_BASELINE_FILE": str(baseline),
                    },
                    plugins=["-p", "pytest_timings"],
                    left_out=[],
                    reuse_db_arg=["--reuse-db"],
                    services_active=True,
                    tz_ld_preload="",
                    product_endpoint="http://localhost.:19000",
                    run_cmd_fn=fake_run,
                )
            self.assertEqual(rc, 5)
            self.assertIn("collected no tests", stderr.getvalue())
            groups = [g for _, g, _ in invoked]
            self.assertEqual(groups, ["alpha", "cleanup", "beta", "cleanup", "gamma", "cleanup"])
            self.assertEqual(invoked[0][2], "http://localhost.:19000")

            # Case 2: fatal exit code (2) aborts immediately without running beta/gamma
            ran_groups: list[str] = []

            def fatal_run(cmd, _cwd, env):
                if "cleanup-clickhouse" in cmd:
                    return 0
                ran_groups.append(env["ENACT_PYTEST_GROUP"])
                return 2

            rc_fatal = rsp.execute_planned_runs(
                runs,
                root=root,
                base_env={},
                plugins=[],
                left_out=[],
                reuse_db_arg=[],
                services_active=False,
                tz_ld_preload="",
                product_endpoint="",
                run_cmd_fn=fatal_run,
            )
            self.assertEqual(rc_fatal, 2)
            self.assertEqual(ran_groups, ["alpha"])

    def test_provision_worker_databases_invokes_entrypoint_and_merges_env(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env: dict[str, str] = {"ENACT_COMPONENT": "base", "ENACT_JOB": "test"}
            captured_cmd: list[str] = []

            def fake_provision(cmd: list[str], _cwd: Path, _env) -> subprocess.CompletedProcess[str]:
                captured_cmd.extend(cmd)
                out_json = Path(cmd[3])
                out_json.write_text(
                    json.dumps(
                        {
                            "ENACT_WORKER_ID": "base_test_3",
                            "PYTEST_XDIST_WORKER": "base_test_3",
                            "CLICKHOUSE_DATABASE": "posthog_test_base_test_3",
                            "DATABASE_URL": "postgres://posthog:posthog@127.0.0.1:5432/test_posthog_base_test_3",
                        }
                    ),
                    encoding="utf-8",
                )
                return subprocess.CompletedProcess(cmd, 0)

            worker_id = rsp.provision_worker_databases(root, env, "3", provision_runner=fake_provision)
            self.assertEqual(worker_id, "base_test_3")
            self.assertEqual(captured_cmd[2], "--provision-db")
            self.assertEqual(captured_cmd[4], "3")
            self.assertEqual(env["CLICKHOUSE_DATABASE"], "posthog_test_base_test_3")
            self.assertEqual(env["PYTEST_XDIST_WORKER"], "base_test_3")


if __name__ == "__main__":
    unittest.main()
