#!/usr/bin/env python3
"""Completes traced footprints with what the Rust binaries they ran were built from.

A Rust test binary reads its sources when it is compiled, not when it runs, so a traced run
(`enact trace run`) sees its fixtures, config and migrations but none of its code. Each map
`enact trace run --outcomes` wrote names one test binary by its root file (src/lib.rs,
src/main.rs, src/bin/<x>.rs, tests/<x>.rs); this adds to that target:

- the binary's own sources, from rustc's dep-info beside the executable (its modules and
  what `include_str!`/`include_bytes!` embed);
- the same of every workspace package it links: the package itself, its dev-dependencies and,
  from there, normal and build dependencies (cargo metadata's resolve), with their build
  scripts' sources and what those rerun on (`cargo::rerun-if-changed`, protos);
- those packages' manifests and their own files outside sources and test, bench and example
  trees: compile-time reads rustc doesn't track (sqlx's offline `.sqlx/` queries, embedded
  migrations);
- the workspace's manifest, lockfile and cargo config.

With `--built-from <root file>` (repeatable; repository-relative or absolute) the maps are
instead of tests that drove servers built from those binaries (`src/main.rs`, `src/bin/<x>.rs`;
a pytest or jest run traced with the services it starts, live_posthog.sh's specs): each of their
targets gets every such binary's inputs, as above without dev-dependencies, from the artifacts of
the `cargo build` that built them. A map's own `recorder` (one naming no footprint's) stays each
footprint's, among its `recorders`.

`--binary <target>=<root file>` (repeatable) names a target that isn't its test binary's root
file (rust_services:test_ignored's, by the file declaring its tests): it gets that binary's
inputs, here and with `--passed`.

`--passed <root file>` (repeatable) names a test binary whose traced run passed: one its map
doesn't hold (it read nothing in the repository, and the tracer refuses an empty footprint)
gets a footprint of what it was built from alone, in <dir>/rust_passed.json.

Usage: rust_footprint.py --repo <checkout> --artifacts <cargo test --no-run (or build) JSON lines>
         --metadata <cargo metadata JSON> --recorder <name/version> --out <dir>
         [--built-from <root file>]... [--binary <target>=<root file>]... [--passed <target>]...
         <map.json>...
Each map is written to <dir> under its own name, `"recorder"` set and each footprint naming it
among its `recorders`.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path

LIB_KINDS = {"lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro"}
# Trees of a package no other target's build reads (each of their binaries traces its own).
TARGET_TREES = ("tests/", "benches/", "examples/")


def read_dep_info(path: Path, base: Path) -> list[Path]:
    """The files a dep-info file's first rule lists, relative ones resolved against `base`."""
    try:
        text = path.read_text()
    except OSError:
        return []
    joined = text.replace("\\\n", " ")
    rule = next(
        (line for line in joined.splitlines() if not line.startswith("#") and ": " in line),
        None,
    )
    if rule is None:
        return []
    deps = rule.split(": ", 1)[1]
    files, current, escaped = [], [], False
    for char in deps:
        if escaped:
            current.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char.isspace():
            if current:
                files.append(base / "".join(current))
                current = []
        else:
            current.append(char)
    if current:
        files.append(base / "".join(current))
    return files


def dep_info_of(artifact: str) -> Path:
    """rustc's dep-info beside an artifact: `deps/libfoo-<hash>.rlib` and `deps/foo-<hash>`
    have `deps/foo-<hash>.d`."""
    path = Path(artifact)
    if path.suffix in {".rlib", ".rmeta", ".so", ".dylib", ".dll", ".a", ".exe"}:
        stem = path.stem
        stem = stem[3:] if stem.startswith("lib") else stem
        return path.with_name(stem + ".d")
    return path.with_name(path.name + ".d")


def trie_paths(value, prefix: str = "") -> set[str]:
    """The paths a footprint's `files` holds: a flat list, or enact's trie (directories as
    keys, `.` for the files of the directory itself)."""
    def join(name: str) -> str:
        name = name.removeprefix("./").lstrip("/")
        if name in ("", "."):
            return prefix
        return f"{prefix}/{name}" if prefix else name

    if value is None:
        return set()
    if isinstance(value, str):
        return {join(value)}
    if isinstance(value, list):
        return set().union(*(trie_paths(item, prefix) for item in value)) if value else set()
    if isinstance(value, dict):
        return set().union(*(trie_paths(child, join(key)) for key, child in value.items())) if value else set()
    raise ValueError(f"unexpected value in a footprint's files: {value!r}")


