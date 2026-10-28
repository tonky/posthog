"""live_footprint: enact footprints for the jobs that drive a live PostHog (run_e2e_tests.sh,
run_mcp_integration.sh), recorded per spec file. A spec's test passes through three processes'
code: the test runner's (Node.js), the served app's (Django's web server, its Celery worker),
and, for the e2e specs, the browser's (the frontend bundle Django serves). A footprint holds
all three; live_posthog.sh then adds what the Rust services the stack ran were built from
(rust_footprint.py --built-from), as their runs read none of their code.

Attribution is by restart, not by request: with $ENACT_FOOTPRINT_DIR set, the job starts the
app's Python processes afresh for each spec file, recording for it (enact_footprint.py's child
mode: a `sitecustomize` on PYTHONPATH, ENACT_FOOTPRINT_TARGET the spec), runs that spec alone,
then stops them (their records written at exit) and clears the app's Redis caches before the
next. One long-lived server serving every spec would hand each spec what an earlier one left:
a query cached in Redis (the query cache serves another spec's result without running the
code that computed it), a module-level cache, a lazily imported module. Setup (migrations,
demo data, keys) records for every spec (`shared`).

  live_footprint.py prepare <dir>
      the recording directory: boot/sitecustomize.py (enact_footprint's child boot), records/
      (the Python processes' records), node/<n>/ (node_reads.mjs's, spec n's)
  live_footprint.py write <dir> <spec>=<exit status>...
      the map, in $ENACT_FOOTPRINT_DIR: one target per spec (failed with its exit status when
      its run failed, partial when it passed but a process left no record), `shared` the
      setup's

The browser half: the app's reads of the built frontend (Django's templates in frontend/dist,
WhiteNoise's opens of staticfiles/) stand for the repository files they were made from: an
esbuild output for the inputs in it (<name>-esbuild-meta.json, written by the production
build), a file copied from frontend/public for that file. A spec whose app read a build output
this can't trace back is incomplete. A file WhiteNoise only stat'ed (its index of the static
root, made at start) or a listing of the static root says nothing of the spec.
"""

import filecmp
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "pytest_plugins"))
import enact_footprint as core  # noqa: E402

RECORDER = "live_footprint.py/3"
ROOT = os.getcwd()
# What the jobs run that no process here records reading: their own scripts, what their shell
# reads, and what uv reads before Python starts.
HARNESS = [
    "showcase/scripts/live_posthog.sh",
    "showcase/scripts/test_databases.sh",
    "showcase/scripts/build_once.sh",
    "showcase/scripts/exclusive.sh",
    "bin/celery-queues.env",
    "bin/download-mmdb",
    "products/db_routing.yaml",
    "pyproject.toml",
    "uv.lock",
]
# Each job's own scripts, by the run script live_posthog.sh's caller is ($LIVE_JOB); an unknown
# one holds them all.
JOB_SCRIPTS = {
    "run_e2e_tests.sh": ["showcase/scripts/run_e2e_tests.sh", "showcase/scripts/build_e2e.sh"],
    "run_mcp_integration.sh": ["showcase/scripts/run_mcp_integration.sh"],
}
# What the frontend's production build reads besides its inputs (frontend/build.mjs, its
# esbuilder, the scripts `pnpm build` runs first) and the manifests build:products reads.
FRONTEND_HARNESS = [
    "package.json",
    "pnpm-lock.yaml",
    "pnpm-workspace.yaml",
    "tsconfig.json",
    "frontend/package.json",
    "frontend/tsconfig.json",
    "frontend/build.mjs",
    "frontend/build-products.mjs",
    "frontend/workers.config.mjs",
    "frontend/bin/copy-posthog-js",
    "frontend/src/queries/schema/schema-general.ts",
]
FRONTEND_HARNESS_DIRS = ["common/esbuilder"]
# frontend/dist files common/esbuilder copies from node_modules (copySnappyWASMFile).
INSTALLED_COPIES = {"snappy_bg.wasm"}
STYLESHEET_DIRS = ["frontend", "products", "common", "packages/quill", "ee/frontend"]
# products/desktop: a pnpm workspace of its own (pnpm-workspace.yaml), never in the bundle.
STYLESHEET_SKIPPED = ("products/desktop/",)
STATIC_ROOT = "staticfiles/"
DIST = "frontend/dist/"
SKIPPED = {"node_modules", "dist", ".turbo", ".cache", "__snapshots__", "__pycache__"}


def prepare(directory: str) -> None:
    for sub in ("boot", "records", "node"):
        os.makedirs(os.path.join(directory, sub), exist_ok=True)
    with open(os.path.join(directory, "boot", "sitecustomize.py"), "w") as f:
        f.write(core.BOOT)


