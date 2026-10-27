"""rust_footprint.py adds to a traced Rust test binary what it and the packages it links were
built from (run_rust_tests.sh's recorder), and to a test driving Rust servers (`--built-from`,
run_flags_integration.sh's and the rust ingestion e2e's) what those servers were built from.

A test binary reads its code when it is compiled, not when it runs: the trace of a run holds its
fixtures, never its sources, so without the build's inputs a change to the code it tests
would select none of its tests. The workspace here is cargo's output as files: dep-info beside
each artifact, `cargo test --no-run --message-format json` lines, `cargo metadata`'s resolve.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hermetic import helper_env  # noqa: E402

SCRIPTS = Path(__file__).resolve().parents[1]

# package -> (its dir under rust/, its normal deps, its dev deps)
PACKAGES = {
    "app": ("app", ["core"], ["testkit"]),
    "core": ("common/core", ["codegen"], []),
    "codegen": ("codegen", [], []),
    "testkit": ("testkit", ["core"], []),
    "other": ("other", [], []),
}


def pid(name: str, repo: Path) -> str:
    return f"path+file://{repo}/rust/{PACKAGES[name][0]}#{name}@0.1.0"


class RustFootprintTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        self.target = self.repo / "rust/target/debug"
        (self.target / "deps").mkdir(parents=True)
        files = [
            "rust/Cargo.toml",
            "rust/Cargo.lock",
            "rust/.sqlx/query-root.json",
            "rust/app/Cargo.toml",
            "rust/app/src/lib.rs",
            "rust/app/src/api.rs",
            "rust/app/src/main.rs",
            "rust/app/tests/flow.rs",
            "rust/app/tests/fixtures/event.json",
            "rust/app/tests/other.rs",
            "rust/app/.sqlx/query-a.json",
            "rust/app/lib/.gitignore",
            "rust/common/core/Cargo.toml",
            "rust/common/core/build.rs",
            "rust/common/core/src/lib.rs",
            "rust/common/core/migrations/0001.sql",
            "rust/codegen/Cargo.toml",
            "rust/codegen/src/lib.rs",
            "rust/testkit/Cargo.toml",
            "rust/testkit/src/lib.rs",
            "rust/other/Cargo.toml",
            "rust/other/src/lib.rs",
            "proto/core.proto",
        ]
        for f in files:
            (self.repo / f).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / f).write_text("")
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(["git", "add", "-A"], cwd=self.repo, check=True)
        self.messages = []
        # Library units (dep-info paths relative to the workspace, as rustc writes them).
        self.unit("app", "lib", "src/lib.rs", ["app/src/lib.rs", "app/src/api.rs"])
        self.unit("core", "lib", "src/lib.rs", ["common/core/src/lib.rs"])
        self.unit("core", "custom-build", "build.rs", ["common/core/build.rs"])
        self.unit("codegen", "proc-macro", "src/lib.rs", ["codegen/src/lib.rs"])
        self.unit("testkit", "lib", "src/lib.rs", ["testkit/src/lib.rs"])
        self.unit("other", "lib", "src/lib.rs", ["other/src/lib.rs"])
        # Test binaries: an integration test embedding a fixture, and app's unit tests.
        self.unit("app", "test", "tests/flow.rs", ["app/tests/flow.rs", "app/tests/fixtures/event.json"], test=True)
        # core's library includes what its build script generated.
        self.unit("core", "lib", "src/lib.rs", ["common/core/src/lib.rs", "target/debug/build/core-1/out/gen.rs"])
        self.unit("app", "lib", "src/lib.rs", ["app/src/lib.rs", "app/src/api.rs"], test=True)
        # app's server binary (`cargo build`), which a Python test drives.
        self.unit("app", "bin", "src/main.rs", ["app/src/main.rs"], executable=True)
        # core's build script reruns on the shared proto (present) and an optional bundle (absent).
        out_dir = self.target / "build/core-1/out"
        out_dir.mkdir(parents=True)
        (out_dir.parent / "output").write_text(
            "cargo::rerun-if-changed=../../../proto/core.proto\n"
            "cargo:rerun-if-changed=lib/optional-bundle.mjs\n"
        )
        self.messages.append({"reason": "build-script-executed", "package_id": pid("core", self.repo), "out_dir": str(out_dir)})

    def unit(self, package, kind, src, deps, test=False, executable=False):
        name = f"{package}-{kind}-{len(self.messages)}"
        exe = self.target / "deps" / name
        (self.target / "deps" / f"{name}.d").write_text(f"{exe}: " + " ".join(deps) + "\n")
        directory = PACKAGES[package][0]
        self.messages.append(
            {
                "reason": "compiler-artifact",
                "package_id": pid(package, self.repo),
                "manifest_path": str(self.repo / "rust" / directory / "Cargo.toml"),
                "target": {"kind": [kind], "name": package, "src_path": str(self.repo / "rust" / directory / src)},
                "profile": {"test": test},
                "filenames": [str(exe)],
                "executable": str(exe) if test or executable else None,
            }
        )

    def metadata(self):
        packages, nodes = [], []
        for name, (directory, deps, dev) in PACKAGES.items():
            packages.append(
                {
                    "id": pid(name, self.repo),
                    "name": name,
                    "manifest_path": str(self.repo / "rust" / directory / "Cargo.toml"),
                    "targets": [{"kind": ["lib"], "name": name, "src_path": str(self.repo / "rust" / directory / "src/lib.rs")}]
                    + (
                        [{"kind": ["test"], "name": "flow", "src_path": str(self.repo / "rust" / directory / "tests/flow.rs")},
                         {"kind": ["bin"], "name": "app", "src_path": str(self.repo / "rust" / directory / "src/main.rs")}]
                        if name == "app"
                        else []
                    ),
                }
            )
            nodes.append(
                {
                    "id": pid(name, self.repo),
                    "deps": [{"pkg": pid(d, self.repo), "dep_kinds": [{"kind": None}]} for d in deps]
                    + [{"pkg": pid(d, self.repo), "dep_kinds": [{"kind": "dev"}]} for d in dev],
                }
            )
        return {
            "workspace_root": str(self.repo / "rust"),
            "target_directory": str(self.repo / "rust/target"),
            "workspace_members": [pid(n, self.repo) for n in PACKAGES],
            "packages": packages,
            "resolve": {"nodes": nodes},
        }

    def record(self, traced: dict, *options: str, live: bool = False) -> dict:
        """rust_footprint.py over a map per traced target, `enact trace run`'s; `live`: one map
        of them all, live_footprint.py's (its `recorder`, a `shared` part, no footprint naming
        its recorders)."""
        work = self.repo / "work"
        work.mkdir()
        (work / "artifacts.jsonl").write_text("\n".join(json.dumps(m) for m in self.messages))
        (work / "metadata.json").write_text(json.dumps(self.metadata()))
        maps = []
        if live:
            path = work / "live-shard1-1.json"
            reach = {"version": 1, "recorder": "live_footprint.py/2", "outcomes": True, "shared": {"files": ["uv.lock"]}}
            reach["targets"] = {target: {"files": files, "loaded_through": 0} for target, files in traced.items()}
            path.write_text(json.dumps(reach))
            maps.append(str(path))
        for i, (target, files) in enumerate(() if live else traced.items()):
            path = work / f"rust_{i}.json"
            footprint = {"files": files, "recorders": ["enact-trace/1"]}
            path.write_text(json.dumps({"version": 1, "outcomes": True, "targets": {target: footprint}}))
            maps.append(str(path))
        out = self.repo / "out"
        run = subprocess.run(
            [sys.executable, str(SCRIPTS / "rust_footprint.py"), "--repo", str(self.repo), "--artifacts", str(work / "artifacts.jsonl"),
             "--metadata", str(work / "metadata.json"), "--recorder", "rust_footprint.py/1", "--out", str(out), *options, *maps],
            capture_output=True, text=True,
        )
        result = {}
        for path in sorted(out.glob("*.json")):
            reach = json.loads(path.read_text())
            self.assertEqual(reach["recorder"], "rust_footprint.py/1")
            result.update(reach["targets"])
        return run, result

    def test_a_test_binary_holds_what_it_and_its_linked_packages_were_built_from(self):
        # The trace's own files come as enact's trie.
        run, targets = self.record({"rust/app/tests/flow.rs": {"rust": {"app": {"tests": {"fixtures": ["event.json"]}}}}})
        self.assertEqual(run.returncode, 0, run.stderr)
        files = set(targets["rust/app/tests/flow.rs"]["files"])
        # Both recorders made it: a new rust_footprint.py version re-records it.
        self.assertEqual(targets["rust/app/tests/flow.rs"]["recorders"], ["enact-trace/1", "rust_footprint.py/1"])
        expected = {
            # what the run read, kept
            "rust/app/tests/fixtures/event.json",
            # its own sources and app's library, which it links
            "rust/app/tests/flow.rs",
            "rust/app/src/lib.rs",
            "rust/app/src/api.rs",
            # the linked packages: core (normal), its proc macro and build script, what that
            # reruns on, testkit (dev); their manifests and untracked-by-rustc files
            "rust/common/core/src/lib.rs",
            "rust/common/core/build.rs",
            "proto/core.proto",
            "rust/common/core/migrations/0001.sql",
            "rust/codegen/src/lib.rs",
            "rust/testkit/src/lib.rs",
            "rust/app/Cargo.toml",
            "rust/common/core/Cargo.toml",
            "rust/codegen/Cargo.toml",
            "rust/testkit/Cargo.toml",
            "rust/app/.sqlx/query-a.json",
            # the workspace's manifest and lockfile
            "rust/Cargo.toml",
            "rust/Cargo.lock",
        }
        self.assertEqual(files, expected)
        # Not linked: another package, and app's other test binary.
        self.assertNotIn("rust/other/src/lib.rs", files)
        self.assertNotIn("rust/app/tests/other.rs", files)

    def test_a_target_the_build_made_no_test_binary_of_lands_partial(self):
        run, targets = self.record({"rust/other/tests/none.rs": ["rust/other/x"]})
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("is no test binary of the build", run.stdout)
        self.assertEqual(targets["rust/other/tests/none.rs"]["outcome"], "partial")

    def test_a_passing_test_binary_that_read_nothing_holds_what_it_was_built_from(self):
        # The tracer refused its empty footprint: its map holds another binary only.
        run, targets = self.record(
            {"rust/app/src/lib.rs": ["rust/app/src/lib.rs"]}, "--passed", "rust/app/tests/flow.rs", "--passed", "rust/app/src/lib.rs"
        )
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(targets["rust/app/tests/flow.rs"]["recorders"], ["rust_footprint.py/1"])
        self.assertIn("rust/common/core/src/lib.rs", targets["rust/app/tests/flow.rs"]["files"])
        self.assertNotIn("outcome", targets["rust/app/tests/flow.rs"])

    def test_a_target_named_by_its_tests_file_holds_what_its_binary_was_built_from(self):
        # rust_services:test_ignored's: the file declaring the ignored tests, run in the
        # library's unit-test binary, traced (api.rs) or passing with nothing read (main.rs).
        run, targets = self.record(
            {"rust/app/src/api.rs": ["rust/app/.sqlx/query-a.json"]},
            "--binary", "rust/app/src/api.rs=rust/app/src/lib.rs",
            "--binary", "rust/app/src/main.rs=rust/app/src/lib.rs",
            "--passed", "rust/app/src/main.rs",
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        for target in ("rust/app/src/api.rs", "rust/app/src/main.rs"):
            files = set(targets[target]["files"])
            self.assertTrue({"rust/app/src/lib.rs", "rust/common/core/src/lib.rs", "rust/testkit/src/lib.rs"} <= files, target)
            self.assertNotIn("outcome", targets[target])

    def test_a_test_driving_a_server_holds_what_the_server_was_built_from(self):
        test = "posthog/api/test/rust_integration/test_flags.py"
        run, targets = self.record({test: ["posthog/api/feature_flag.py"]}, "--built-from", "rust/app/src/main.rs")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(targets[test]["recorders"], ["enact-trace/1", "rust_footprint.py/1"])
        files = set(targets[test]["files"])
        self.assertLessEqual(
            {
                # what the run read, kept
                "posthog/api/feature_flag.py",
                # the server's own sources, its package's library and the packages it links
                "rust/app/src/main.rs",
                "rust/app/src/lib.rs",
                "rust/common/core/src/lib.rs",
                "proto/core.proto",
                "rust/codegen/src/lib.rs",
                "rust/app/.sqlx/query-a.json",
                "rust/Cargo.lock",
            },
            files,
        )
        # A server links no dev-dependency, nor any test binary's sources.
        self.assertNotIn("rust/testkit/src/lib.rs", files)
        self.assertNotIn("rust/app/tests/flow.rs", files)
        self.assertNotIn("rust/other/src/lib.rs", files)

    def test_live_specs_hold_what_every_server_of_the_stack_was_built_from(self):
        # live_posthog.sh's: one map of the specs, the servers named as cargo metadata does.
        specs = {"playwright/e2e/a.spec.ts": ["playwright/e2e/a.spec.ts"], "playwright/e2e/b.spec.ts": ["posthog/api/x.py"]}
        run, targets = self.record(specs, "--built-from", str(self.repo / "rust/app/src/main.rs"), live=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        for spec, read in specs.items():
            # The map's recorder stays each spec's: a new live_footprint.py version re-records it.
            self.assertEqual(targets[spec]["recorders"], ["live_footprint.py/2", "rust_footprint.py/1"])
            self.assertEqual(targets[spec]["loaded_through"], 0)
            files = set(targets[spec]["files"])
            self.assertLessEqual({*read, "rust/app/src/main.rs", "rust/common/core/src/lib.rs", "rust/Cargo.lock"}, files)
            self.assertNotIn("rust/testkit/src/lib.rs", files)
        reach = json.loads((self.repo / "out/live-shard1-1.json").read_text())
        self.assertEqual(reach["shared"], {"files": ["uv.lock"]})

    def test_a_server_the_build_made_no_binary_of_leaves_its_passing_tests_partial(self):
        test = "posthog/api/test/rust_integration/test_flags.py"
        run, targets = self.record({test: ["posthog/api/feature_flag.py"]}, "--built-from", "rust/other/src/main.rs")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("rust/other/src/main.rs is no binary of the build", run.stdout)
        self.assertEqual(targets[test]["outcome"], "partial")


# run_rust_release_build.sh builds the crates it is given, by name or by manifest: rust_services:build's
# targets are the manifests its suite lists (`--targets rust/<crate>/Cargo.toml`, relative to the
# directory enact runs it from) as well as the names rust_affected_crates.sh prints; cargo took a
# manifest for a package spec ("looks like a file path") and the build failed. Here, not in a file of
# its own: a file added under showcase/scripts/tests ages every helper test's footprint (a listing).
class RustReleaseBuildTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.repo)
        scripts = self.repo / "showcase" / "scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SCRIPTS / "run_rust_release_build.sh", scripts)
        # The profile's settings it unsets come from enve.cue; none here.
        (scripts / "rust_ci_env.sh").write_text("unset_args=(-u RUST_RELEASE_BUILD_TEST_UNSET)\n")
        crate = self.repo / "rust" / "common" / "limiters"
        crate.mkdir(parents=True)
        (crate / "Cargo.toml").write_text(
            '[lints]\nworkspace = true\n\n[package]\nname = "limiters"\nversion = "0.1.0"\n\n'
            '[lib]\nname = "limiters_lib"\n\n[dependencies]\nserde = { workspace = true }\n'
        )
        bin_dir = self.repo / "bin"
        bin_dir.mkdir()
        self.argv = self.repo / "cargo.argv"
        cargo = bin_dir / "cargo"
        cargo.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$(pwd -P)" "$@" > {self.argv}\n')
        cargo.chmod(0o755)
        self.env = {**helper_env(), "PATH": f"{bin_dir}:{os.environ['PATH']}"}

    def build(self, cwd: Path, *targets: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.repo / "showcase" / "scripts" / "run_rust_release_build.sh"), *targets],
            cwd=cwd,
            env=self.env,
            capture_output=True,
            text=True,
        )

    def test_a_manifest_target_builds_its_package(self) -> None:
        out = self.build(self.repo / "rust", "../rust/common/limiters/Cargo.toml", "capture")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(
            self.argv.read_text().splitlines(),
            [str((self.repo / "rust").resolve()), "build", "-p", "limiters", "-p", "capture", "--locked", "--release"],
        )

    def test_a_manifest_without_a_package_fails_naming_it(self) -> None:
        (self.repo / "rust" / "Cargo.toml").write_text('[workspace]\nmembers = ["common/*"]\n')
        out = self.build(self.repo, "rust/Cargo.toml")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("no [package] name in rust/Cargo.toml", out.stderr)
        self.assertFalse(self.argv.exists())

    def test_no_targets_build_the_workspace(self) -> None:
        out = self.build(self.repo)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.argv.read_text().splitlines()[1:], ["build", "--workspace", "--locked", "--release"])



if __name__ == "__main__":
    unittest.main()