class Repo:
    """Paths under the checkout, relative to it (cargo reports them canonical)."""

    def __init__(self, root: Path):
        self.roots = [root.absolute()]
        resolved = root.resolve()
        if resolved != self.roots[0]:
            self.roots.append(resolved)

    def relative(self, path: Path) -> str | None:
        path = Path(os.path.normpath(path))
        for root in self.roots:
            try:
                rel = path.relative_to(root)
            except ValueError:
                continue
            return str(rel) if str(rel) != "." else None
        return None


class Build:
    """What `cargo test --no-run --message-format json` reported, by package."""

    def __init__(self, artifacts: Path, metadata: dict, repo: Repo):
        self.repo = repo
        self.workspace = Path(metadata["workspace_root"])
        self.members = set(metadata["workspace_members"])
        self.packages = {p["id"]: p for p in metadata["packages"]}
        self.deps = {
            node["id"]: [(dep["pkg"], {k.get("kind") for k in dep.get("dep_kinds", [])}) for dep in node["deps"]]
            for node in (metadata.get("resolve") or {}).get("nodes", [])
        }
        # package id -> the repository files its library and build script were built from
        self.package_inputs: dict[str, set[str]] = {}
        # test binary root file (repository-relative) -> its own sources
        self.tests: dict[str, set[str]] = {}
        # (non-test) binary root file -> its own sources
        self.bins: dict[str, set[str]] = {}
        for line in artifacts.read_text().splitlines():
            try:
                message = json.loads(line)
            except ValueError:
                continue
            self._record(message)

    def _record(self, message: dict) -> None:
        package = message.get("package_id", "")
        if package not in self.members:
            return
        if message.get("reason") == "build-script-executed":
            self._reruns(package, message)
            return
        if message.get("reason") != "compiler-artifact":
            return
        target = message["target"]
        sources = set()
        for artifact in message.get("filenames", []):
            info = dep_info_of(artifact)
            if info.is_file():
                sources.update(self._relative(read_dep_info(info, self.workspace)))
                break
        root = self.repo.relative(Path(target["src_path"]))
        if root:
            sources.add(root)
        if message.get("profile", {}).get("test") and message.get("executable") and root:
            self.tests.setdefault(root, set()).update(sources)
        elif "bin" in target["kind"] and message.get("executable") and root:
            self.bins.setdefault(root, set()).update(sources)
        elif LIB_KINDS & set(target["kind"]) or "custom-build" in target["kind"]:
            self.package_inputs.setdefault(package, set()).update(sources)

    def _reruns(self, package: str, message: dict) -> None:
        out_dir = message.get("out_dir")
        if not out_dir:
            return
        output = Path(out_dir).with_name("output")
        manifest_dir = Path(self.packages[package]["manifest_path"]).parent
        try:
            lines = output.read_text().splitlines()
        except OSError:
            return
        reruns = []
        for line in lines:
            for prefix in ("cargo::rerun-if-changed=", "cargo:rerun-if-changed="):
                if line.startswith(prefix):
                    reruns.append(manifest_dir / line[len(prefix):])
        inputs = self.package_inputs.setdefault(package, set())
        for path in reruns:
            rel = self.repo.relative(path)
            if rel is None:
                continue
            if path.is_dir():
                inputs.update(self._relative(p for p in path.rglob("*") if p.is_file()))
            elif path.is_file():
                inputs.add(rel)

    def _relative(self, paths) -> set[str]:
        return {rel for rel in (self.repo.relative(p) for p in paths) if rel}

    def linked(self, package: str, dev: bool) -> set[str]:
        """The workspace packages a binary of `package` links: itself, its dev-dependencies
        when it is a test binary (`dev`) and, from there, normal and build dependencies."""
        seen, stack = {package}, [package]
        while stack:
            current = stack.pop()
            for dep, kinds in self.deps.get(current, []):
                if dep not in self.members or dep in seen:
                    continue
                if "dev" in kinds and kinds <= {"dev"} and (current != package or not dev):
                    continue
                seen.add(dep)
                stack.append(dep)
        return seen


def package_files(build: Build, repo_root: Path) -> dict[str, set[str]]:
    """Each workspace package's tracked files that aren't Rust sources, outside its test,
    bench and example trees and the packages nested in it."""
    dirs = {
        pid: build.repo.relative(Path(build.packages[pid]["manifest_path"]).parent)
        for pid in build.members
    }
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--", *sorted({d for d in dirs.values() if d})],
        cwd=repo_root,
        capture_output=True,
        check=True,
    ).stdout.decode()
    files = [f for f in listed.split("\0") if f]
    owners = sorted(((d, pid) for pid, d in dirs.items() if d), key=lambda item: -len(item[0]))
    result: dict[str, set[str]] = {pid: set() for pid in build.members}
    for path in files:
        owner = next(((d, pid) for d, pid in owners if path.startswith(d + "/")), None)
        if owner is None:
            continue
        inner = path[len(owner[0]) + 1 :]
        if path.endswith(".rs") or inner.startswith(TARGET_TREES) or Path(inner).name == ".gitignore":
            continue
        result[owner[1]].add(path)
    return result