def python_records(directory: str) -> dict[str, core.Footprint]:
    """The Python processes' records by target; one started without a record is opaque."""
    records = os.path.join(directory, "records")
    out: dict[str, core.Footprint] = {}
    for name in sorted(os.listdir(records)):
        if not name.endswith(".started"):
            continue
        stem = name[: -len(".started")]
        with open(os.path.join(records, name)) as f:
            token = f.read().partition("\n")[0]
        native = stem.partition("-")[2].startswith("x")
        fp = out.setdefault(token, core.Footprint())
        try:
            with open(os.path.join(records, core._record_of(stem))) as f:
                fp.update(core.Footprint.load(json.load(f)["footprint"], native=native))
        except (OSError, ValueError, KeyError):
            fp.opaque.add("a Python process of the app ended without its record")
    return out


def node_records(directory: str) -> core.Footprint:
    """node_reads.mjs's records in `directory`: a process' `.json` at exit, a worker thread's
    `.jsonl` log; a process or worker started without one is opaque, and so is a spec no Node.js
    process recorded (its test runner ran without the preload)."""
    fp = core.Footprint()
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        names = []
    if not any(name.endswith(".started") for name in names):
        fp.opaque.add("no test runner process recorded for it")
    for name in names:
        if not name.endswith(".started"):
            continue
        stem = os.path.join(directory, name[: -len(".started")])
        try:
            record = _node_record(stem)
        except (OSError, ValueError):
            with open(os.path.join(directory, name)) as f:
                argv = f.read()[:200]
            fp.opaque.add(f"a Node.js process ended without its record ({argv})")
            continue
        fp.reads.update(record.get("reads", ()))
        fp.present.update(record.get("present", ()))
        fp.probes.update(record.get("probes", ()))
        fp.dirs.update(record.get("dirs", ()))
    return fp


def _node_record(stem: str) -> dict[str, list[str]]:
    """A process' record (`<stem>.json`), else a worker's log (`<stem>.jsonl`, `[set, path]`
    lines; a torn last line is one the worker was writing as it ended: its call never ran)."""
    try:
        with open(stem + ".json") as f:
            return json.load(f)
    except FileNotFoundError:
        pass
    record: dict[str, list[str]] = {}
    with open(stem + ".jsonl") as f:
        lines = f.read().split("\n")
    for line in lines[:-1]:
        kind, path = json.loads(line)
        record.setdefault(kind, []).append(path)
    return record


def _walk(directory: str, keep) -> list[str]:
    found = []
    for base, dirs, files in os.walk(os.path.join(ROOT, directory)):
        dirs[:] = [d for d in dirs if d not in SKIPPED and not d.startswith(".")]
        rel = os.path.relpath(base, ROOT)
        found.extend(f"{rel}/{f}" for f in files if keep(f"{rel}/{f}"))
    return found


