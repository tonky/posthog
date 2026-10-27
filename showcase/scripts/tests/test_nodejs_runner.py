"""run_nodejs_tests.sh runs the jest files it is given, and only those.

The package's test:parallel script ends in --testPathIgnorePatterns, an array option, so the
paths the runner appended became more ignore patterns: given five files, the lane ran the
other 600. Runs the runner's own lane arguments with --listTests; needs nodejs/node_modules
(`enve run --locked -- python3 -m unittest showcase/scripts/tests/test_nodejs_runner.py`).
"""

import re
import shlex
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / "showcase/scripts/run_nodejs_tests.sh"
TARGET = "src/common/utils/db/redis.test.ts"


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