def binary_inputs(
    build: Build, roots: dict[str, set[str]], dev: bool, files: dict[str, set[str]], workspace_files: set[str]
) -> dict[str, set[str]]:
    """Each binary root's build inputs (`roots`: the build's test binaries, `dev`, or others)."""
    owner = {}
    for pid in build.members:
        for target in build.packages[pid]["targets"]:
            rel = build.repo.relative(Path(target["src_path"]))
            if rel:
                owner.setdefault(rel, pid)
    inputs = {}
    for root, own in roots.items():
        found = set(own) | workspace_files
        for pid in build.linked(owner[root], dev):
            found |= build.package_inputs.get(pid, set())
            found |= files.get(pid, set())
            manifest = build.repo.relative(Path(build.packages[pid]["manifest_path"]))
            if manifest:
                found.add(manifest)
        inputs[root] = found
    return inputs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--recorder", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--built-from", action="append", default=[], metavar="ROOT")
    parser.add_argument("--binary", action="append", default=[], metavar="TARGET=ROOT")
    parser.add_argument("--passed", action="append", default=[], metavar="TARGET")
    parser.add_argument("maps", nargs="*", type=Path)
    args = parser.parse_args()

    repo = Repo(args.repo)
    metadata = json.loads(args.metadata.read_text())
    build = Build(args.artifacts, metadata, repo)
    workspace = Path(metadata["workspace_root"])
    workspace_files = {
        rel
        for rel in (
            repo.relative(workspace / name)
            for name in ("Cargo.toml", "Cargo.lock", ".cargo/config.toml", "rust-toolchain.toml", "rust-toolchain")
            if (workspace / name).is_file()
        )
        if rel
    }
    files = package_files(build, args.repo)
    inputs = binary_inputs(build, build.bins if args.built_from else build.tests, not args.built_from, files, workspace_files)
    # Generated sources (a build script's OUT_DIR) are the build's output, not its input:
    # what generates them is there already (the script and what it reruns on).
    target = repo.relative(Path(metadata.get("target_directory", workspace / "target")))
    if target:
        inputs = {root: {f for f in found if not f.startswith(target + "/")} for root, found in inputs.items()}
    for alias in args.binary:
        target, _, root = alias.partition("=")
        if root in inputs:
            inputs[target] = inputs[root]
    served = None
    if args.built_from:
        # Given as cargo reports them (absolute, maybe canonical) or repository-relative.
        args.built_from = [repo.relative(Path(root)) or root if Path(root).is_absolute() else root for root in args.built_from]
        missing = [root for root in args.built_from if root not in inputs]
        for root in missing:
            print(f"rust_footprint: {root} is no binary of the build", flush=True)
        served = None if missing else set().union(*(inputs[root] for root in args.built_from))
    args.out.mkdir(parents=True, exist_ok=True)
    status = 0
    mapped = set()
    for map_path in args.maps:
        reach = json.loads(map_path.read_text())
        # The map's own recorder (live_footprint.py's) stays each footprint's, next to this.
        previous = reach.get("recorder")
        reach["recorder"] = args.recorder
        mapped.update(reach.get("targets", {}))
        for target, footprint in reach.get("targets", {}).items():
            # Next to the tracer's own (`enact-trace/1`) or the map's: a footprint naming its
            # recorders takes none from the map's `recorder`.
            recorders = set(footprint.get("recorders") or ([previous] if previous else []))
            footprint["recorders"] = sorted(recorders | {args.recorder})
            built = served if args.built_from else inputs.get(target)
            if built is None:
                # Not a binary this build made: its footprint can't hold its code (a gap,
                # not a failure: a failed run keeps its exit).
                if not args.built_from:
                    print(f"rust_footprint: {target} is no test binary of the build", flush=True)
                footprint.setdefault("outcome", "partial")
                status = 1
                continue
            footprint["files"] = sorted(trie_paths(footprint.get("files")) | built)
        (args.out / map_path.name).write_text(json.dumps(reach))
    unread = {
        root: {"files": sorted(inputs[root]), "recorders": [args.recorder]}
        for root in args.passed
        if root not in mapped and root in inputs and not args.built_from
    }
    if unread:
        reach = {"version": 1, "outcomes": True, "recorder": args.recorder, "targets": unread}
        (args.out / "rust_passed.json").write_text(json.dumps(reach))
    return status


if __name__ == "__main__":
    raise SystemExit(main())
