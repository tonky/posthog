"""live_footprint.py's shared footprint holds what the job that recorded it ran: its own run
script (not the other live stack's), and the frontend build's inputs only when its app served
the build's outputs (the e2e specs' browser), never the desktop app's stylesheets, a workspace
of their own the bundle never takes in. Every e2e and MCP spec holds the shared footprint, so a
file in it that the job never read selects its whole suite. A spec's own footprint takes in
node_reads.mjs's records of its Node.js processes and their worker threads (NodeReadsTest).
"""

import importlib.util
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

CORE = (
    Path(os.environ["ENACT_FOOTPRINT_CORE"])
    if os.environ.get("ENACT_FOOTPRINT_CORE")
    else Path(__file__).resolve().parents[6] / "crates/enact-runner/recorders/python/enact_footprint.py"
    if (Path(__file__).resolve().parents[6] / "crates/enact-runner/recorders/python/enact_footprint.py").exists()
    else SCRIPTS.parent / "pytest_plugins/enact_footprint.py"
)
spec = importlib.util.spec_from_file_location("provenance_core", CORE)
core = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = core
spec.loader.exec_module(core)

class ChildRecorderProvenanceTest(unittest.TestCase):
    def test_actual_and_unknown_recorder_ids_survive_every_merge_boundary(self):
        old = core.Footprint.load({"reads": ["child.txt"], "recorders": ["enact-trace/1", "custom/7"]}, native=True)
        current = core.Footprint.load({"recorders": ["enact-trace/2"]}, native=True)
        merged = core.Footprint.load(old.copy().dump())
        merged.update(current)
        entry = core._raw_target_v2(merged)
        self.assertEqual(set(entry["recorders"]), {"enact-trace/1", "enact-trace/2", "custom/7"})
        self.assertIn("child.txt", entry["reads"])
        self.assertFalse(merged.opaque)

    def test_a_legacy_native_record_without_provenance_is_incomplete(self):
        child = core.Footprint.load({"reads": ["child.txt"]}, native=True)
        self.assertTrue(any("kernel recorder provenance" in why for why in child.opaque))
        entry = core._raw_target_v2(child)
        self.assertIn("child.txt", entry["reads"])
        self.assertNotIn("enact-trace/2", entry.get("recorders", ()))

    def test_python_children_do_not_invent_native_coverage(self):
        child = core.Footprint.load({"reads": ["python.txt"]})
        self.assertFalse(child.opaque)
        self.assertNotIn("recorders", core._raw_target_v2(child))

    def test_socket_connect_attributes_loopback_services_and_emits_target_service_deps(self):
        fp = core.footprints.setdefault("api/test_db.py", core.Footprint())
        fp.services.clear()
        fp.duration_sec = 0.25
        prev = core.current
        core.current = fp
        try:
            core._audit_socket_connect((None, ("127.0.0.1", 5432)))
            core._audit_socket_connect((None, ("localhost", 6379)))
            core._audit_socket_connect((None, ("127.0.0.1", 9092)))
            core._audit_socket_connect((None, ("8.8.8.8", 5432)))
        finally:
            core.current = prev
        self.assertEqual(fp.services, {"postgres", "redis", "kafka"})
        entry = core._raw_target_v2(fp, is_shared=False)
        self.assertEqual(entry.get("duration_ms"), 250)
        with tempfile.TemporaryDirectory() as tmp:
            v2_path = core.write_raw_v2(tmp, "v2-")
            raw_v2 = json.loads(Path(v2_path).read_text())
            self.assertEqual(raw_v2.get("version"), 2)
            self.assertEqual(
                raw_v2["targets"]["api/test_db.py"].get("services"),
                ["kafka", "postgres", "redis"],
            )
            self.assertEqual(raw_v2["targets"]["api/test_db.py"].get("duration_ms"), 250)
        core.footprints.pop("api/test_db.py", None)


