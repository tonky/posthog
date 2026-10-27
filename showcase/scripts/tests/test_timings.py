"""A shard's durations file (pytest_timings.py) is the history enact's plans weigh its tests by:
a run updates the tests it ran and keeps the rest, and replaces the file whole. Each run
rewrote it with its own tests alone, so a selected run left the next plan without the other
tests' seconds, and a plan reading it mid-write lost it: forecasts flipped.

Runs real pytest sessions (the backend environment's); skipped without pytest.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PLUGINS = Path(__file__).resolve().parents[2] / "pytest_plugins"

TESTS = """
def test_a():
    pass

def test_b():
    pass
"""


@unittest.skipUnless(importlib.util.find_spec("pytest"), "needs pytest")
class TimingsTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.directory = Path(tmp.name)
        (self.directory / "pytest.ini").write_text("[pytest]\n")
        (self.directory / "test_it.py").write_text(TESTS)
        self.results = self.directory / "results"
        self.durations = self.results / "durations-shard-1.json"

    def pytest(self, *args: str) -> None:
        env = {
            **os.environ,
            "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1",
            "PYTHONPATH": str(PLUGINS),
            "ENACT_REPLAY_RESULTS": str(self.results),
            "ENACT_SHARD_INDEX": "1",
        }
        env.pop("ENACT_PYTEST_GROUP", None)
        done = subprocess.run(
            [sys.executable, "-m", "pytest", "-p", "no:cacheprovider", "-p", "pytest_timings", *args],
            cwd=self.directory,
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)

    def recorded(self) -> dict:
        return json.loads(self.durations.read_text())

    def test_a_selected_run_keeps_the_tests_it_did_not_run(self) -> None:
        self.pytest("test_it.py")
        first = self.recorded()
        self.assertEqual(["test_it.py::test_a", "test_it.py::test_b"], sorted(first))
        held = self.durations.open()
        self.addCleanup(held.close)

        self.pytest("test_it.py::test_a")
        second = self.recorded()
        self.assertEqual(sorted(first), sorted(second), "test_b's seconds are kept")
        self.assertEqual(first["test_it.py::test_b"], second["test_it.py::test_b"])
        # Replaced whole, never rewritten in place: a reader holding the file reads it all.
        self.assertEqual(first, json.loads(held.read()))
        # Its temp and lock files are no durations file enact's `durations-*.json` reads.
        self.assertEqual(["durations-shard-1.json"], sorted(p.name for p in self.results.glob("durations-*.json")))


if __name__ == "__main__":
    unittest.main()
