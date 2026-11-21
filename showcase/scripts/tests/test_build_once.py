"""build_once.sh builds once per source state of its inputs.

The Storybook and e2e jobs build the frontend's bundles in the checkout they share with the run's
other jobs and shards: the first to arrive builds and the rest find its build current, and a
change to what the build reads (tracked or untracked) builds again. Needs `flock`
(exclusive.sh): run inside the locked environment.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent


@unittest.skipUnless(shutil.which("flock"), "needs flock (enve run --locked)")
class BuildOnceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.repo)
        scripts = self.repo / "showcase" / "scripts"
        scripts.mkdir(parents=True)
        for name in ("build_once.sh", "exclusive.sh"):
            shutil.copy2(SCRIPTS / name, scripts / name)
        (self.repo / "src").mkdir()
        (self.repo / "src" / "app.ts").write_text("one\n")
        (self.repo / "other.txt").write_text("other\n")
        (self.repo / ".gitignore").write_text("dist/\n.enact/\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.repo, check=True)

    def build(self) -> int:
        """Runs a build of src into dist and returns how many builds ran so far."""
        subprocess.run(
            [
                "showcase/scripts/build_once.sh",
                "test-build",
                "dist/.key",
                "src",
                "--",
                "bash",
                "-c",
                "mkdir -p dist && echo built >> dist/count",
            ],
            cwd=self.repo,
            check=True,
            capture_output=True,
            env={**os.environ, "BUILD_ONCE_LOCKED": ""},
        )
        return len((self.repo / "dist" / "count").read_text().splitlines())

    def test_builds_once_per_source_state_of_its_inputs(self) -> None:
        steps = [
            ("first build", lambda: None, 1),
            ("unchanged sources", lambda: None, 1),
            ("a file outside the inputs", lambda: (self.repo / "other.txt").write_text("changed\n"), 1),
            ("a tracked input changed", lambda: (self.repo / "src" / "app.ts").write_text("two\n"), 2),
            ("the same state again", lambda: None, 2),
            ("an untracked input", lambda: (self.repo / "src" / "new.ts").write_text("new\n"), 3),
        ]
        for name, change, builds in steps:
            with self.subTest(step=name):
                change()
                self.assertEqual(self.build(), builds)

    def test_a_failed_build_records_no_state(self) -> None:
        failed = subprocess.run(
            ["showcase/scripts/build_once.sh", "test-build", "dist/.key", "src", "--", "false"],
            cwd=self.repo,
            capture_output=True,
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse((self.repo / "dist" / ".key").exists())
        self.assertEqual(self.build(), 1)


@unittest.skipUnless(
    os.environ.get("ENACT_EXE") or os.environ.get("ENACT_BIN") or shutil.which("enact"),
    "needs enact",
)
class BuildE2eStampTest(unittest.TestCase):
    """e2e:build -> e2e:test stamp parity: runtime inputs invalidate, nodejs/tests/** keeps hit."""

    def setUp(self) -> None:
        self.repo = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.repo)
        scripts = self.repo / "showcase" / "scripts"
        scripts.mkdir(parents=True)
        for name in ("build_e2e.sh", "build_once.sh", "exclusive.sh"):
            shutil.copy2(SCRIPTS / name, scripts / name)
        # Stub build_hogvm.sh to avoid invoking real turbo for hogvm in this unit fixture.
        hogvm_stub = scripts / "build_hogvm.sh"
        hogvm_stub.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "mkdir -p common/hogvm/typescript/dist\n"
            "echo hogvm-ok > common/hogvm/typescript/dist/.enact-build-key\n"
        )
        hogvm_stub.chmod(0o755)

        fake_bin = self.repo / "bin"
        fake_bin.mkdir()
        turbo = fake_bin / "turbo"
        turbo.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "if [[ \"$*\" == *\"--filter=@posthog/plugin-transpiler\"* ]]; then\n"
            "  mkdir -p common/plugin_transpiler/dist\n"
            "  touch common/plugin_transpiler/dist/index.js\n"
            "  exit 0\n"
            "fi\n"
            "if [[ \"$*\" == *\"--filter=@posthog/nodejs\"* ]]; then\n"
            "  mkdir -p nodejs/dist common/replay-headless/dist rust/replay-anonymizer-node/dist rust/common/hogvm/node\n"
            "  echo built >> .enact-nodejs-build-count\n"
            "  touch nodejs/dist/index.js\n"
            "  touch common/replay-headless/dist/player.html common/replay-headless/dist/protocol.js\n"
            "  touch rust/replay-anonymizer-node/dist/index.js rust/replay-anonymizer-node/index.node\n"
            "  touch rust/common/hogvm/node/index.node\n"
            "  exit 0\n"
            "fi\n"
            "exit 1\n"
        )
        turbo.chmod(0o755)

        shim_dir = self.repo / ".test-bin"
        shim_dir.mkdir()
        pnpm = shim_dir / "pnpm"
        pnpm.write_text("#!/usr/bin/env bash\nexit 0\n")
        pnpm.chmod(0o755)
        self.shim_dir = shim_dir

        seed_files = {
            "nodejs/src/index.ts": "export const v = 1;\n",
            "nodejs/assets/bot-ips.txt": "127.0.0.1\n",
            "nodejs/package.json": '{"name":"@posthog/nodejs"}\n',
            "nodejs/tsconfig.json": "{}\n",
            "nodejs/tests/ingestion/sample.test.ts": "test('v1', () => {});\n",
            "common/hogvm/typescript/src/index.ts": "export const h = 1;\n",
            "common/hogvm/typescript/package.json": "{}\n",
            "common/hogvm/typescript/tsconfig.json": "{}\n",
            "common/hogvm/typescript/tsconfig.build.json": "{}\n",
            "common/hogvm/typescript/.parcelrc": "{}\n",
            "common/replay-headless/src/index.html": "<html></html>\n",
            "common/replay-headless/package.json": "{}\n",
            "common/replay-headless/tsconfig.json": "{}\n",
            "common/replay-headless/build.mjs": "// build\n",
            "common/replay-shared/src/index.ts": "export const s = 1;\n",
            "common/replay-shared/package.json": "{}\n",
            "common/plugin_transpiler/src/index.ts": "export const p = 1;\n",
            "common/esbuilder/index.js": "// esbuilder\n",
            "rust/common/hogvm/Cargo.toml": "[package]\n",
            "rust/replay-anonymizer/Cargo.toml": "[package]\n",
            "rust/replay-anonymizer-node/Cargo.toml": "[package]\n",
            "package.json": "{}\n",
            "pnpm-lock.yaml": "lockfileVersion: 9\n",
            "pnpm-workspace.yaml": "packages: []\n",
            "turbo.json": "{}\n",
            "tsconfig.json": "{}\n",
            "patches/keep.patch": "",
            ".gitignore": "**/dist/\n**/*.node\n.enact/\n.test-bin/\n.enact-nodejs-build-count\n",
        }
        for rel, body in seed_files.items():
            path = self.repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)

        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.repo, check=True)

    def run_build_e2e(self, job: str = "test") -> int:
        env = {
            **os.environ,
            "PATH": f"{self.shim_dir}:{os.environ.get('PATH', '')}",
            "BUILD_ONCE_LOCKED": "",
            "ENACT_JOB": job,
        }
        subprocess.run(
            ["showcase/scripts/build_e2e.sh"],
            cwd=self.repo,
            check=True,
            capture_output=True,
            env=env,
        )
        counter = self.repo / ".enact-nodejs-build-count"
        return len(counter.read_text().splitlines()) if counter.exists() else 0

    def test_producer_handoff_reused_on_nodejs_tests_edit_and_invalidated_on_runtime_or_missing_output(self) -> None:
        # 1. Producer builds and writes stamp + built outputs.
        self.assertEqual(self.run_build_e2e(job="build"), 1)
        self.assertTrue((self.repo / "nodejs/dist/.enact-build-key").is_file())

        # 2. Editing nodejs/tests/ingestion/** keeps the consumer stamp HIT (0 rebuild).
        (self.repo / "nodejs/tests/ingestion/sample.test.ts").write_text("test('v2', () => {});\n")
        self.assertEqual(self.run_build_e2e(job="test"), 1)

        # 3. Editing nodejs/src/** invalidates the stamp and triggers rebuild.
        (self.repo / "nodejs/src/index.ts").write_text("export const v = 2;\n")
        self.assertEqual(self.run_build_e2e(job="test"), 2)

        # 4. Editing nodejs/assets/bot-ips.txt invalidates the stamp and triggers rebuild.
        (self.repo / "nodejs/assets/bot-ips.txt").write_text("127.0.0.1\n10.0.0.1\n")
        self.assertEqual(self.run_build_e2e(job="test"), 3)

        # 5. Missing built output fails closed even when stamp file is present.
        (self.repo / "nodejs/dist/index.js").unlink()
        self.assertEqual(self.run_build_e2e(job="test"), 4)
        (self.repo / "rust/replay-anonymizer-node/index.node").unlink()
        self.assertEqual(self.run_build_e2e(job="test"), 5)

        # 6. Mismatched or missing stamp fails closed and rebuilds.
        (self.repo / "nodejs/dist/.enact-build-key").write_text("stale-hash\n")
        self.assertEqual(self.run_build_e2e(job="test"), 6)
        (self.repo / "nodejs/dist/.enact-build-key").unlink()
        self.assertEqual(self.run_build_e2e(job="test"), 7)


if __name__ == "__main__":
    unittest.main()