FILES = [
    "showcase/scripts/live_posthog.sh",
    "showcase/scripts/live_posthog.py",
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
        return set(self.written_map(job)["shared"]["files"])

    def written_map(self, job: str) -> dict:
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
        return json.loads(written.read_text())

    def native_shared_map(self, recorders=None) -> dict:
        records = self.recording / "records"
        (records / "1.started").write_text("spec.ts\n")
        (records / "1.json").write_text(json.dumps({"footprint": {"reads": ["app.py"]}}))
        (records / "2-xnative.started").write_text("<shared>\nexec:sh\n")
        child = {"reads": ["native.txt"]}
        if recorders is not None:
            child["recorders"] = recorders
        (records / "xnative.json").write_text(json.dumps({"footprint": child}))
        node = self.recording / "node/1"
        (node / "1.started").write_text("node\n")
        (node / "1.json").write_text(json.dumps({"reads": ["spec.ts"]}))
        return self.written_map("run_mcp_integration.sh")

    def test_native_shared_provenance_survives_alongside_both_adapter_stamps(self):
        raw = self.native_shared_map(["enact-trace/2", "external/9"])
        expected = {core.RECORDER, "live_footprint.py/3", "enact-trace/2", "external/9"}
        self.assertEqual(set(raw["shared"]["recorders"]), expected)
        # Shared metadata is laid over the spec by the normal map reader.
        self.assertEqual(set(raw["targets"]["spec.ts"]["recorders"]), {core.RECORDER, "live_footprint.py/3"})
        self.assertNotEqual(raw["targets"]["spec.ts"].get("outcome"), "partial")

    def test_a_shared_legacy_native_record_cannot_leave_a_complete_spec(self):
        raw = self.native_shared_map()
        self.assertEqual(raw["targets"]["spec.ts"]["outcome"], "partial")
        stats = next((self.repo / "maps").glob("*.stats"))
        reasons = json.loads(stats.read_text())["opaque"]["spec.ts"]
        self.assertTrue(any("kernel recorder provenance" in reason for reason in reasons), reasons)

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

    def test_staticfiles_resolve_against_restored_dist_esbuild_meta(self):
        # On a frontend:build cache hit, only frontend/dist (with .enact-esbuild-meta/) is restored.
        (self.repo / "frontend/app-esbuild-meta.json").unlink()
        meta_dir = self.repo / "frontend/dist/.enact-esbuild-meta"
        meta_dir.mkdir(parents=True)
        (self.repo / "frontend/src/App.tsx").parent.mkdir(parents=True, exist_ok=True)
        (self.repo / "frontend/src/App.tsx").write_text("export {}\n")
        (self.repo / "frontend/dist/index.js").write_text("console.log(1);\n")
        (meta_dir / "posthog-app-esbuild-meta.json").write_text(
            json.dumps(
                {
                    "inputs": {"src/App.tsx": {}},
                    "outputs": {"dist/index.js": {"inputs": {"src/App.tsx": {"bytesInOutput": 10}}}},
                }
            )
        )
        (self.repo / "staticfiles").mkdir(parents=True, exist_ok=True)
        (self.repo / "staticfiles/staticfiles.json").write_text(
            json.dumps({"paths": {"index.js": "index.abc123.js"}})
        )
        records = self.recording / "records"
        (records / "1.started").write_text("spec.ts\n")
        (records / "1.json").write_text(json.dumps({"footprint": {"reads": ["staticfiles/index.abc123.js"]}}))
        node = self.recording / "node/1"
        (node / "1.started").write_text("node\n")
        (node / "1.json").write_text(json.dumps({"reads": ["spec.ts"]}))
        out = self.repo / "maps"
        env = helper_env() | {"ENACT_FOOTPRINT_DIR": str(out), "LIVE_JOB": "run_e2e_tests.sh"}
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "live_footprint.py"), "write", str(self.recording), "spec.ts=0"],
            cwd=self.repo,
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertNotIn("read a build output without the build's record", result.stderr)
        (written,) = [p for p in out.iterdir() if p.suffix == ".json"]
        target = json.loads(written.read_text())["targets"]["spec.ts"]
        self.assertNotIn("outcome", target)
        self.assertIn("frontend/src/App.tsx", target["files"])

    def test_playwright_skip_records_mark_skipped_on_and_missing_records_are_partial(self):
        records = self.recording / "records"
        for idx, spec in enumerate(["pass.spec.ts", "skip.spec.ts", "unreported.spec.ts"], 1):
            (records / f"{idx}.started").write_text(f"{spec}\n")
            (records / f"{idx}.json").write_text(json.dumps({"footprint": {"reads": ["app.py"]}}))
            node = self.recording / f"node/{idx}"
            node.mkdir(parents=True, exist_ok=True)
            (node / "1.started").write_text("node\n")
            (node / "1.json").write_text(json.dumps({"reads": [spec]}))
        skips = self.recording / "skips"
        skips.mkdir(parents=True, exist_ok=True)
        (skips / "1.jsonl").write_text(
            json.dumps({"target": "pass.spec.ts", "outcome": "passed", "skipped": False, "reads": []}) + "\n"
        )
        (skips / "2.jsonl").write_text(
            json.dumps({"target": "skip.spec.ts", "outcome": "passed", "skipped": True, "reads": []}) + "\n"
        )
        out = self.repo / "maps"
        env = helper_env() | {"ENACT_FOOTPRINT_DIR": str(out), "LIVE_JOB": "run_e2e_tests.sh"}
        subprocess.run(
            [
                sys.executable,
                str(SCRIPTS / "live_footprint.py"),
                "write",
                str(self.recording),
                "pass.spec.ts=0",
                "skip.spec.ts=0",
                "unreported.spec.ts=0",
            ],
            cwd=self.repo,
            env=env,
            check=True,
            capture_output=True,
        )
        (written,) = [p for p in out.iterdir() if p.suffix == ".json"]
        targets = json.loads(written.read_text())["targets"]
        platform = "linux" if sys.platform.startswith("linux") else sys.platform
        self.assertNotIn("skipped_on", targets["pass.spec.ts"])
        self.assertNotIn("outcome", targets["pass.spec.ts"])
        self.assertEqual(targets["skip.spec.ts"].get("skipped_on"), [platform])
        self.assertNotIn("outcome", targets["skip.spec.ts"])
        self.assertNotIn("skipped_on", targets["unreported.spec.ts"])
        self.assertEqual(targets["unreported.spec.ts"].get("outcome"), "partial")

    def test_shared_files_dirs_and_loaded_are_deduplicated_from_targets(self):
        records = self.recording / "records"
        (records / "1.started").write_text("<shared>\n")
        (records / "1.json").write_text(
            json.dumps({"footprint": {"reads": ["app.py"], "dirs": ["posthog"], "loaded": ["mod_shared"]}})
        )
        (records / "2.started").write_text("spec.ts\n")
        (records / "2.json").write_text(
            json.dumps(
                {
                    "footprint": {
                        "reads": ["app.py", "spec_only.py"],
                        "dirs": ["posthog", "spec_dir"],
                        "loaded": ["mod_shared", "mod_spec"],
                    }
                }
            )
        )
        node = self.recording / "node/1"
        (node / "1.started").write_text("node\n")
        (node / "1.json").write_text(json.dumps({"reads": ["spec.ts"]}))
        raw = self.written_map("run_mcp_integration.sh")
        self.assertIn("app.py", raw["shared"]["files"])
        self.assertIn("posthog", raw["shared"]["dirs"])
        self.assertIn("mod_shared", raw["shared"]["loaded"])
        target = raw["targets"]["spec.ts"]
        self.assertNotIn("app.py", target["files"])
        self.assertIn("spec_only.py", target["files"])
        self.assertEqual(target["dirs"], ["spec_dir"])
        self.assertEqual(target["loaded"], ["mod_spec"])


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


