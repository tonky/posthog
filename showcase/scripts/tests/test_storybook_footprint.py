"""storybook_footprint.mjs soundness guard for all-skipped story files:
emits a minimal footprint (`[target]`) ONLY when the runner exited 0 AND junit.xml
positively proves Jest executed the file with zero errors, zero failures, and every
story skipped (never on crashes, timeouts, partial skips, or unexecuted files).
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "storybook_footprint.mjs"


class StorybookFootprintSoundnessTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name).resolve()
        (self.repo / "products").mkdir()
        (self.repo / "common/storybook/dist").mkdir(parents=True)
        (self.repo / "frontend/src/stories").mkdir(parents=True)
        (self.repo / "frontend/src/stories/Skipped.stories.tsx").write_text("export default {}\n")
        (self.repo / "frontend/src/stories/Partial.stories.tsx").write_text("export default {}\n")
        (self.repo / "frontend/src/stories/Unrun.stories.tsx").write_text("export default {}\n")
        (self.repo / "frontend/src/stories/Rendered.stories.tsx").write_text("export default {}\n")
        (self.repo / "frontend/src/stories/Empty.stories.tsx").write_text("export default {}\n")
        (self.repo / "common/storybook/dist/enact-chunks.json").write_text(
            json.dumps({"outputs": {"assets/rendered.js": ["frontend/src/stories/Rendered.stories.tsx"]}})
        )
        (self.repo / "common/storybook/dist/index.json").write_text(
            json.dumps(
                {
                    "entries": {
                        "skipped--a": {
                            "type": "story",
                            "importPath": "../../frontend/src/stories/Skipped.stories.tsx",
                            "tags": ["test-skip"],
                        },
                        "empty--docs": {
                            "type": "docs",
                            "importPath": "../../frontend/src/stories/Empty.stories.tsx",
                            "tags": ["autodocs"],
                        },
                    }
                }
            )
        )
        self.loads = self.repo / "loads"
        self.loads.mkdir()
        self.out = self.repo / "footprints"
        self.out.mkdir()
        self.junit = self.repo / "junit.xml"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_recorder(self, *, status: int | None = 0, junit: Path | None = None) -> dict:
        for old in self.out.glob("*"):
            old.unlink()
        cmd = [
            "node",
            str(SCRIPT),
            "common/storybook/dist",
            str(self.loads),
            "http://127.0.0.1:6006",
        ]
        if status is not None:
            cmd += ["--status", str(status)]
        if junit is not None:
            cmd += ["--junit", str(junit)]
        env = {**os.environ, "ENACT_FOOTPRINT_DIR": str(self.out), "ENACT_SHARD_INDEX": "1"}
        res = subprocess.run(cmd, cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(0, res.returncode, res.stdout + res.stderr)
        maps = list(self.out.glob("storybook-shard1-*.json"))
        self.assertEqual(1, len(maps), maps)
        return json.loads(maps[0].read_text())

    def test_emits_minimal_footprint_only_for_proven_all_skipped_and_zero_story_files(self) -> None:
        (self.loads / "1.jsonl").write_text(
            json.dumps(
                {
                    "file": str(self.repo / "frontend/src/stories/Rendered.stories.tsx"),
                    "story": "rendered--a",
                    "urls": ["http://127.0.0.1:6006/assets/rendered.js"],
                }
            )
            + "\n"
        )
        self.junit.write_text(
            """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="../../frontend/src/stories/Skipped.stories.tsx" errors="0" failures="0" skipped="2" tests="2">
    <testcase classname="Skipped" name="One" time="0"><skipped/></testcase>
    <testcase classname="Skipped" name="Two" time="0"><skipped/></testcase>
  </testsuite>
  <testsuite name="../../frontend/src/stories/Partial.stories.tsx" errors="0" failures="0" skipped="1" tests="2">
    <testcase classname="Partial" name="One" time="0"><skipped/></testcase>
    <testcase classname="Partial" name="Two" time="0.1"/>
  </testsuite>
  <testsuite name="../../frontend/src/stories/Empty.stories.tsx" errors="0" failures="0" skipped="0" tests="0"/>
</testsuites>
"""
        )
        data = self.run_recorder(status=0, junit=self.junit)
        targets = data["targets"]
        self.assertIn("frontend/src/stories/Rendered.stories.tsx", targets)
        self.assertEqual(
            {"files": ["frontend/src/stories/Skipped.stories.tsx"], "loaded": ["frontend/src/stories/Skipped.stories.tsx"]},
            targets["frontend/src/stories/Skipped.stories.tsx"],
        )
        self.assertEqual(
            {"files": ["frontend/src/stories/Empty.stories.tsx"], "loaded": ["frontend/src/stories/Empty.stories.tsx"]},
            targets["frontend/src/stories/Empty.stories.tsx"],
        )
        # Partial skip with no browser loads and unexecuted files must stay untraced.
        self.assertNotIn("frontend/src/stories/Partial.stories.tsx", targets)
        self.assertNotIn("frontend/src/stories/Unrun.stories.tsx", targets)

    def test_refuses_skipped_footprint_on_nonzero_status_failure_or_unskipped_testcase(self) -> None:
        self.junit.write_text(
            """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="../../frontend/src/stories/Skipped.stories.tsx" errors="0" failures="0" skipped="1" tests="1">
    <testcase classname="Skipped" name="One" time="0"><skipped/></testcase>
  </testsuite>
  <testsuite name="../../frontend/src/stories/Partial.stories.tsx" errors="0" failures="1" skipped="1" tests="1">
    <testcase classname="Partial" name="One" time="0"><failure>boom</failure></testcase>
  </testsuite>
  <testsuite name="../../frontend/src/stories/Unrun.stories.tsx" errors="0" failures="0" skipped="1" tests="1">
    <testcase classname="Unrun" name="One" time="0"/>
  </testsuite>
</testsuites>
"""
        )
        # Crash / non-zero runner exit refuses ALL skipped-only emissions.
        crashed = self.run_recorder(status=1, junit=self.junit)
        self.assertEqual({}, crashed["targets"])

        # Status 0 still rejects failed suite and testcase lacking <skipped>.
        clean = self.run_recorder(status=0, junit=self.junit)
        self.assertEqual(["frontend/src/stories/Skipped.stories.tsx"], sorted(clean["targets"].keys()))

    def test_refuses_skipped_footprint_without_junit(self) -> None:
        data = self.run_recorder(status=0, junit=self.repo / "missing-junit.xml")
        self.assertEqual({}, data["targets"])


if __name__ == "__main__":
    unittest.main()