class Frontend:
    """The production build's outputs (frontend/dist) and what each was made from."""

    def __init__(self):
        self.outputs: dict[str, set[str]] = {}  # dist-relative name -> repository files
        self.held: set[str] = set()
        self.loaded = False
        frontend = os.path.join(ROOT, "frontend")
        metas = [n for n in sorted(os.listdir(frontend)) if n.endswith("-esbuild-meta.json")]
        if not metas:
            return
        self.loaded = True
        for meta in metas:
            with open(os.path.join(frontend, meta)) as f:
                self._add(json.load(f))
        self.held = set().union(*self.outputs.values()) if self.outputs else set()
        manifest = os.path.join(ROOT, STATIC_ROOT, "staticfiles.json")
        self.unhashed: dict[str, str] = {}
        try:
            with open(manifest) as f:
                self.unhashed = {hashed: name for name, hashed in json.load(f).get("paths", {}).items()}
        except (OSError, ValueError):
            pass

    @staticmethod
    def _repo(path: str) -> str | None:
        """An esbuild path (from frontend/) as the repository's, None for installed packages."""
        namespace, colon, rest = path.partition(":")
        if colon and "/" not in namespace:
            # A plugin's namespace (`sass-plugin-0:/…/x.scss`): its file, if it names one.
            if not rest.startswith("/"):
                return None
            absolute = os.path.normpath(rest)
        else:
            absolute = os.path.normpath(os.path.join(ROOT, "frontend", path))
        rel = os.path.relpath(absolute, ROOT)
        if rel.startswith("..") or "node_modules" in rel.split(os.sep):
            return None
        return rel

    def _add(self, meta: dict) -> None:
        inputs = meta.get("inputs", {})
        holders: dict[str, set[str]] = {}
        for output, info in meta.get("outputs", {}).items():
            name = self._repo(output)
            if not name or not name.startswith(DIST):
                continue
            name = name[len(DIST):]
            files = self.outputs.setdefault(name, set())
            for path in info.get("inputs", {}):
                holders.setdefault(path, set()).add(name)
                rel = self._repo(path)
                if rel:
                    files.add(rel)
        # An input no output holds (shaken out whole): the outputs of its nearest held
        # importers, where an added side effect would land.
        importers: dict[str, set[str]] = {}
        for path, info in inputs.items():
            for imported in info.get("imports", ()):
                if imported.get("path") in inputs:
                    importers.setdefault(imported["path"], set()).add(path)
        for path in inputs:
            rel = self._repo(path)
            if path in holders or not rel:
                continue
            seen, queue = {path}, [path]
            while queue:
                for importer in importers.get(queue.pop(), ()):
                    if importer in seen:
                        continue
                    seen.add(importer)
                    if importer in holders:
                        for name in holders[importer]:
                            self.outputs[name].add(rel)
                    else:
                        queue.append(importer)

    def sources(self, name: str) -> list[str] | None:
        """The repository files frontend/dist/<name> was made from; None: unknown."""
        if name in self.outputs:
            return sorted(self.outputs[name])
        # A worker's fixed name (workers.config.mjs' outfileName) beside the hashed output the
        # metafile names: the same bytes, the same sources.
        stem, ext = os.path.splitext(name)
        hashed = [o for o in self.outputs if re.fullmatch(re.escape(stem) + r"-[A-Z0-9]{8}" + re.escape(ext), o)]
        dist = os.path.join(ROOT, DIST)
        for output in hashed:
            try:
                if filecmp.cmp(os.path.join(dist, name), os.path.join(dist, output), shallow=False):
                    return sorted(self.outputs[output])
            except OSError:
                pass
        if name.endswith(".html"):
            # The pages build.mjs writes from its templates (common/esbuilder's createHtmlPages).
            template = f"frontend/src/{name}"
            return [template] if os.path.isfile(os.path.join(ROOT, template)) else []
        public = f"frontend/public/{name}"
        if os.path.isfile(os.path.join(ROOT, public)):
            return [public]  # copied by build.mjs (copyPublicFolder)
        if os.path.isfile(os.path.join(ROOT, "frontend/node_modules/posthog-js/dist", name)):
            return ["frontend/bin/copy-posthog-js"]  # posthog-js' bundles (its version: the lockfile)
        if name in INSTALLED_COPIES:
            return []  # copied from an installed package by common/esbuilder (the lockfile's)
        if name == "preload-manifest.json" or (name.startswith("chunk-map-") and name.endswith(".js")):
            # Lists of the build's own outputs (build.mjs's preload manifest, common/esbuilder's
            # chunk map): what they make the page fetch is read, and mapped, in its own right.
            return []
        return None

    def static_sources(self, name: str) -> list[str] | None:
        """staticfiles/<name>, collected from frontend/dist (STATICFILES_DIRS) or an app."""
        if name == "staticfiles.json":
            return []  # the names' index: each file served counts by its own read
        for suffix in (".gz", ".br"):
            if name.endswith(suffix):
                name = name[: -len(suffix)]
        name = self.unhashed.get(name, name)
        if os.path.exists(os.path.join(ROOT, DIST, name)):
            return self.sources(name)
        # An app's static files: the repository's own, or an installed package's.
        for app in ("posthog", "ee"):
            own = f"{app}/static/{name}"
            if os.path.isfile(os.path.join(ROOT, own)):
                return [own]
        return []

    def stylesheets(self) -> list[str]:
        """Stylesheets no output holds: Sass partials, which esbuild's inputs leave out."""
        found = []
        for directory in STYLESHEET_DIRS:
            found.extend(
                _walk(
                    directory,
                    lambda f: f.endswith((".scss", ".sass", ".css"))
                    and f not in self.held
                    and not f.startswith(STYLESHEET_SKIPPED),
                )
            )
        return found


def map_built(fp: core.Footprint, frontend: Frontend) -> None:
    """Replaces the build outputs `fp` holds with their sources (module docstring)."""

    def built(rel: str) -> str | None:
        if rel.startswith(STATIC_ROOT):
            return "static"
        if rel.startswith(DIST):
            return "dist"
        return None

    for name in ("present", "dirs", "probes"):
        setattr(fp, name, {rel for rel in getattr(fp, name) if not built(rel) and rel.rstrip("/") + "/" not in (STATIC_ROOT, DIST)})
    for rel in sorted(rel for rel in fp.reads if built(rel)):
        fp.reads.discard(rel)
        if not frontend.loaded:
            # No production build (the MCP job's page stubs): nothing of the frontend's.
            if rel.startswith(DIST) and rel.endswith(".html"):
                continue
            fp.opaque.add(f"read a build output without the build's record: {rel}")
            continue
        if built(rel) == "static":
            sources = frontend.static_sources(rel[len(STATIC_ROOT):])
        else:
            sources = frontend.sources(rel[len(DIST):])
        if sources is None:
            fp.opaque.add(f"read a build output it can't trace to its sources: {rel}")
        else:
            fp.reads.update(sources)