class PytestFootprintOutcomesTest(unittest.TestCase):
    """Contract matrix for pytest_footprint._outcomes_and_skipped (Astra 201)."""

    def _load_plugin(self):
        import importlib.util
        import types

        repo_root = Path(__file__).resolve().parents[5]
        plugin_path = Path(__file__).resolve().parents[2] / "pytest_plugins" / "pytest_footprint.py"
        core_path = repo_root / "crates" / "enact-runner" / "recorders" / "python" / "enact_footprint.py"
        old_dir = os.environ.pop("ENACT_FOOTPRINT_DIR", None)
        old_core = os.environ.get("ENACT_FOOTPRINT_CORE")
        stubbed_pytest = False
        if "pytest" not in sys.modules:
            try:
                __import__("pytest")
            except ModuleNotFoundError:
                stub = types.ModuleType("pytest")
                stub.hookimpl = lambda *a, **kw: (lambda fn: fn)
                stub.Module = type("Module", (), {})
                sys.modules["pytest"] = stub
                stubbed_pytest = True
        if core_path.is_file():
            os.environ["ENACT_FOOTPRINT_CORE"] = str(core_path)
        try:
            spec = importlib.util.spec_from_file_location("pytest_footprint_unit", plugin_path)
            assert spec and spec.loader
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
        finally:
            if stubbed_pytest:
                sys.modules.pop("pytest", None)
            if old_dir is not None:
                os.environ["ENACT_FOOTPRINT_DIR"] = old_dir
            if old_core is not None:
                os.environ["ENACT_FOOTPRINT_CORE"] = old_core
            elif core_path.is_file():
                os.environ.pop("ENACT_FOOTPRINT_CORE", None)

    def test_completion_witness_contract_matrix(self):
        mod = self._load_plugin()
        # Clean session: passing, failed, deselected, module-skipped
        mod.collected.clear()
        mod.finished.clear()
        mod.failed.clear()
        mod.collection_failed.clear()
        mod.collected_modules.clear()
        mod.deselected.clear()
        mod.skipped.clear()
        mod.session_collection_failed = False
        mod.session_exitstatus = 0

        mod.collected.update({"t_pass.py": 2, "t_fail.py": 1, "t_partial.py": 2})
        mod.finished.update({"t_pass.py": 2, "t_fail.py": 1, "t_partial.py": 1})
        mod.failed.add("t_fail.py")
        mod.deselected.add("t_deselected.py")
        mod.skipped.add("t_mod_skip.py")
        mod.collected_modules.update({"t_empty_clean.py", "t_deselected.py"})

        targets = [
            "t_pass.py",
            "t_fail.py",
            "t_partial.py",
            "t_deselected.py",
            "t_mod_skip.py",
            "t_empty_clean.py",
            "t_unwitnessed.py",
        ]
        outcomes, skipped_dict = mod._outcomes_and_skipped(targets)
        self.assertNotIn("t_pass.py", outcomes)
        self.assertNotIn("t_mod_skip.py", outcomes)
        self.assertNotIn("t_empty_clean.py", outcomes)
        self.assertEqual([mod.PLATFORM], skipped_dict["t_mod_skip.py"])
        for bad in ("t_fail.py", "t_partial.py", "t_deselected.py", "t_unwitnessed.py"):
            self.assertIn(bad, outcomes, f"{bad} must be incomplete")
            self.assertIn("incomplete", outcomes[bad])

        # Unfinished session (exitstatus is None, e.g. crash before sessionfinish):
        # cleanly collected empty module cannot claim completion.
        mod.session_exitstatus = None
        outcomes_crash, _ = mod._outcomes_and_skipped(["t_empty_clean.py", "t_mod_skip.py"])
        self.assertIn("t_empty_clean.py", outcomes_crash)
        self.assertIn("t_mod_skip.py", outcomes_crash)

        # Collection-failed session (exit 2): collection error + unrun sibling + module-skip + empty all incomplete
        mod.collected.clear()
        mod.finished.clear()
        mod.failed.clear()
        mod.collection_failed.clear()
        mod.collected_modules.clear()
        mod.deselected.clear()
        mod.skipped.clear()
        mod.session_collection_failed = True
        mod.session_exitstatus = 2
        mod.collection_failed.add("t_err.py")
        mod.collected["t_sibling.py"] = 3
        mod.skipped.add("t_mod_skip.py")
        mod.collected_modules.add("t_empty_clean.py")

        outcomes2, _ = mod._outcomes_and_skipped(
            ["t_err.py", "t_sibling.py", "t_mod_skip.py", "t_empty_clean.py"]
        )
        self.assertEqual(
            outcomes2,
            {
                "t_err.py": {"incomplete": {"exit": 2}},
                "t_sibling.py": {"incomplete": {"exit": 2}},
                "t_mod_skip.py": {"incomplete": {"exit": 2}},
                "t_empty_clean.py": {"incomplete": {"exit": 2}},
            },
        )

    def test_partial_file_selection_three_row_table(self):
        """Astra 225 3-row regression table: whole file -> complete, -k first -> incomplete,
        explicit file.py::test_first -> incomplete; whole-file or enclosing-dir operands override ::."""
        mod = self._load_plugin()

        def reset():
            mod.collected.clear()
            mod.finished.clear()
            mod.failed.clear()
            mod.collection_failed.clear()
            mod.collected_modules.clear()
            mod.deselected.clear()
            mod.node_filtered.clear()
            mod.skipped.clear()
            mod.session_collection_failed = False
            mod.session_exitstatus = 0

        # Row 1: Whole file (2 passed) -> complete
        reset()
        mod.collected["tests/test_pair.py"] = 2
        mod.finished["tests/test_pair.py"] = 2
        outcomes, _ = mod._outcomes_and_skipped(["tests/test_pair.py"])
        self.assertNotIn("tests/test_pair.py", outcomes)

        # Row 2: Same file with `-k first` (1 passed, 1 deselected) -> incomplete
        reset()
        mod.collected["tests/test_pair.py"] = 1
        mod.finished["tests/test_pair.py"] = 1
        mod.deselected.add("tests/test_pair.py")
        outcomes, _ = mod._outcomes_and_skipped(["tests/test_pair.py"])
        self.assertEqual(outcomes, {"tests/test_pair.py": {"incomplete": {"exit": 1}}})

        # Row 3: Explicit `tests/test_pair.py::test_first` (1 passed, no deselection hook) -> incomplete
        reset()
        mod.collected["tests/test_pair.py"] = 1
        mod.finished["tests/test_pair.py"] = 1
        mod.node_filtered.update(mod._node_only_files(["tests/test_pair.py::test_first"]))
        self.assertIn("tests/test_pair.py", mod.node_filtered)
        outcomes, _ = mod._outcomes_and_skipped(["tests/test_pair.py"])
        self.assertEqual(outcomes, {"tests/test_pair.py": {"incomplete": {"exit": 1}}})

        # Whole-file or enclosing-directory operands alongside :: restore whole-file completeness.
        self.assertEqual(
            mod._node_only_files(["tests/test_pair.py", "tests/test_pair.py::test_first"]),
            set(),
        )
        self.assertEqual(
            mod._node_only_files(["tests", "tests/test_pair.py::test_first"]),
            set(),
        )
        self.assertEqual(
            mod._node_only_files(["tests/test_pair.py::TestCls::test_first"]),
            {"tests/test_pair.py"},
        )


if __name__ == "__main__":
    unittest.main()
