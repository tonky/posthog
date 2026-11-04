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


if __name__ == "__main__":
    unittest.main()
