"""The actual runner reuses managed installs and dispatches only the jest files it is given.

Preparation and dispatch fixtures mock dependencies and services; optional real Jest checks
require the nodejs install.

The package's test:parallel script ends in --testPathIgnorePatterns, an array option, so the
paths the runner appended became more ignore patterns: given five files, the lane ran the
other 600. Runs the runner's own lane arguments with --listTests; needs nodejs/node_modules
(`enve run --locked -- python3 -m unittest showcase/scripts/tests/test_nodejs_runner.py`).
"""

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / "showcase/scripts/run_nodejs_tests.sh"
TARGET = "src/common/utils/db/redis.test.ts"

STUB = r'''import json, os, subprocess, sys
from pathlib import Path
tool, args = Path(sys.argv[0]).name, sys.argv[1:]
if tool == "uname":
    print("Linux")
elif tool == "clickhouse-client":
    print("0")
elif tool == "realpath":
    base = next(arg.partition("=")[2] for arg in args if arg.startswith("--relative-to="))
    print(os.path.relpath(os.path.abspath(args[-1]), base))
elif tool in ("pnpm", "enact"):
    row = {"tool": tool, "args": args, "shard": [os.getenv("SHARD_INDEX"), os.getenv("SHARD_COUNT")]}
    if tool == "pnpm":
        serial = "test:serial" in args
        files = [p for p in json.loads(os.environ["JEST_FILES"]) if p.endswith(".serial.test.ts") == serial]
        selectors = args[args.index("--ci") + 1:]
        selectors = [p for p in selectors if p != "--listTests"]
        if selectors:
            if "--findRelatedTests" in selectors:
                files = [p for p in files if "/selected/" in p]
            else:
                files = [p for p in files if any(s in p for s in selectors)]
        index, count = int(os.environ["SHARD_INDEX"]), int(os.environ["SHARD_COUNT"])
        row["tests"] = files[index - 1::count]
    with open(os.environ["CALL_LOG"], "a") as f:
        f.write(json.dumps(row) + "\n")
    if tool == "enact":
        sys.exit(subprocess.call(args[args.index("--") + 1:]))
    elif "--listTests" in args:
        print("\n".join(row["tests"]))
'''


PREPARE_STUB = r'''import json, os, subprocess, sys
from pathlib import Path
tool, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["CALL_LOG"], "a") as log:
    log.write(json.dumps({"tool": tool, "args": args}) + "\n")
if tool == "exclusive.sh":
    sys.exit(subprocess.call(args[1:]))
if tool == "enve" and os.getenv("ENACT_TEST_SERVICE_EXIT_STATUS"):
    print("service startup begins")
    for i in range(60):
        print(f"[kafka] startup progress {i}")
    print("[seaweedfs-open] FATAL: nested startup cause: permission denied")
    for i in range(200):
        print(f"[kafka] orderly teardown {i}")
    print("final teardown marker")
    sys.exit(int(os.environ["ENACT_TEST_SERVICE_EXIT_STATUS"]))
'''