def entry(fp: core.Footprint, shared: core.Footprint | None = None) -> dict:
    fp.collapse_probes({})
    result = fp.entry(0, {}, (), shared)
    result["recorders"] = sorted(set(result["recorders"]) | {RECORDER})
    return result


def write(directory: str, results: list[str]) -> None:
    out_dir = os.environ["ENACT_FOOTPRINT_DIR"]
    core.root = ROOT + os.sep
    python = python_records(directory)
    frontend = Frontend()
    shared = python.pop(core.SHARED, core.Footprint())
    job = os.environ.get("LIVE_JOB", "")
    scripts = JOB_SCRIPTS.get(job, [s for listed in JOB_SCRIPTS.values() for s in listed])
    shared.reads.update(f for f in HARNESS + scripts if os.path.isfile(os.path.join(ROOT, f)))
    # The build's own inputs only where the app served its outputs (the e2e specs' browser):
    # a job whose app read none (the MCP tools' API calls) ran nothing the build made.
    served = any(
        rel.startswith((DIST, STATIC_ROOT))
        for fp in [shared, *python.values()]
        for rel in fp.reads
    )
    if frontend.loaded and served:
        shared.reads.update(f for f in FRONTEND_HARNESS if os.path.isfile(os.path.join(ROOT, f)))
        for directory_ in FRONTEND_HARNESS_DIRS:
            shared.reads.update(_walk(directory_, lambda f: True))
        products = os.path.join(ROOT, "products")
        shared.reads.update(
            f"products/{p}/manifest.tsx"
            for p in sorted(os.listdir(products))
            if os.path.isfile(os.path.join(products, p, "manifest.tsx"))
        )
        shared.reads.update(frontend.stylesheets())
    map_built(shared, frontend)
    wanted = None
    listed = os.environ.get("ENACT_FOOTPRINT_TARGETS")
    if listed:
        with open(listed) as f:
            wanted = {line.strip().split("::")[0] for line in f if line.strip()}
    targets, opaque = {}, {}
    for index, result in enumerate(results, 1):
        spec, _, status = result.rpartition("=")
        if wanted is not None and spec not in wanted:
            continue
        fp = python.pop(spec, core.Footprint())
        if not fp.code and not fp.reads:
            fp.opaque.add("no app process recorded for it")
        fp.update(node_records(os.path.join(directory, "node", str(index))))
        map_built(fp, frontend)
        fp.reads.add(spec)
        target = entry(fp, shared)
        why = sorted(fp.opaque | shared.opaque)
        if why:
            opaque[spec] = why
        if status != "0":
            target["outcome"] = {"incomplete": {"exit": int(status) if status.lstrip("-").isdigit() else 1}}
        elif why:
            target["outcome"] = "partial"
        targets[spec] = target
    for token in python:
        print(f"live_footprint: records for {token!r}, no spec of this run", file=sys.stderr)
    if not targets:
        return
    os.makedirs(out_dir, exist_ok=True)
    shard = os.environ.get("ENACT_SHARD_INDEX", "1")
    out = os.path.join(out_dir, f"live-shard{shard}-{os.getpid()}.json")
    with open(out, "w") as f:
        json.dump(
            {
                "version": 1,
                "recorder": RECORDER,
                "outcomes": True,
                "shared": entry(shared),
                "targets": targets,
            },
            f,
            separators=(",", ":"),
        )
    with open(out[: -len(".json")] + ".stats", "w") as f:
        json.dump({"targets": len(targets), "opaque": opaque, "frontend_build": frontend.loaded}, f, indent=1)
    print(
        f"live_footprint: {len(targets)} spec files "
        f"({sum('incomplete' in target.get('outcome', '') for target in targets.values())} failed, "
        f"{sum(target.get('outcome') == 'partial' for target in targets.values())} partial), "
        f"{os.path.getsize(out) >> 10} KB -> {out}",
        file=sys.stderr,
    )
    for spec, why in opaque.items():
        print(f"  {spec}: {'; '.join(why)[:300]}", file=sys.stderr)


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "prepare":
        prepare(argv[1])
        return 0
    if len(argv) >= 2 and argv[0] == "write":
        write(argv[1], argv[2:])
        return 0
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
