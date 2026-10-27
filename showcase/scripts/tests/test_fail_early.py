"""A broken session- or package-scoped fixture ends the pytest session at once with exit 2
(pytest_fail_early.py), which enact's `error_exit_codes` take as an error that stops the
run. A test's failure, or a function-, class- or module-scoped fixture's, runs on.

Runs a real pytest session (the backend environment's); skipped without it.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PLUGINS = Path(__file__).resolve().parents[2] / "pytest_plugins"

TESTS = '''
import pytest

@pytest.fixture(scope="{scope}")
def database():
    raise TimeoutError("timed out")

def test_a(database):
    pass

def test_b(database):
    pass

def test_c():
    pass
'''


@unittest.skipUnless(importlib.util.find_spec("pytest"), "needs pytest")
class FailEarlyTest(unittest.TestCase):
    def pytest(self, scope: str, *args: str) -> subprocess.CompletedProcess:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        directory = Path(tmp.name)
        (directory / "pytest.ini").write_text("[pytest]\n")
        (directory / "test_setup.py").write_text(TESTS.format(scope=scope))
        return subprocess.run(
            [sys.executable, "-m", "pytest", "-p", "no:cacheprovider", "-p", "pytest_fail_early", "-v", *args],
            cwd=directory,
            env={**os.environ, "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1", "PYTHONPATH": str(PLUGINS)},
            capture_output=True,
            text=True,
        )

    def test_a_broken_session_fixture_ends_the_session(self) -> None:
        for scope in ("session", "package"):
            done = self.pytest(scope)
            out = done.stdout + done.stderr
            self.assertEqual(2, done.returncode, out)
            self.assertIn(f"{scope}-scoped fixture 'database' failed its setup (TimeoutError: timed out)", out)
            self.assertIn("test_a ERROR", out)
            self.assertNotIn("test_setup.py::test_b", out)
            self.assertNotIn("test_c PASSED", out)

    def test_narrower_fixtures_and_failing_tests_run_on(self) -> None:
        for scope in ("function", "class", "module"):
            done = self.pytest(scope)
            out = done.stdout + done.stderr
            self.assertEqual(1, done.returncode, out)
            self.assertIn("test_c PASSED", out)
            self.assertNotIn("failed its setup", out)


if __name__ == "__main__":
    unittest.main()