class NodejsPreparationTest(unittest.TestCase):
    """Execute the real outer runner, with dependency builds and services logged stubs."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        scripts = self.root / "showcase/scripts"
        scripts.mkdir(parents=True)
        (scripts / "run_nodejs_tests.sh").write_text(RUNNER.read_text())
        (scripts / "test_databases.sh").write_text(
            'with_templates() { "$@"; }\nfresh_django_clone() { :; }\n'
        )
        tools = self.root / "stubs"
        tools.mkdir()
        stub = tools / "tool.py"
        stub.write_text(f"#!{sys.executable}\n" + PREPARE_STUB)
        stub.chmod(0o755)
        for name in ("pnpm", "enve"):
            (tools / name).symlink_to(stub)
        for name in ("exclusive.sh", "build_hogvm.sh"):
            (scripts / name).symlink_to(stub)
        (self.root / "bin").mkdir()
        (self.root / "bin/turbo").symlink_to(stub)
        (self.root / "nodejs").mkdir()

    def run_outer(self, prepared: str | None, store: str | None = None, shard: int = 1,
                  service_status: int = 0) -> list[dict]:
        log = self.root / f"calls-{shard}.jsonl"
        env = {k: v for k, v in os.environ.items() if not k.startswith(("ENACT_", "ENVE_", "NODEJS_"))}
        env.update(PATH=f"{self.root / 'stubs'}:{env['PATH']}", CALL_LOG=str(log),
                   PGUSER="posthog", PGHOST="127.0.0.1", PGPORT="1",
                   ENACT_SHARD_INDEX=str(shard), ENACT_SHARD_TOTAL="2")
        if prepared is not None:
            env["ENACT_PREPARED"] = prepared
        if store is not None:
            env["ENACT_PNPM_STORE"] = store
        if service_status:
            env["ENACT_TEST_SERVICE_EXIT_STATUS"] = str(service_status)
        out = subprocess.run(["bash", str(self.root / "showcase/scripts/run_nodejs_tests.sh")],
                             cwd=self.root / "nodejs", env=env, capture_output=True, text=True)
        self.last_out = out
        self.assertEqual(out.returncode, service_status, out.stdout + out.stderr)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(sum(call["tool"] == "enve" for call in calls), 1, calls)
        self.assertEqual(sum(call["tool"] == "build_hogvm.sh" for call in calls), 1, calls)
        self.assertEqual(sum(call["tool"] == "turbo" for call in calls), 1, calls)
        return calls

    def test_managed_prepare_skips_the_install_and_lock_for_every_shard(self) -> None:
        for prepared in ("node", "node,python", " python , node "):
            for shard in (1, 2):
                with self.subTest(prepared=prepared, shard=shard):
                    (self.root / f"calls-{shard}.jsonl").unlink(missing_ok=True)
                    calls = self.run_outer(prepared, str(self.root / "configured store"), shard)
                    self.assertFalse(any(call["tool"] == "pnpm" for call in calls), calls)
                    self.assertFalse(any(call["tool"] == "exclusive.sh" and call["args"][0] == "node-modules"
                                         for call in calls), calls)

    def assert_fallback(self, calls: list[dict], store: str) -> None:
        installs = [call for call in calls if call["tool"] == "pnpm"]
        self.assertEqual(len(installs), 1, calls)
        self.assertEqual(installs[0]["args"], ["--filter=@posthog/nodejs...", "install", "--frozen-lockfile",
                                               "--prefer-offline", "--store-dir", store])
        locks = [call for call in calls if call["tool"] == "exclusive.sh" and call["args"][0] == "node-modules"]
        self.assertEqual(len(locks), 1, calls)

    def test_manual_fallback_uses_the_managed_default_store(self) -> None:
        self.assert_fallback(self.run_outer(None), str(self.root / ".enact/state/pnpm-store"))

    def test_unprepared_fallback_preserves_the_configured_store_with_spaces(self) -> None:
        store = str(self.root / "configured store")
        self.assert_fallback(self.run_outer("python", store), store)

    def test_similarly_named_ecosystems_do_not_claim_a_node_prepare(self) -> None:
        for prepared in ("nodejs,python", "pre-node,python", "node-extra", "n o d e", "NODE", ""):
            with self.subTest(prepared=prepared):
                (self.root / "calls-1.jsonl").unlink(missing_ok=True)
                self.assert_fallback(self.run_outer(prepared), str(self.root / ".enact/state/pnpm-store"))


    def test_startup_failure_keeps_early_cause_exit_status_and_complete_artifact(self) -> None:
        self.run_outer("node", service_status=7)
        self.assertIn("nested startup cause: permission denied", self.last_out.stderr)
        self.assertIn("service startup begins", self.last_out.stderr)
        self.assertIn("final teardown marker", self.last_out.stderr)
        self.assertLess(len(self.last_out.stderr.splitlines()), 150)
        log = self.root / ".enact/state/nodejs/default-nodejs1.services.log"
        complete = log.read_text()
        self.assertEqual(len(complete.splitlines()), 263)
        self.assertEqual(complete.count("orderly teardown"), 200)
        # Inspect the committed generated steps, including their cancellation handling.
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        steps = re.findall(r"(?ms)^    - name:.*?(?=^    - name:|^  [\w-]+:|\Z)", workflow)
        uploads = [step for step in steps if re.search(r"(?m)^        name: telemetry-", step)]
        self.assertGreaterEqual(len(uploads), 2)
        self.assertTrue(any("telemetry-stage-" in step for step in uploads))
        for step in uploads:
            self.assertIn("always()", step)
            self.assertIn("actions/upload-artifact@", step)
            paths = re.findall(r"(?m)^          (\S.+)$", step)
            # An explicit visible search root below .enact works with hidden-files=false.
            nested = ".enact/state/nodejs/*.services.log"
            self.assertIn(nested, paths)
            self.assertIn(log, list(self.root.glob(nested)))
            self.assertEqual(log.read_text(), complete)

    def test_success_does_not_print_failure_excerpts(self) -> None:
        self.run_outer("node")
        self.assertNotIn("diagnostic lines", self.last_out.stderr)
        self.assertNotIn("first 40 lines", self.last_out.stderr)


class NodejsRecordingDispatchTest(unittest.TestCase):
    def test_requested_files_record_and_other_files_run_once_on_nonfirst_shard(self) -> None:
        for from_file in (False, True):
            with self.subTest(from_file=from_file):
                self.dispatch(from_file)

    def test_whole_suite_records_only_wanted_files_on_nonfirst_shard(self) -> None:
        self.dispatch(False, "whole")

    def test_directory_records_only_wanted_files_on_nonfirst_shard(self) -> None:
        self.dispatch(False, "directory")

    def test_pattern_records_only_wanted_files_on_nonfirst_shard(self) -> None:
        self.dispatch(False, "pattern")

    def test_related_selector_keeps_original_shard_before_recording(self) -> None:
        self.dispatch(False, "related")

    def test_broad_selections_keep_jest_sharding_when_not_recording(self) -> None:
        for selection in ("whole", "directory", "pattern", "related"):
            with self.subTest(selection=selection):
                self.dispatch(False, selection, recording=False)

    def dispatch(self, from_file: bool, selection: str = "files", recording: bool = True) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            runner = root / "showcase/scripts/run_nodejs_tests.sh"
            runner.parent.mkdir(parents=True)
            runner.write_text(RUNNER.read_text())
            tools = root / "bin"
            tools.mkdir()
            stub = tools / "tool.py"
            stub.write_text(f"#!{sys.executable}\n" + STUB)
            stub.chmod(0o755)
            for name in ("pnpm", "enact", "uname", "uv", "clickhouse-client", "realpath"):
                (tools / name).symlink_to(stub)
            migrate = root / "rust/bin/migrate-entry"
            migrate.parent.mkdir(parents=True)
            migrate.symlink_to(stub)
            names = ["nodejs/src/selected/a.test.ts", "nodejs/src/selected/b.serial.test.ts", "nodejs/src/selected/c.test.ts"]
            catalogue = names
            if selection != "files":
                # Two parallel files and one serial file belong to shard 2/3. The other
                # shards' files catch discovery at 1/1 and accidental second sharding.
                catalogue = ["nodejs/src/selected/other1.test.ts", names[0],
                             "nodejs/src/selected/other3.test.ts", "nodejs/src/selected/other4.test.ts", names[2],
                             "nodejs/src/selected/other6.test.ts", "nodejs/src/selected/other1.serial.test.ts", names[1],
                             "nodejs/src/selected/other3.serial.test.ts"]
            for name in [*catalogue, "nodejs/src/common/kafka/config.ts"]:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("")
            wanted, out = root / "wanted.txt", root / "footprints"
            wanted.write_text(names[0] + "\n")
            out.mkdir()
            log = root / "calls.jsonl"
            env = {k: v for k, v in os.environ.items() if not k.startswith(("ENACT_", "ENVE_"))}
            env.update(PATH=f"{tools}:{env['PATH']}", CALL_LOG=str(log), NODEJS_SHARD_INSTANCE="fixture",
                       JEST_FILES=json.dumps([str(root / name) for name in catalogue]),
                       ENVE_INSTANCE="fixture", NODEJS_LANES="parallel serial", PGUSER="posthog", PGHOST="127.0.0.1",
                       PGPORT="1", NODEJS_DJANGO_DATABASE_URL="postgres://fixture", KAFKA_HOSTS="127.0.0.1:1",
                       CLICKHOUSE_TCP_PORT="1", ENACT_SHARD_INDEX="2", ENACT_SHARD_TOTAL="3",
                       ENACT_FOOTPRINT_DIR=str(out), ENACT_FOOTPRINT_TARGETS=str(wanted), ENACT_EXE=str(tools / "enact"))
            if not recording:
                del env["ENACT_FOOTPRINT_DIR"]
                del env["ENACT_FOOTPRINT_TARGETS"]
            for variable in ("ENVE_SERVICE_VALKEY_CLUSTER_PORT", "ENVE_SERVICE_SEAWEEDFS_OPEN_PORT",
                             "ENVE_SERVICE_DYNAMODB_PORT", "ENVE_SERVICE_MAILDEV_PORT", "ENVE_SERVICE_MAILDEV_PORT_SMTP"):
                env[variable] = "1"
            args = ["../" + name for name in names]
            if selection == "whole":
                args = []
            elif selection == "directory":
                args = ["src/selected"]
            elif selection == "pattern":
                args = ["selected/"]
            elif selection == "related":
                args = ["--findRelatedTests", "src/common/kafka/config.ts"]
            if from_file:
                selected = root / "selected.txt"
                selected.write_text("\n".join(names) + "\n")
                env["ENACT_TARGETS_FILE"] = str(selected)
                args = []
            result = subprocess.run(["bash", str(runner), *args],
                                    cwd=root / "nodejs", env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            traces = [call for call in calls if call["tool"] == "enact"]
            self.assertEqual(len(traces), int(recording), calls)
            if recording:
                self.assertIn("--node-functions", traces[0]["args"])
                self.assertEqual(traces[0]["args"][traces[0]["args"].index("-t") + 1], names[0])
            runs = [call for call in calls if call["tool"] == "pnpm" and "--listTests" not in call["args"]]
            self.assertEqual(sorted(Path(test).relative_to(root).as_posix() for call in runs for test in call["tests"]), names)
            probes = [call for call in calls if "--listTests" in call["args"]]
            self.assertEqual(len(probes), 2 if recording and selection != "files" else 0, calls)
            self.assertTrue(all(call["shard"] == ["2", "3"] for call in probes), calls)
            execution_shard = ["1", "1"] if recording or selection == "files" else ["2", "3"]
            self.assertTrue(all(call["shard"] == execution_shard for call in [*runs, *traces]), calls)


def lane_arguments(lane: str) -> list[str]:
    match = re.search(rf'pnpm run {re.escape(lane)} (.*?)"\$@"', RUNNER.read_text())
    assert match, f"the runner runs no {lane} lane"
    return shlex.split(match.group(1))


@unittest.skipUnless(
    (ROOT / "nodejs/node_modules").is_dir() and shutil.which("pnpm"), "needs the nodejs install"
)
class NodejsRunnerTest(unittest.TestCase):
    def listed(self, lane: str, target: str) -> list[str]:
        result = subprocess.run(
            ["pnpm", "--silent", "run", lane, *lane_arguments(lane), target, "--listTests"],
            cwd=ROOT / "nodejs",
            capture_output=True,
            text=True,
            check=True,
        )
        return [line for line in result.stdout.splitlines() if line.endswith(".ts")]

    def test_the_parallel_lane_runs_only_the_given_file(self) -> None:
        listed = self.listed("test:parallel", TARGET)
        self.assertEqual([Path(p).relative_to(ROOT / "nodejs").as_posix() for p in listed], [TARGET])

    def test_the_serial_lane_runs_only_the_given_file(self) -> None:
        target = "tests/ingestion/person-state-batch.serial.test.ts"
        listed = self.listed("test:serial", target)
        self.assertEqual([Path(p).relative_to(ROOT / "nodejs").as_posix() for p in listed], [target])


if __name__ == "__main__":
    unittest.main()
