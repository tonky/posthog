"""live_footprint.py's shared footprint holds what the job that recorded it ran: its own run
script (not the other live stack's), and the frontend build's inputs only when its app served
the build's outputs (the e2e specs' browser), never the desktop app's stylesheets, a workspace
of their own the bundle never takes in. Every e2e and MCP spec holds the shared footprint, so a
file in it that the job never read selects its whole suite. A spec's own footprint takes in
node_reads.mjs's records of its Node.js processes and their worker threads (NodeReadsTest).
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hermetic import helper_env  # noqa: E402

SCRIPTS = Path(__file__).resolve().parents[1]

FILES = [
    "showcase/scripts/live_posthog.sh",
    "showcase/scripts/run_e2e_tests.sh",
    "showcase/scripts/build_e2e.sh",
    "showcase/scripts/run_mcp_integration.sh",
    "pyproject.toml",
    "frontend/build.mjs",
    "frontend/src/styles/base.scss",
    "products/desktop/apps/code/global.css",
    "products/web_analytics/manifest.tsx",
]


class LiveFootprintTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        for file in FILES:
            (self.repo / file).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / file).write_text("x\n")
        # A production build's record: the frontend counts as built.
        (self.repo / "frontend/app-esbuild-meta.json").write_text('{"outputs": {}}')
        self.recording = self.repo / "recording"
        for sub in ("records", "node/1"):
            (self.recording / sub).mkdir(parents=True)

    def shared(self, job: str, served: bool) -> set[str]:
        if served:
            records = self.recording / "records"
            (records / "1.started").write_text("<shared>\n")
            (records / "1.json").write_text(json.dumps({"footprint": {"reads": ["frontend/dist/index.html"]}}))
        out = self.repo / "maps"
        env = helper_env() | {"ENACT_FOOTPRINT_DIR": str(out), "LIVE_JOB": job}
        subprocess.run(
            [sys.executable, str(SCRIPTS / "live_footprint.py"), "write", str(self.recording), "spec.ts=0"],
            cwd=self.repo,
            env=env,
            check=True,
            capture_output=True,
        )
        (written,) = [p for p in out.iterdir() if p.suffix == ".json"]
        return set(json.loads(written.read_text())["shared"]["files"])

    def test_the_mcp_job_holds_its_own_script_and_no_build(self):
        shared = self.shared("run_mcp_integration.sh", served=False)
        self.assertIn("showcase/scripts/run_mcp_integration.sh", shared)
        self.assertIn("showcase/scripts/live_posthog.sh", shared)
        for file in ["showcase/scripts/run_e2e_tests.sh", "showcase/scripts/build_e2e.sh", "frontend/build.mjs"]:
            self.assertNotIn(file, shared)
        self.assertFalse([f for f in shared if f.endswith((".css", ".scss"))], shared)

    def test_a_served_build_holds_its_inputs_but_not_the_desktop_app(self):
        shared = self.shared("run_e2e_tests.sh", served=True)
        for file in [
            "showcase/scripts/run_e2e_tests.sh",
            "showcase/scripts/build_e2e.sh",
            "frontend/build.mjs",
            "frontend/src/styles/base.scss",
            "products/web_analytics/manifest.tsx",
        ]:
            self.assertIn(file, shared)
        self.assertNotIn("showcase/scripts/run_mcp_integration.sh", shared)
        self.assertNotIn("products/desktop/apps/code/global.css", shared)

    def test_an_unknown_job_holds_every_script(self):
        shared = self.shared("", served=False)
        for file in ["showcase/scripts/run_e2e_tests.sh", "showcase/scripts/run_mcp_integration.sh"]:
            self.assertIn(file, shared)


# The spec's runner: reads a.txt, starts a worker that reads b.txt and then never returns (as
# esbuild's thread), and exits as soon as the worker has read.
MAIN = """
import fs from 'node:fs'
import { Worker } from 'node:worker_threads'
fs.readFileSync('a.txt')
const worker = process.argv[2] === 'eval'
    ? new Worker(fs.readFileSync('worker.cjs', 'utf8'), { eval: true })
    : new Worker(new URL('./worker.cjs', import.meta.url))
worker.unref()
worker.once('message', () => process.exit(0))
"""
WORKER = """
const fs = require('fs')
const { parentPort } = require('worker_threads')
fs.readFileSync('b.txt')
parentPort.postMessage('read')
setInterval(() => {}, 1000)
"""


class NodeReadsTest(unittest.TestCase):
    """node_reads.mjs records a spec's Node.js processes and their worker threads (live_footprint.py
    turns the records into its footprint). A worker thread can end with its process without an exit
    event: esbuild's sync-transform thread, which tsx starts on a cold cache (the first
    copy-instructions.ts run of each mcp recording), never returns. Its reads count, and the spec is
    complete when every worker recorded; a worker that never ran the preload (an eval worker) leaves
    the spec incomplete.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name).resolve()
        for name, text in [("a.txt", "a\n"), ("b.txt", "b\n"), ("main.mjs", MAIN), ("worker.cjs", WORKER)]:
            (self.repo / name).write_text(text)
        # No production build: the app served none.
        (self.repo / "frontend").mkdir()
        self.recording = self.repo / "recording"
        (self.recording / "records").mkdir(parents=True)
        # The app's record for the spec: it ran some Python.
        (self.recording / "records/1.started").write_text("spec.ts\n")
        (self.recording / "records/1.json").write_text(json.dumps({"footprint": {"reads": ["app.py"]}}))

    def footprint(self, mode: str) -> dict:
        env = helper_env() | {
            "ENACT_NODE_READS": str(self.recording / "node/1"),
            "ENACT_FOOTPRINT_ROOT": str(self.repo),
            "NODE_OPTIONS": f"--import {SCRIPTS / 'node_reads.mjs'}",
        }
        subprocess.run(["node", "main.mjs", mode], cwd=self.repo, env=env, check=True, timeout=60)
        out = self.repo / "maps"
        env = helper_env() | {"ENACT_FOOTPRINT_DIR": str(out), "LIVE_JOB": "run_mcp_integration.sh"}
        env.pop("NODE_OPTIONS", None)
        subprocess.run(
            [sys.executable, str(SCRIPTS / "live_footprint.py"), "write", str(self.recording), "spec.ts=0"],
            cwd=self.repo,
            env=env,
            check=True,
            capture_output=True,
        )
        (written,) = [p for p in out.iterdir() if p.suffix == ".json"]
        return json.loads(written.read_text())["targets"]["spec.ts"]

    def test_a_worker_ending_with_its_process_records_its_reads(self):
        target = self.footprint("file")
        self.assertNotIn("outcome", target)
        for file in ["a.txt", "b.txt", "worker.cjs", "main.mjs"]:
            self.assertIn(file, target["files"])

    def test_a_worker_without_the_preload_leaves_the_spec_incomplete(self):
        target = self.footprint("eval")
        self.assertIn("outcome", target)
        self.assertNotIn("b.txt", target["files"])
        self.assertTrue(os.listdir(self.recording / "node/1"))


if __name__ == "__main__":
    unittest.main()
