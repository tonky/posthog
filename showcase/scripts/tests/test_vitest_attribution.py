"""vitest.sh switches mcp:test and mcp:test_hono onto vitest-attribution.mjs:
- ENACT_ATTRIBUTION_FILE passes `--no-cache --pool=forks --isolate --reporter=default --reporter=<vitest-attribution.mjs>`.
- ENACT_FOOTPRINT_DIR partitions unwanted targets (plain), Node-pool targets (one batched
  `enact trace run --attribution` with filtered `outcomes: true` map), and Cloudflare workerd
  targets (`tests/workers/*`, traced per-file without `--pool=forks`).
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

OVERLAY = Path(__file__).resolve().parents[3]
VITEST_SH = OVERLAY / ".enact/vitest/vitest.sh"


class VitestAttributionWrapperTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)
        vitest_dir = self.repo / ".enact/vitest"
        vitest_dir.mkdir(parents=True)
        shutil.copy2(VITEST_SH, vitest_dir / "vitest.sh")
        (vitest_dir / "node_marker.mjs").write_text("export default class {}\n")
        self.recorders = self.repo / "recorders"
        (self.recorders / "js").mkdir(parents=True)
        (self.recorders / "js/vitest-attribution.mjs").write_text("export default class {}\n")

        self.pkg = self.repo / "services/mcp"
        (self.pkg / "tests/workers").mkdir(parents=True)
        (self.pkg / "tests/unit").mkdir(parents=True)
        (self.pkg / "vitest.workers.config.mts").write_text("export default {}\n")
        (self.pkg / "tests/workers/health.test.ts").write_text("")
        (self.pkg / "tests/unit/a.test.ts").write_text("")
        (self.pkg / "tests/unit/b.test.ts").write_text("")

        self.bin_dir = self.repo / "bin"
        self.bin_dir.mkdir()
        self.log = self.repo / "calls.log"
        self._write_stub(
            "pnpm",
            """#!/usr/bin/env bash
printf 'PNPM:%s|ATTR=%s|COV=%s\\n' "$*" "${ENACT_ATTRIBUTION_FILE:-}" "${ENACT_NODE_COVERAGE_DIR:-}" >> "$STUB_LOG"
""",
        )
        self._write_stub(
            "enact",
            """#!/usr/bin/env bash
printf 'ENACT:%s\\n' "$*" >> "$STUB_LOG"
reach=""
attr=""
target=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
    case "${args[$i]}" in
        --reach-file) reach="${args[$((i+1))]}"; i=$((i+2)) ;;
        --attribution) attr="${args[$((i+1))]}"; i=$((i+2)) ;;
        -t) target="${args[$((i+1))]}"; i=$((i+2)) ;;
        --) i=$((i+1)); break ;;
        *) i=$((i+1)) ;;
    esac
done
cmd=("${args[@]:$i}")
if [ -n "$attr" ]; then
    ENACT_ATTRIBUTION_FILE="$attr" "${cmd[@]}"
    cat > "$reach" <<'JSON'
{"targets":{"services/mcp/tests/unit/a.test.ts":{"files":["a.ts"]},"services/mcp/tests/unit/b.test.ts":{"files":["b.ts"]}}}
JSON
else
    "${cmd[@]}"
    printf '{"targets":{"%s":{"files":["w.ts"]}}}\\n' "$target" > "$reach"
fi
""",
        )

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _write_stub(self, name: str, body: str) -> None:
        path = self.bin_dir / name
        path.write_text(body)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _env(self, **extra: str) -> dict[str, str]:
        env = {
            **os.environ,
            "PATH": f"{self.bin_dir}:{os.environ['PATH']}",
            "STUB_LOG": str(self.log),
            "ENACT_EXE": str(self.bin_dir / "enact"),
            "ENACT_RECORDERS_DIR": str(self.recorders),
            "ENACT_VITEST_FORCE_TRACE": "Linux",
        }
        env.update(extra)
        return env

    def test_partitions_plain_node_attributed_and_workerd_targets(self) -> None:
        out_dir = self.repo / "footprints"
        wanted = self.repo / "wanted.txt"
        wanted.write_text(
            "services/mcp/tests/unit/a.test.ts\nservices/mcp/tests/workers/health.test.ts\n"
        )
        res = subprocess.run(
            [
                str(self.repo / ".enact/vitest/vitest.sh"),
                "run",
                "tests/unit/a.test.ts",
                "tests/unit/b.test.ts",
                "tests/workers/health.test.ts",
            ],
            cwd=self.pkg,
            env=self._env(
                ENACT_FOOTPRINT_DIR=str(out_dir),
                ENACT_FOOTPRINT_TARGETS=str(wanted),
            ),
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, res.returncode, res.stdout + res.stderr)
        lines = self.log.read_text().splitlines()
        # Plain unwanted target ran without attribution or --pool=forks.
        self.assertTrue(
            any("PNPM:exec vitest run tests/unit/b.test.ts|ATTR=|" in line for line in lines),
            lines,
        )
        # Wanted Node target ran via vitest-attribution.mjs with --pool=forks --isolate.
        self.assertTrue(
            any(
                "PNPM:exec vitest run tests/unit/a.test.ts --no-cache --pool=forks --isolate --reporter=default --reporter="
                in line
                and "vitest-attribution.mjs" in line
                for line in lines
            ),
            lines,
        )
        # Workerd target ran individually via `enact trace run -t ...` WITHOUT `--pool=forks`.
        self.assertTrue(
            any("-t services/mcp/tests/workers/health.test.ts" in line for line in lines),
            lines,
        )
        self.assertTrue(
            any("PNPM:exec vitest run tests/workers/health.test.ts|ATTR=|" in line for line in lines),
            lines,
        )

        attr_maps = list(out_dir.glob("vitest-attr-*.json"))
        self.assertEqual(1, len(attr_maps), attr_maps)
        attr_data = json.loads(attr_maps[0].read_text())
        self.assertTrue(attr_data["outcomes"])
        self.assertEqual(["services/mcp/tests/unit/a.test.ts"], sorted(attr_data["targets"].keys()))

        worker_maps = list(out_dir.glob("vitest-worker-*.json"))
        self.assertEqual(1, len(worker_maps), worker_maps)
        worker_data = json.loads(worker_maps[0].read_text())
        self.assertIn("services/mcp/tests/workers/health.test.ts", worker_data["targets"])


if __name__ == "__main__":
    unittest.main()
