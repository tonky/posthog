"""run_sharded_pytest.sh runs a shard's products as upstream's product jobs do: one pytest
process per product, from the product's directory with its `backend:test` script's flags,
one after another (turbo run backend:test), and core's targets as one run from the root.

Batched into one process, batch_exports' module-scoped autouse configure_logger() left
structlog's WrapperLogger set for every later product: wizard's views answered 500
(`'WrapperLogger' object has no attribute 'isEnabledFor'`) and cohorts' assertLogs saw
nothing. uv and backend_runtime.py are stubbed: the test reads the runs it started.
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hermetic import helper_env  # noqa: E402

SCRIPTS = Path(__file__).resolve().parents[1]

UV_STUB = """#!/usr/bin/env bash
# uv run --no-sync [--directory <dir>] <command...>: logs where and what it ran.
shift 2
dir=.
if [ "$1" = --directory ]; then dir=$2; shift 2; fi
cd "$dir" || exit 1
printf '%s\\n' "$(pwd -P)|$ENACT_PYTEST_GROUP|$*" >> "$RUNS_LOG"
printf '%s\\n' "$ENACT_PYTEST_GROUP|${OBJECT_STORAGE_ENDPOINT-unset}" >> "$RUNS_LOG.endpoints"
case "$*" in *test_fails.py*) exit 1 ;; *test_empty.py*) exit 5 ;; esac
"""

RUNTIME_STUB = """import os, sys
os.execvp(sys.argv[2], sys.argv[2:])  # exec <command...>
"""


@unittest.skipUnless(all(map(shutil.which, ("bash", "rg", "flock"))), "needs bash, rg and flock")
class ProductRunsTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name).resolve()
        scripts = self.repo / "showcase/scripts"
        scripts.mkdir(parents=True)
        for name in ("run_sharded_pytest.sh", "product_pytest.py", "exclusive.sh"):
            shutil.copy2(SCRIPTS / name, scripts / name)
        (scripts / "backend_runtime.py").write_text(RUNTIME_STUB)
        self.write("bin/uv", UV_STUB, executable=True)
        self.write("bin/download-mmdb", "#!/usr/bin/env bash\n", executable=True)
        # The host's OS is the test's choice (UNAME_S): the script leaves tests out on macOS.
        self.write(
            "bin/uname",
            '#!/usr/bin/env bash\n[ "$1" != -s ] || exec echo "${UNAME_S:-Linux}"\nexec command -p uname "$@"\n',
            executable=True,
        )
        self.write(".venv/pyvenv.cfg", "")
        self.write(".venv/.replay-provisioned.json", "{}")
        self.write(
            "products/alpha/package.json",
            json.dumps({"scripts": {"backend:test": "pytest -c ../../pytest.ini --rootdir ../.. backend/tests -v --tb=short"}}),
        )
        self.write(
            "products/beta/package.json",
            json.dumps(
                {
                    "scripts": {
                        "backend:test": "pytest -c ../../pytest.ini --rootdir ../.. backend/ "
                        "-m 'not async_migrations' --reruns=2 -v --tb=short"
                    }
                }
            ),
        )

    def write(self, name: str, text: str, executable: bool = False) -> None:
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        if executable:
            path.chmod(0o755)

    def run_shard(self, *targets: str, env: dict[str, str | None] | None = None) -> tuple[int, list[list[str]]]:
        """Runs the shard; `env` adds variables, a None value removing one."""
        log = self.repo / "runs.log"
        merged = {
            **helper_env(),
            "RUNS_LOG": str(log),
            "ENACT_SERVICES_ACTIVE": "0",
            "ENACT_SHARD_INDEX": "3",
            "ENACT_SHARD_TOTAL": "8",
            **(env or {}),
        }
        env = {name: value for name, value in merged.items() if value is not None}
        done = subprocess.run(
            ["bash", "showcase/scripts/run_sharded_pytest.sh", *targets],
            cwd=self.repo,
            env=env,
            capture_output=True,
            text=True,
        )
        runs = [line.split("|", 2) for line in log.read_text().splitlines()] if log.exists() else []
        return done.returncode, runs

    def test_two_products_run_as_two_pytest_processes_from_their_directories(self) -> None:
        code, runs = self.run_shard(
            "products/alpha/backend/tests/test_a.py",
            "products/beta/backend/test_b.py",
            "products/alpha/backend/tests/test_c.py::TestC",
        )
        self.assertEqual(0, code)
        self.assertEqual(
            [str(self.repo / "products/alpha"), str(self.repo / "products/beta")], [cwd for cwd, _, _ in runs]
        )
        self.assertEqual(["alpha", "beta"], [group for _, group, _ in runs])
        alpha, beta = (args for _, _, args in runs)
        self.assertTrue(
            alpha.startswith(
                "pytest -p pytest_timings -p pytest_snapshot_worker -p pytest_fail_early"
                " -p pytest_unmarked_db_setup -o pythonhashseed=0 "
            ),
            alpha,
        )
        self.assertTrue(
            alpha.endswith(
                "-c ../../pytest.ini --rootdir ../.. -v --tb=short --force-reruns 1 --reruns-delay 1 "
                "backend/tests/test_a.py backend/tests/test_c.py::TestC"
            ),
            alpha,
        )
        # The product's own flags (its marker filter, its reruns), its paths replaced by the shard's,
        # and ci-backend.yml's retry.
        self.assertTrue(
            beta.endswith(
                "-c ../../pytest.ini --rootdir ../.. -m not async_migrations --reruns=2 -v --tb=short "
                "--force-reruns 1 --reruns-delay 1 backend/test_b.py"
            ),
            beta,
        )
        for _, _, args in runs:
            self.assertNotIn("--import-mode", args)  # pytest's default, as upstream

    def test_business_knowledge_runs_with_tach_off(self) -> None:
        # Its script clears addopts, the root pytest.ini's `-p no:tach` with them: tach's plugin
        # ran git over the whole repository. The overlay turns it off again (a sanctioned exception).
        self.write(
            "products/business_knowledge/package.json",
            json.dumps(
                {
                    "scripts": {
                        "backend:test": "pytest -c ../../pytest.ini --rootdir ../.. backend/tests -v --tb=short "
                        "--override-ini='addopts=' || test $? -eq 5"
                    }
                }
            ),
        )
        code, runs = self.run_shard(
            "products/business_knowledge/backend/tests/test_k.py", "products/alpha/backend/tests/test_a.py"
        )
        self.assertEqual(0, code)
        knowledge, alpha = (args for _, _, args in runs)
        self.assertTrue(
            knowledge.endswith(
                "-c ../../pytest.ini --rootdir ../.. -v --tb=short --override-ini=addopts= -p no:tach "
                "--force-reruns 1 --reruns-delay 1 backend/tests/test_k.py"
            ),
            knowledge,
        )
        self.assertNotIn("no:tach", alpha)  # the root pytest.ini's addopts turn it off there

    def test_core_targets_are_one_run_from_the_root(self) -> None:
        code, runs = self.run_shard("posthog/api/test/test_x.py", "products/alpha/backend/tests/test_a.py", "ee/test_y.py")
        self.assertEqual(0, code)
        self.assertEqual([str(self.repo), str(self.repo / "products/alpha")], [cwd for cwd, _, _ in runs])
        self.assertTrue(runs[0][2].endswith("-v --force-reruns 1 --reruns-delay 1 posthog/api/test/test_x.py ee/test_y.py"), runs[0][2])
        self.assertIn("-m pytest", runs[0][2])

    def test_core_segments_upstream_runs_apart_are_runs_of_their_own(self) -> None:
        # ci-backend.yml's Core segment ignores posthog/temporal (the Temporal segment) and
        # posthog/dags (ci-dagster.yml): in Core's process, the temporal tests' structlog
        # setup left command_exec_audit's capture_logs() empty.
        code, runs = self.run_shard(
            "posthog/api/test/test_x.py",
            "posthog/temporal/tests/test_t.py",
            "posthog/dags/tests/test_d.py",
            "ee/test_y.py",
            "posthog/temporal/tests/test_u.py",
        )
        self.assertEqual(0, code)
        self.assertEqual(["core", "temporal", "dags"], [group for _, group, _ in runs])
        self.assertEqual({str(self.repo)}, {cwd for cwd, _, _ in runs})
        core, temporal, dags = (args for _, _, args in runs)
        self.assertTrue(core.endswith("-v --force-reruns 1 --reruns-delay 1 posthog/api/test/test_x.py ee/test_y.py"), core)
        self.assertTrue(
            temporal.endswith(
                "-v --force-reruns 1 --reruns-delay 1 posthog/temporal/tests/test_t.py posthog/temporal/tests/test_u.py"
            ),
            temporal,
        )
        self.assertTrue(dags.endswith("-v --reruns 2 --reruns-delay 1 posthog/dags/tests/test_d.py"), dags)

    def test_dagster_targets_are_one_run_from_the_root(self) -> None:
        # ci-dagster.yml: `pytest posthog/dags products/*/dags --reruns 2 --reruns-delay 1` from the
        # root, so a product's dags tests join posthog/dags' run instead of the product's.
        code, runs = self.run_shard(
            "posthog/dags/tests/test_d.py",
            "products/alpha/dags/tests/test_e.py",
            "products/alpha/backend/tests/test_a.py",
        )
        self.assertEqual(0, code)
        self.assertEqual(["dags", "alpha"], [group for _, group, _ in runs])
        self.assertEqual([str(self.repo), str(self.repo / "products/alpha")], [cwd for cwd, _, _ in runs])
        self.assertTrue(
            runs[0][2].endswith(
                "-v --reruns 2 --reruns-delay 1 posthog/dags/tests/test_d.py products/alpha/dags/tests/test_e.py"
            ),
            runs[0][2],
        )

    def test_products_reach_object_storage_by_a_name_other_than_localhost(self) -> None:
        # Upstream's turbo passes product tests only turbo.json's env, so they take settings'
        # objectstorage:19000, not the job's localhost:19000. Under DEBUG, exports'
        # get_content_response redirects to a presigned URL only off localhost: on localhost
        # replay_vision's thumbnail tests answered 500 (a read of an object they never wrote).
        endpoints = self.repo / "runs.log.endpoints"
        code, _ = self.run_shard(
            "posthog/api/test/test_x.py",
            "products/alpha/backend/tests/test_a.py",
            "posthog/dags/tests/test_d.py",
            env={"OBJECT_STORAGE_ENDPOINT": "http://localhost:23492"},
        )
        self.assertEqual(0, code)
        self.assertEqual(
            ["core|http://localhost:23492", "alpha|http://localhost.:23492", "dags|http://localhost:23492"],
            endpoints.read_text().splitlines(),
        )
        # Another endpoint, or none, passes through as it is.
        endpoints.unlink()
        self.run_shard("products/alpha/backend/tests/test_a.py", env={"OBJECT_STORAGE_ENDPOINT": "http://127.0.0.1:9"})
        self.run_shard("products/alpha/backend/tests/test_a.py", env={"OBJECT_STORAGE_ENDPOINT": None})
        self.assertEqual(["alpha|http://127.0.0.1:9", "alpha|unset"], endpoints.read_text().splitlines())

    def test_a_failing_product_fails_the_shard_after_every_product_ran(self) -> None:
        code, runs = self.run_shard(
            "products/alpha/backend/tests/test_fails.py",
            "products/beta/backend/test_b.py",
        )
        self.assertEqual(1, code)
        self.assertEqual(["alpha", "beta"], [group for _, group, _ in runs])

    def test_a_product_collecting_nothing_fails(self) -> None:
        # pytest's 5 (no tests collected): the targets were selected as tests, so none ran.
        code, runs = self.run_shard("products/beta/backend/test_empty.py")
        self.assertEqual(5, code)
        self.assertEqual(1, len(runs))

    def test_macos_leaves_out_the_test_files_chdb_wont_load_there(self) -> None:
        # ISSUES U31: chdb-core's _chdb.abi3.so won't dlopen on macOS 27; Linux runs them.
        product = "products/web_analytics"
        self.write(f"{product}/package.json", json.dumps({"scripts": {"backend:test": "pytest backend -v"}}))
        left_out = f"{product}/backend/hogql_queries/external/test/test_summary_query_runner.py"
        darwin = {"UNAME_S": "Darwin"}
        # Every target left out: no pytest runs, and the shard passes.
        self.assertEqual((0, []), self.run_shard(f"{left_out}::TestSummary::test_calculate", env=darwin))
        # A directory holding one collects it without that file.
        code, runs = self.run_shard(f"{product}/backend", env=darwin)
        self.assertEqual(0, code)
        self.assertIn(f"--ignore={self.repo}/{left_out} ", runs[-1][2])
        # Elsewhere it runs, and nothing is ignored.
        code, runs = self.run_shard(left_out)
        self.assertEqual(0, code)
        self.assertNotIn("--ignore", runs[-1][2])
        self.assertTrue(runs[-1][2].endswith(" backend/hogql_queries/external/test/test_summary_query_runner.py"))

    def test_a_shard_with_no_targets_fails_without_running_pytest(self) -> None:
        # It once printed "Skipping pytest" and passed: a whole-suite call with no targets
        # (or an empty targets file) passed without running a test.
        self.write("targets.txt", "\n")
        for targets in ((), ("",), ("@targets.txt",)):
            code, runs = self.run_shard(*targets)
            self.assertEqual(1, code, targets)
            self.assertEqual([], runs, targets)


if __name__ == "__main__":
    unittest.main()
