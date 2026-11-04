"""no_drift.sh fails a generator that changed a tracked file, on a checkout the overlay's
patches already modify: openapi_types' `git diff --exit-code` failed on the patches alone."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "no_drift.sh"


@unittest.skipUnless(shutil.which("git") and shutil.which("sha256sum"), "needs git and sha256sum")
class NoDriftTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        for name in ("patched.py", "generated.ts", "other.ts"):
            (self.repo / name).write_text(f"{name}\n")
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run([*git, "commit", "-q", "-m", "base"], cwd=self.repo, check=True)
        # The overlay's patch: a tracked file differing from HEAD before the check runs.
        (self.repo / "patched.py").write_text("patched\n")

    def run_check(self, command: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), "bash", "-c", command], cwd=self.repo, capture_output=True, text=True
        )

    def test_a_generator_reproducing_the_tracked_files_passes_beside_patches(self) -> None:
        done = self.run_check("echo generated.ts > generated.ts")
        self.assertEqual(0, done.returncode, done.stderr)

    def test_a_generator_changing_a_tracked_file_fails_naming_it(self) -> None:
        done = self.run_check("echo new > generated.ts")
        self.assertEqual(1, done.returncode, done.stdout)
        self.assertIn("generated.ts", done.stderr)
        self.assertNotIn("patched.py", done.stderr.split("changed tracked files:")[1].split("diff --git")[0])

    def test_a_generator_changing_a_patched_file_fails(self) -> None:
        done = self.run_check("echo regenerated > patched.py")
        self.assertEqual(1, done.returncode, done.stdout)
        self.assertIn("patched.py", done.stderr)

    def test_the_generators_failure_is_the_checks(self) -> None:
        self.assertEqual(3, self.run_check("exit 3").returncode)


if __name__ == "__main__":
    unittest.main()
