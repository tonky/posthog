"""enact_footprint: what a Python test process uses of its repository, per test target, for an
enact reach map. The in-process recorders (posthog's pytest_footprint.py, odoo's
odoo-footprint.py) drive it; both overlays hold this same file (a test checks they match).

`sys.monitoring` reports the first call of each function while a target is current, then
disables it until the next `switch` (which restarts events). Each switch first checks that
the recorder's tools still hold their ids, callbacks and events (another tool may free, take
or silence them): a target whose code went unseen is opaque. The audit hook records the files
the process opens as data, the directories it lists, the paths it finds missing (probes) and
the programs it starts:

* Files read as data (b): every open but the import system's own read of a module's code,
  pytest's assertion rewriting and the library calls `UNRECORDED_CALLS` names (Hypothesis's
  constant mining). A `.py` file read as data (parsed, shown, globbed) joins
  its target whole, not through the functions it called.
* Listings (c): `os.listdir`, `os.scandir` (`glob`, `pathlib`, `os.walk`), `os.fwalk`, and a
  glob's missing literal prefix. The import system's own listings are left out: its lookups
  are recorded exactly instead, as probes of each candidate a lookup found missing before the
  one it took (`FileFinder.find_spec`), so a module added where an import looked selects the
  importer and one added elsewhere selects nobody.
* Probes: an open, `os.stat` or `os.lstat` (`os.path.exists`, `isfile`, `isdir`) of a missing
  path, and a file the standard library's presence predicates (`os.path.exists`, `isfile`,
  `isdir`, `islink`, pathlib's `exists`, `is_dir`, `is_file`…) found present: pytest's
  collection asks `is_dir()` of every sibling of a test's packages. Adding a
  missing path or deleting a present one reaches the prober, editing a present one doesn't.
  Any other `stat` of a file (`getmtime`, `getsize`, `os.stat`: Django's autoreload, linecache,
  pytest's `.pyc` check, a template loader's `uptodate`) may use its times or size, so the
  file is found: held whole, or by function when code of it ran. The import system's own
  `stat` (a module's mtime against its `.pyc`) calls `posix.stat` and isn't seen: the module
  then runs and is recorded by function and as `loaded`. Probes below a file or a missing
  directory are kept as that path (`collapse_probes`).
* What outlives a target (d, e): a module's import (its body, its class bodies, what they
  call) and a `functools.lru_cache`/`cache` computation run once and serve every later target
  of the process, so they run in a shared extent: a second monitoring tool records them into
  the shared footprint, which every target of the process holds, as it holds start-up.
  Adapters run their framework's caches the same way (`extent`).
* Child processes (a): a Python child loads this module in child mode (a `sitecustomize` on
  `PYTHONPATH`, which then runs the interpreter's own), records everything it runs for the
  target that started it, and leaves a record the parent merges: at exit, at an `exec`, or
  at SIGTERM (then it dies by the signal still); a parent ending one it just started
  waits until it records (`_patch_kill`). A forked child records likewise, and so do
  children started below `subprocess` (`_posixsubprocess.fork_exec`: multiprocessing's spawn
  and helpers, loky's workers). When recording ends, multiprocessing's children are ended
  and its helpers (resource trackers, a forkserver) stopped, and running children are
  waited for a while. A child that ran while the parent was on another target (a pool's
  worker a later target reused, a forkserver's child) records for every target: shared. A
  child the parent started that leaves no record (killed, still running when recording
  ends, `-I`/`-E`/`-S`, a scrubbed environment, an older Python) makes the targets it
  records for opaque. Other programs are modelled when they read no files (`true`,
  `echo`), only the files their arguments name (`cat`; `grep`, trees when it recurses),
  only git's own metadata (`git rev-parse`) or a repository apart from this one (git in a
  scratch work tree under /tmp), or nothing of the repository when no argument names a
  path in it: host facts (`lscpu`) and the programs the adapter names (`quiet`). git's
  queries of the repository's tree are modelled by their arguments (`_git_tree_query`):
  `ls-files` probes listed paths and models tree enumeration; `--others` reads
  the `.gitignore` files too, and `diff` against the work tree reads every tracked file.
  Any other git over the repository makes its target opaque (incomplete: it runs for any
  change): the tracer misses the `lstat`s git decides by. Any other program (`node`, a
  shell running more than pure programs) runs under enact's tracer on Linux (`enact trace
  exec`, started through `$ENACT_EXE` in its place): what its tree opens joins its target
  as a Python child's record does, shared when it ran into another target. Off Linux,
  without `$ENACT_EXE`, or started by `os.exec*` or `os.system`, it makes its target opaque.

Each footprint also lists the repository modules loaded (`loaded`): those in `sys.modules`
when its target last ended, start-up and the modules earlier targets imported included, and
those its Python children loaded. enact narrows a change outside a module's functions (its
body, a class body, a decorator, an import) to the targets that loaded it: a
target that ended before a module's first import never ran its body. Every loaded module is
among the footprint's files too, so a whole-file change reaches the same targets and more.

A target's own module (the test file a target is, or is in: `own_modules`) is a runner's
import, every collected file's before any test runs, so it isn't every later target's: it
belongs to its own targets and to those importing it (`narrow_own_modules`). Each import
statement is noted as an edge from the module whose body ran it, or from the target whose
code did (`import_edges`); a module whose importers lead to anything else (start-up, a
shared extent, another module, code outside the repository, a load no statement explains)
stays every target's, as do one read whole and one whose functions a shared extent ran.
"""

import _signal
import _thread
import contextlib
import contextvars
import os
import sys
import time

monitoring = sys.monitoring
PY_START = monitoring.events.PY_START
CO_NEWLOCALS = 0x0002  # inspect.CO_NEWLOCALS, without importing inspect into every child
SHARED = "<shared>"
# This recorder and the version of what it writes, in each map (`recorder`): a change to
# what it records bumps it, re-recording only its footprints (`analysis.recorders`).
RECORDER = "enact_footprint.py/7"
TARGETS_NAME = "enact-footprint"
SHARED_NAME = "enact-footprint-shared"

ENV_ROOT = "ENACT_FOOTPRINT_ROOT"
ENV_CHILDREN = "ENACT_FOOTPRINT_CHILDREN"
ENV_TARGET = "ENACT_FOOTPRINT_TARGET"
ENV_SPAWN = "ENACT_FOOTPRINT_SPAWN"
ENV_CORE = "ENACT_FOOTPRINT_CORE"
ENV_QUIET = "ENACT_FOOTPRINT_QUIET"
ENV_READERS = "ENACT_FOOTPRINT_READERS"
ENV_EXE = "ENACT_EXE"
ENV_OUTER_KERNEL_TRACE = "ENACT_OUTER_KERNEL_TRACE"

# Programs that read no files.
PURE = {"true", "false", "echo", "printf", "uname", "sleep", "hostname", "whoami", "id",
        "nproc", "getconf", "date", "exit", "test", "[", ":", "pwd", "kill", "lsb_release", "ip"}
# Programs that report on the host, reading nothing of the repository unless an argument
# names a path in it: CPU counts (loky's `lscpu --parse=core`, `sysctl -n hw.physicalcpu`).
HOST_FACTS = {"lscpu", "sysctl"}
# Programs that read only the files their arguments name.
READERS = {"cat", "head", "tail", "wc", "md5sum", "sha256sum", "file"}
# grep reads its file operands (none: its input), and the directories it names whole when it
# recurses (none: its working directory).
GREPS = {"grep", "egrep", "fgrep"}
GREP_VALUED = "efABCmdD"  # short options taking a value
GREP_VALUED_LONG = {"--regexp", "--file", "--after-context", "--before-context", "--context",
                    "--max-count", "--directories", "--devices", "--include", "--exclude",
                    "--exclude-dir", "--exclude-from", "--label", "--binary-files", "--group-separator"}
# Standard library modules that start programs for facts about the host (`ctypes.util`'s
# `find_library` runs gcc and ld, `platform.architecture` runs `file`): what they start reads
# nothing of the repository unless an argument names a path in it.
HOST_PROBES = (f"{os.sep}ctypes{os.sep}util.py", f"{os.sep}platform.py", f"{os.sep}uuid.py")
# Library functions whose opens and stats are no test's, by name: the file defining them.
# Hypothesis mines the constants of every first-party module it finds loaded (reads each
# source whole, resolves its path) to bias the inputs it generates, which are random anyway:
# in `lru_cache` computations, shared extents, so every footprint of the process held every
# loaded module whole, its functions lost. Matched by the caller's frames, as
# pytest's plugins load through its own importer, and an importer binds them as it imports.
_HYPOTHESIS_CONSTANTS = f"{os.sep}hypothesis{os.sep}internal{os.sep}constants_ast.py"
UNRECORDED_CALLS = {
    "constants_from_module": _HYPOTHESIS_CONSTANTS,
    "is_local_module_file": _HYPOTHESIS_CONSTANTS,
}
UNRECORDED_DEPTH = 12  # frames between such a call and the open or stat it makes
SHELLS = {"sh", "bash", "dash", "zsh"}
# git commands that read only git's metadata (`.git/`, never in a footprint).
GIT_METADATA = {"rev-parse", "describe", "symbolic-ref", "log", "show-ref", "--version", "version"}
# git's options before its command that take a value, and those (and variables) that move
# its repository or work tree.
GIT_VALUED = {"-c", "-C", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"}
GIT_RELOCATING = ("--git-dir", "--work-tree")
GIT_RELOCATING_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY")
# git's options before its command that change nothing of what a tree query reads.
GIT_HARMLESS = {"--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-P", "-c"}
# `git ls-files` options of a names-only listing: tracked (`-c`) or untracked (`-o`) files.
GIT_LS_FILES = {"-z", "-c", "--cached", "--full-name", "--deduplicate", "--error-unmatch", "-o", "--others",
                "--exclude-standard"}
# `git diff` options that change only how it reports the paths and contents it compares.
GIT_DIFF = {"--name-status", "--name-only", "--numstat", "--shortstat", "--summary", "-z", "--no-renames",
            "--quiet", "--exit-code", "-p", "--patch", "-u", "--no-color", "--no-ext-diff", "--no-textconv",
            "-w", "--ignore-all-space", "-b", "--ignore-space-change", "--minimal", "--full-index", "--binary",
            "--raw", "--stat", "-R", "--relative"}
GIT_DIFF_VALUED = ("--stat=", "-M", "--find-renames", "--diff-filter=", "--relative=", "-U", "--unified=",
                   "--ignore-submodules", "--abbrev", "--color=never", "--src-prefix=", "--dst-prefix=")


class Footprint:
    """What one target used: the functions it ran by file (none: code outside functions), the
    files it read as data, found present or probed, the directories it listed, the Python
    children it started (until their records are merged), and why it is opaque (empty: it
    isn't)."""

    __slots__ = ("code", "reads", "present", "probes", "dirs", "opaque", "spawned", "loaded", "recorders")
    SETS = ("reads", "present", "probes", "dirs", "opaque", "spawned", "loaded", "recorders")

    def __init__(self):
        self.code: dict[str, set[str]] = {}
        self.reads: set[str] = set()
        self.present: set[str] = set()
        self.probes: set[str] = set()
        self.dirs: set[str] = set()
        self.opaque: set[str] = set()
        self.spawned: set[str] = set()
        self.loaded: set[str] = set()  # modules its Python children loaded
        self.recorders: set[str] = set()  # actual native-child provenance, never inferred

    def copy(self) -> "Footprint":
        fp = Footprint()
        fp.code = {file: set(functions) for file, functions in self.code.items()}
        for name in self.SETS:
            setattr(fp, name, set(getattr(self, name)))
        return fp

    def update(self, other: "Footprint") -> None:
        for file, functions in other.code.items():
            self.code.setdefault(file, set()).update(functions)
        for name in self.SETS:
            getattr(self, name).update(getattr(other, name))

    def dump(self) -> dict:
        record = {name: sorted(getattr(self, name)) for name in self.SETS}
        record["code"] = {file: sorted(functions) for file, functions in self.code.items()}
        return record

    @classmethod
    def load(cls, record: dict, *, native: bool = False) -> "Footprint":
        fp = cls()
        for file, functions in record.get("code", {}).items():
            fp.code[file] = set(functions)
        for name in cls.SETS:
            getattr(fp, name).update(record.get(name, ()))
        if native and not any(name == "enact-trace" and version for name, _, version in
                              (recorder.rpartition("/") for recorder in fp.recorders)):
            fp.opaque.add("native child record lacks kernel recorder provenance")
        return fp

    def entry(self, through: int, at: dict[str, int], own=(), shared: "Footprint | None" = None) -> dict:
        """The footprint as an enact reach map target: `files` (found), `functions`, `dirs`,
        the modules it loaded, and `probes`, by directory (`_grouped`). The modules are the
        map's `load_order` up to `loaded_through` (`through`; `at`: each one's place in it),
        and in `loaded` the rest: `own`, and those its children loaded. Each target naming
        the prefix of one list, a map grows with its modules, not their square per target. A file it only found present whose code
        `shared` (the part enact lays over it) runs is held by function, as the two merged
        would be: enact keeps a file whole that either part holds whole."""
        found = set(self.code) | self.reads | self.present
        coded = set(self.code) | (self.present & set(shared.code) if shared else set())
        entry = {
            "files": sorted(found),
            "recorders": sorted(self.recorders | {RECORDER}),
            "functions": {
                file: sorted(self.code.get(file, ()))
                for file in sorted(coded)
                if file.endswith(".py") and file not in self.reads
            },
        }
        entry["loaded_through"] = through
        rest = sorted(rel for rel in self.loaded.union(own) if at.get(rel, through) >= through)
        if rest:
            entry["loaded"] = rest
        probes = self.probes - found
        if probes:
            entry["probes"] = _grouped(probes)
        if self.dirs:
            entry["dirs"] = sorted(f"dir:{d}" for d in self.dirs)
        return entry

    def collapse_probes(self, kinds: dict[str, str | None]) -> None:
        """Keeps one path for the probes below a path that isn't a directory:
        an import system's lookups probe every candidate under every path entry, and some
        libraries look for files under each path they're given. A probe `X/…` below a file X
        can only be found once X turns into a directory, which deletes X: X stays, a probe of
        its presence. One below a missing directory D can only be found once
        something is added at or below D, which reaches whoever probed D: D stays, for all
        of them. `kinds` caches each path's kind."""
        kept = set()
        for probe in self.probes:
            parts = probe.split("/")
            keep = probe
            for end in range(1, len(parts)):
                prefix = "/".join(parts[:end])
                kind = kinds[prefix] if prefix in kinds else kinds.setdefault(prefix, _kind_of(prefix))
                if kind == "dir":
                    continue
                if kind in ("file", "missing"):
                    keep = prefix
                break  # anything else (unreadable, a socket): the probe as it is
            if keep is not None:
                kept.add(keep)
        self.probes = kept


def _kind_of(rel: str) -> str | None:
    """What the repository holds at `rel`: "dir", "file", "missing", or None (another kind,
    or it can't tell)."""
    try:
        mode = _real_stat(root + rel).st_mode & 0o170000
    except FileNotFoundError:
        return "missing"
    except OSError:
        return None
    return {0o040000: "dir", 0o100000: "file"}.get(mode)


def _grouped(paths) -> list:
    """`paths` as enact reads probes compactly: `[[directories, names], …]`, each directory
    probed for each name of its group, the directories probed for the same names together."""
    by_dir: dict[str, set[str]] = {}
    for path in paths:
        directory, _, name = path.rpartition("/")
        by_dir.setdefault(directory, set()).add(name)
    groups: dict[frozenset, list[str]] = {}
    for directory, names in by_dir.items():
        groups.setdefault(frozenset(names), []).append(directory)
    return sorted([sorted(dirs), sorted(names)] for names, dirs in groups.items())


# --- state -------------------------------------------------------------------------------

TARGETS_TOOL = monitoring.PROFILER_ID
SHARED_TOOL = 4  # an unnamed id; `start` takes a free one
root = ""  # the repository, with a trailing separator
own: tuple[str, ...] = ()  # the recorders' own files and directories
quiet: set[str] = set()
# Programs that read the files and directories (whole, recursively) their arguments name, and
# these paths relative to their working directory (the adapter's `tree_readers`).
tree_readers: dict[str, tuple[str, ...]] = {}
unlisted: tuple[str, ...] = ()  # callers whose listings aren't recorded (`start`)
child = False  # recording a child process for the target that started it
footprints: dict[str, Footprint] = {SHARED: Footprint()}
shared = footprints[SHARED]
current: Footprint | None = None  # the target recording (the targets tool's sink)
current_key: str | None = None
_ctx_target: contextvars.ContextVar[str | None] = contextvars.ContextVar("enact_footprint_target", default=None)
depth = 0  # nesting of shared extents, every thread's
children_dir = ""
child_stem = ""
# When the parent made each target current (`time.monotonic`, the host's clock: children's
# start and end times compare with it), for the targets a child ran into (`_served`).
switched_at: list[float] = []
switched_to: list[str | None] = []
# How long recording's end waits for children still running to leave their record.
CHILD_WAIT = 5.0
# How long ending a Python child waits for its recording to start (`_patch_kill`).
CHILD_START_WAIT = 5.0
# The Python children started whose recording may not have started yet (`_patch_kill`).
_unstarted: set[int] = set()
stats: dict[str, int] = {}
# `busy`: inside the recorder, whose own calls aren't recorded; `python`: the start being
# classified is a Python child's.
local = _thread._local()
_rel_cache: dict[str, str | None] = {}
tracer = ""  # `enact trace exec`'s enact ($ENACT_EXE) on Linux: what runs a program unmodelled
outer_kernel_trace = False  # outer kernel tracer supervises subprocess file/dir/probe opens
_popen_pending = False  # `subprocess` not imported yet: Popen is patched once it is
# The repository modules the process loaded, in order, and where each target last ended in
# that order (`loaded_marks`): a target's modules are those loaded before its mark.
loaded_order: list[str] = []
loaded_seen: set[str] = set()
loaded_marks: dict[str, int] = {}
# Targets' own modules (the adapter's: each collected test file), who imported each repository
# module (`(importer, module)`: a module whose body ran the statement, `KEY` + the target whose
# code did, or `EXTERNAL`/SHARED), and the target current at each module's first load.
own_modules: set[str] = set()
import_edges: set[tuple[str, str]] = set()
_imports_seen: set = set()
first_loaded_by: dict[str, str | None] = {}
KEY = "key:"
EXTERNAL = "<external>"
_modules_seen = None  # `sys.modules`' size and last key when last scanned
child_from = 0  # in a child, the modules loaded before it (a forked child's parent's)
_writing = False  # writing this child's record (`write_child`)
_signalled = 0  # a SIGTERM that came while writing it, delivered once it is written
_real_stat = os.stat
_real_lstat = os.lstat
_real_exit = os._exit


def count(name: str, n: int = 1) -> None:
    stats[name] = stats.get(name, 0) + n


def active_target_key() -> str | None:
    """The target active in the current context (`request_target`), process (`switch`), or env."""
    ctx_key = _ctx_target.get()
    if ctx_key is not None and ctx_key != SHARED:
        return ctx_key
    if current_key is not None and current_key != SHARED:
        return current_key
    env_target = os.environ.get("ENACT_TRACE_TARGET") or os.environ.get(ENV_TARGET)
    return env_target if env_target and env_target != SHARED else None


@contextlib.contextmanager
def request_target(key: str | None):
    """Scopes all function calls, file opens, stats, and outbound HTTP calls in the current
    thread or async task (`contextvars.ContextVar`) to `key`'s footprint."""
    if not key:
        yield
        return
    footprints.setdefault(key, Footprint())
    token = _ctx_target.set(key)
    try:
        yield
    finally:
        _ctx_target.reset(token)
        _mark_loaded(key)


def sink() -> Footprint | None:
    """Where a file the process uses now is recorded: shared inside an extent."""
    if depth > 0:
        return shared
    ctx_key = _ctx_target.get()
    if ctx_key is not None:
        return footprints.setdefault(ctx_key, Footprint())
    return current


def relative(path) -> str | None:
    """`path` from the repository root ("" for the root): None outside it, in a dot
    directory or a `__pycache__`, or one of the recorders' own files."""
    if isinstance(path, os.PathLike):
        path = os.fspath(path)
    if isinstance(path, bytes):
        try:
            path = os.fsdecode(path)
        except (TypeError, ValueError):
            return None
    if not isinstance(path, str) or not path or path.startswith("<"):
        return None
    cached = _rel_cache.get(path, False)
    if cached is not False:
        return cached
    if not os.path.isabs(path):
        try:
            return relative(os.path.join(os.getcwd(), path))
        except OSError:
            return None
    busy = getattr(local, "busy", False)
    local.busy = True
    try:
        real = os.path.realpath(path)
    finally:
        local.busy = busy
    rel = None
    if (real + os.sep).startswith(root) and not real.startswith(own):
        rel = real[len(root):]
        if rel.startswith(".") or "/." in rel or "__pycache__" in rel:
            rel = None  # dot directories and bytecode caches: not the repository's
    _rel_cache[path] = rel
    return rel


def function_of(code) -> str | None:
    """The function `code` is, or is in: None for code outside functions."""
    if not code.co_flags & CO_NEWLOCALS:
        return None  # a module or class body
    name = code.co_qualname.split(".<locals>", 1)[0]
    return None if "<" in name else name


def _ran(fp: Footprint, code) -> None:
    path = relative(code.co_filename)
    if path is not None:
        function = function_of(code)
        called = fp.code.get(path)
        if called is None:
            called = fp.code.setdefault(path, set())
        if function:
            called.add(function)


def on_start(code, _offset):
    ctx_key = _ctx_target.get()
    if ctx_key is not None:
        _ran(footprints.setdefault(ctx_key, Footprint()), code)
        return None
    fp = current
    if fp is not None:
        _ran(fp, code)
    return monitoring.DISABLE


def on_shared_start(code, _offset):
    _ran(shared, code)
    return monitoring.DISABLE


def _kind(path: str) -> str | None:
    """"dir", "file", or None (missing), by the real `stat`."""
    import stat as st

    try:
        mode = _real_stat(path).st_mode
    except (OSError, ValueError):
        return None
    return "dir" if st.S_ISDIR(mode) else "file"


def _absolute(path) -> str | None:
    if isinstance(path, int):
        return _fd_path(path)
    if path is None:
        path = "."
    try:
        path = os.fsdecode(os.fspath(path))
    except (TypeError, ValueError):
        return None
    if os.path.isabs(path):
        return path
    try:
        return os.path.join(os.getcwd(), path)
    except OSError:
        return None


def _fd_path(fd: int) -> str | None:
    try:
        return os.readlink(f"/proc/self/fd/{fd}")
    except OSError:
        pass
    try:
        import fcntl

        return fcntl.fcntl(fd, fcntl.F_GETPATH, b"\0" * 1024).rstrip(b"\0").decode()
    except (ImportError, AttributeError, OSError, ValueError):
        return None


def note(path, kind: str | None = None, fp: Footprint | None = None) -> None:
    """Records `path`: a listing if it's a directory, a read if a file, a probe if missing."""
    fp = fp or sink()
    if fp is None:
        return
    absolute = _absolute(path)
    rel = relative(absolute) if absolute else None
    if rel is None:
        return
    kind = kind or _kind(absolute)
    if kind == "dir":
        fp.dirs.add(rel)
    elif kind == "file":
        fp.reads.add(rel)
    elif rel:
        fp.probes.add(rel)


# --- loaded modules ----------------------------------------------------------------------

def _module_file(module) -> str | None:
    """The file `module` was loaded from, read without running a lazy module's loader."""
    try:
        namespace = object.__getattribute__(module, "__dict__")
        path = namespace.get("__file__")
    except Exception:
        return None
    return path if isinstance(path, str) else None


def note_module(module) -> str | None:
    """`module` is loaded: its repository file joins every target ending from now on."""
    path = _module_file(module)
    if path is None:
        return None
    busy = getattr(local, "busy", False)
    local.busy = True
    try:
        rel = relative(path)
    finally:
        local.busy = busy
    if rel and rel not in loaded_seen:
        loaded_seen.add(rel)
        loaded_order.append(rel)
    return rel


def scan_modules() -> None:
    """Notes the modules of `sys.modules` (those no loader this module wraps ran: extension
    modules, a test runner's own loader, start-up before recording), when it grew since the
    last scan: a module added since is its last key, or makes it longer."""
    global _modules_seen
    modules = sys.modules
    try:
        seen = (len(modules), next(reversed(modules)))
    except (StopIteration, RuntimeError):
        seen = None
    if seen is not None and seen == _modules_seen:
        return
    _modules_seen = seen
    for module in list(modules.values()):
        note_module(module)


def _mark_loaded(key: str | None) -> None:
    """Target `key` ends (for now): it holds the modules loaded so far."""
    if key is None or key == SHARED or child:
        return
    scan_modules()
    loaded_marks[key] = len(loaded_order)


def noting(exec_module):
    """A loader's `exec_module` noting each module, and the target current at its first
    load, before its body runs."""
    import functools

    @functools.wraps(exec_module)
    def exec_module_noting(self, module):
        rel = note_module(module)
        if rel and not child:
            first_loaded_by.setdefault(rel, current_key)
        result = exec_module(self, module)
        if _popen_pending and getattr(module, "__name__", None) == "subprocess":
            _patch_popen_in(module)
        return result

    return exec_module_noting


def _unrecorded(frame) -> bool:
    """Whether `frame` runs in one of `UNRECORDED_CALLS`, or below it."""
    for _ in range(UNRECORDED_DEPTH):
        if frame is None:
            return False
        code = frame.f_code
        defined_in = UNRECORDED_CALLS.get(code.co_name)
        if defined_in is not None and code.co_filename.endswith(defined_in):
            return True
        frame = frame.f_back
    return False


# --- the audit hook ----------------------------------------------------------------------

def _caller():
    """The code that made the audited call."""
    frame = sys._getframe(3)  # _caller, the handler, on_audit
    return frame.f_code if frame is not None else None


def _opened_by_import() -> bool:
    """Whether the open being audited is the import system reading a module's code."""
    frame = sys._getframe(3)
    for _ in range(4):
        if frame is None:
            return False
        code = frame.f_code
        if code.co_name == "get_code" and code.co_filename.startswith("<frozen importlib"):
            return True
        if code.co_name == "_rewrite_test" and code.co_filename.endswith("rewrite.py"):
            return True
        frame = frame.f_back
    return False


STDLIB = os.path.dirname(os.__file__) + os.sep


def _listed_by_unlisted() -> bool:
    """Whether the first caller outside the standard library (`glob`, `pathlib`, `os.walk`
    list for their callers) is one of `unlisted`."""
    frame = sys._getframe(3)
    while frame is not None:
        name = frame.f_code.co_filename
        if any(fragment in name for fragment in unlisted):
            return True
        if not name.startswith((STDLIB, "<frozen")) or "-packages" in name:
            return False
        frame = frame.f_back
    return False


def _audit_open(args) -> None:
    path, mode, flags = (tuple(args) + (None, None, None))[:3]
    if isinstance(path, int) or path is None:
        return
    if isinstance(mode, str):
        if "r" not in mode and "+" not in mode:
            return  # written, not read
    elif isinstance(flags, int) and flags & (os.O_WRONLY | os.O_RDWR) == os.O_WRONLY:
        return
    try:
        name = os.fsdecode(os.fspath(path))
    except (TypeError, ValueError):
        return
    if name.endswith(".pyc"):
        return
    if name.endswith(".py") and _opened_by_import():
        return
    absolute = _absolute(name)
    if absolute is None or relative(absolute) is None or _unrecorded(sys._getframe(2)):
        return
    kind = _kind(absolute)
    if kind == "file" and name.endswith(".py"):
        count("source_reads")
    note(absolute, kind)


def _audit_listing(args) -> None:
    caller = _caller()
    if caller is not None:
        if caller.co_name == "_fill_cache" and caller.co_filename.startswith("<frozen importlib"):
            return  # the import system: its lookups are probes (find_spec)
        if unlisted and _listed_by_unlisted():
            return  # the adapter's: a test runner's collection walk (`unlisted_callers`)
    absolute = _absolute(args[0] if args else None)
    if absolute is not None and relative(absolute) is not None:
        count("listings")
        note(absolute)


def _audit_glob(args) -> None:
    pattern, _recursive, root_dir = (tuple(args) + (None, None, None))[:3]
    try:
        pattern = os.fsdecode(pattern)
    except (TypeError, ValueError):
        return
    parts = pattern.split("/")
    literal = []
    for part in parts:
        if any(ch in part for ch in "*?["):
            break
        literal.append(part)
    if len(literal) == len(parts):
        return  # no magic: glob checks the path itself (a stat, a probe if missing)
    base = "/".join(literal) or ("/" if pattern.startswith("/") else ".")
    if not os.path.isabs(base) and root_dir is not None:
        base = os.path.join(os.fsdecode(root_dir), base)
    absolute = _absolute(base)
    if absolute and _kind(absolute) is None:
        note(absolute, "missing")  # answered by any file added below it


def _audit_fwalk(args) -> None:
    if args and not isinstance(args[0], int):
        absolute = _absolute(args[0])
        if absolute is not None and relative(absolute) is not None:
            note(absolute)


def _audit_popen(args) -> None:
    executable, argv, cwd, env = (tuple(args) + (None, None, None, None))[:4]
    if isinstance(argv, (str, bytes, os.PathLike)):
        argv = [argv]
    spawn(executable, list(argv or []), env, cwd)


def _audit_system(args) -> None:
    command = args[0] if args else ""
    if isinstance(command, bytes):
        command = os.fsdecode(command)
    spawn("/bin/sh", ["/bin/sh", "-c", command], None)


def _audit_posix_spawn(args) -> None:
    caller = _caller()
    if caller is not None and caller.co_name == "_posix_spawn" and caller.co_filename.endswith("subprocess.py"):
        return  # subprocess.Popen's, classified by `_patch_popen`
    path, argv, env = (tuple(args) + (None, None, None))[:3]
    spawn(path, list(argv or []), env)


def _audit_exec(args) -> None:
    path, argv, env = (tuple(args) + (None, None, None))[:3]
    spawn(path, list(argv or []), env)
    if child:
        write_child()  # this image ends here; the next one leaves its own record


# `os.spawn*` and `pty.spawn` fork and exec: the forked child classifies its `os.exec`.
AUDITED = {
    "open": _audit_open,
    "os.listdir": _audit_listing,
    "os.scandir": _audit_listing,
    "os.fwalk": _audit_fwalk,
    "glob.glob/2": _audit_glob,
    "subprocess.Popen": _audit_popen,
    "os.system": _audit_system,
    "os.posix_spawn": _audit_posix_spawn,
    "os.exec": _audit_exec,
}


def on_audit(event, args):
    handler = AUDITED.get(event)
    if handler is None or sink() is None or getattr(local, "busy", False):
        return
    local.busy = True
    try:
        handler(args)
    except Exception as e:  # never break the code under test
        count(f"audit_error:{event}:{type(e).__name__}")
    finally:
        local.busy = False


# --- child processes ---------------------------------------------------------------------

def _which(program: str) -> str:
    if "/" in program:
        return program
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(directory, program)
        if os.access(candidate, os.X_OK) and _kind(candidate) == "file":
            return candidate
    return program


def _is_python(path: str) -> bool:
    import re

    if re.fullmatch(r"python(\d+(\.\d+)*t?)?", os.path.basename(path)):
        return True
    try:
        if os.path.realpath(path) == os.path.realpath(sys.executable):
            return True
        with open(path, "rb") as f:
            first = f.readline(256)
    except OSError:
        return False
    return first.startswith(b"#!") and b"python" in first


def _shell_is_pure(command: str) -> bool:
    """Whether a `sh -c` command runs only programs that read no files."""
    import shlex

    if any(ch in command for ch in "$`<()\\\n"):
        return False
    try:
        tokens = list(shlex.shlex(command, posix=True, punctuation_chars=True))
    except ValueError:
        return False
    first = True
    for token in tokens:
        if token in ("|", "||", "&&", ";", "&", ">", ">>", "2>", "2>&1"):
            first = True
            continue
        if first and token not in PURE:
            return False
        first = False
    return True


def _in(cwd, path: str) -> str:
    return path if cwd is None or os.path.isabs(path) else os.path.join(os.fsdecode(os.fspath(cwd)), path)


def _repo_paths(argv: list, cwd=None) -> list[str]:
    """The arguments naming an existing path in the repository (`--opt=path` included)."""
    named = []
    for arg in argv[1:]:
        if not isinstance(arg, (str, bytes, os.PathLike)):
            continue
        arg = os.fsdecode(os.fspath(arg))
        for value in (arg, arg.split("=", 1)[-1]):
            if not value or value.startswith("-"):
                continue
            absolute = _absolute(_in(cwd, value))
            if absolute and relative(absolute) is not None and _kind(absolute):
                named.append(absolute)
                break
    return named


def _grep_files(words: list[str]) -> tuple[list[str], bool]:
    """grep's file operands, and whether it recurses (`-r`, `-R`, `-d recurse`)."""
    files: list[str] = []
    patterned = recursive = False
    i = 0
    while i < len(words):
        word, i = words[i], i + 1
        if word == "--":
            files += words[i:]
            break
        if word.startswith("--"):
            name, eq, value = word.partition("=")
            if name in GREP_VALUED_LONG and not eq:
                value, i = (words[i] if i < len(words) else ""), i + 1
            patterned |= name in ("--regexp", "--file")
            recursive |= name in ("--recursive", "--dereference-recursive") or (name, value) == ("--directories", "recurse")
        elif word.startswith("-") and word != "-":
            for at, flag in enumerate(word[1:], 2):
                recursive |= flag in "rR"
                if flag in GREP_VALUED:
                    value = word[at:]
                    if not value:
                        value, i = (words[i] if i < len(words) else ""), i + 1
                    patterned |= flag in "ef"
                    recursive |= (flag, value) == ("d", "recurse")
                    break
        else:
            files.append(word)
    return (files if patterned else files[1:]), recursive


def _grep_reads(words: list[str], cwd, fp: Footprint) -> None:
    files, recursive = _grep_files(words)
    for name in files or (["."] if recursive else []):
        absolute = _absolute(_in(cwd, name))
        if absolute and relative(absolute) is not None:
            if recursive:
                _read_tree(absolute, fp)
            else:
                note(absolute, fp=fp)


def _apart(path: str) -> bool:
    """Whether `path` is neither in the repository (dot directories included) nor above it."""
    real = os.path.realpath(path) + os.sep
    return not real.startswith(root) and not root.startswith(real)


def _git_reads_nothing(argv: list, words: list[str], cwd, env) -> bool:
    """Whether git reads only its metadata (`GIT_METADATA`), or works in a repository and work
    tree apart from this one (a scratch clone under /tmp) naming nothing of it."""
    command, work, relocated = None, _absolute(cwd), False
    i = 0
    while i < len(words):
        word, i = words[i], i + 1
        if not word.startswith("-") or word == "--version":
            command = word
            break
        name, eq, value = word.partition("=")
        if name in GIT_VALUED and not eq:
            value, i = (words[i] if i < len(words) else ""), i + 1
        relocated |= name in GIT_RELOCATING
        if name == "-C" and work:
            work = os.path.join(work, value)
    if command in GIT_METADATA:
        return True
    environment = os.environ if env is None else env
    relocated |= any(environment.get(name) for name in GIT_RELOCATING_ENV)
    named = any(root.rstrip(os.sep) in word for word in words) or _repo_paths(argv, cwd)
    return bool(work) and _apart(work) and not relocated and not named


def _read_tree(path: str, fp: Footprint) -> None:
    """`path` read whole: a file, or a directory's listing and everything below it."""
    note(path, fp=fp)
    if _kind(path) != "dir":
        return
    for directory, subdirs, files in os.walk(path):
        subdirs[:] = [d for d in subdirs if relative(os.path.join(directory, d)) is not None]
        for name in subdirs + files:
            note(os.path.join(directory, name), fp=fp)


def _started_for_host_facts() -> bool:
    """Whether a standard library host probe ([`HOST_PROBES`]) starts this process."""
    frame = sys._getframe(2)
    while frame is not None:
        name = frame.f_code.co_filename
        if name.startswith(STDLIB) and name.endswith(HOST_PROBES):
            return True
        frame = frame.f_back
    return False


def spawn(program, argv: list, env, cwd=None, traceable=False):
    """A process is starting: a Python child is told which target it records for; any other
    program is modelled (reads nothing, reads its arguments, git's tree queries) or else
    makes its target opaque. With `traceable` (a start this module can rewrite), an
    unmodelled program it can trace ([`tracer`]) returns `(target, why)` instead: the caller
    starts it under the tracer (`_traced`), or makes the target opaque for `why`."""
    fp = sink()
    if fp is None:
        return None
    key = SHARED if depth > 0 else current_key
    argv = [os.fsdecode(a) if isinstance(a, (bytes, os.PathLike)) else a for a in argv]
    if isinstance(program, (bytes, os.PathLike)):
        program = os.fsdecode(os.fspath(program))
    path = _which(str(program or (argv[0] if argv else "")))
    name = os.path.basename(path)
    count(f"spawn:{name}")
    if _kind(_absolute(_in(cwd, path)) or path) == "file":
        note(_in(cwd, path), fp=fp)  # a program of the repository's own: what it runs is read
    if _is_python(path):
        _propagate(fp, env, key)
        return None
    if outer_kernel_trace:
        count("kernel_delegated_spawns")
        return None
    words = [a for a in argv[1:] if isinstance(a, str)]
    why = f"{name}: {' '.join(map(str, argv))[:160]}"
    if name in SHELLS and len(words) >= 2 and words[0] == "-c":
        if _shell_is_pure(words[1]):
            return None
        why = f"shell: {words[1][:160]}"
    elif name in PURE:
        return None
    elif name in READERS:
        for absolute in _repo_paths(argv, cwd):
            note(absolute, fp=fp)
        return None
    elif name in GREPS:
        _grep_reads(words, cwd, fp)
        return None
    elif name in tree_readers:
        for absolute in _repo_paths(argv, cwd):
            _read_tree(absolute, fp)
        for path in tree_readers[name]:
            _read_tree(_absolute(_in(cwd, path)) or path, fp)
        return None
    elif name == "git":
        # Never traced: what git reads of the work tree is decided by `lstat`s the tracer
        # doesn't see (its index's stat cache).
        if not (_git_reads_nothing(argv, words, cwd, env) or _git_tree_query(path, words, cwd, env, fp)):
            opaque(fp, why)
        return None
    elif (name in quiet or name in HOST_FACTS or _started_for_host_facts()) and not _repo_paths(argv, cwd):
        return None
    if traceable and tracer:
        return key, why
    opaque(fp, why)
    return None


# --- programs run under enact's tracer ----------------------------------------------------

def _executable(program: str, env, cwd) -> str | None:
    """`program` as `exec` finds it: a path (relative to `cwd`), or its first match on the
    `PATH` it starts with. None when nothing runs by that name (its start then fails as
    usual, untraced)."""
    if "/" in program:
        candidate = _absolute(_in(cwd, program))
        return program if candidate and os.access(candidate, os.X_OK) and _kind(candidate) == "file" else None
    environment = os.environ if env is None else env
    for directory in os.get_exec_path(environment):
        candidate = os.path.join(directory, program)
        absolute = _absolute(_in(cwd, candidate))
        if absolute and os.access(absolute, os.X_OK) and _kind(absolute) == "file":
            return candidate
    return None


def _traced(program, argv: list, env, cwd, why: str):
    """The argv that runs `program` (as `argv`) under the tracer, writing its record in the
    children's directory, and that record's id; None when it can't (no such program)."""
    executable = _executable(os.fsdecode(program), env, cwd)
    if executable is None:
        return None
    record = os.urandom(6).hex()
    out = os.path.join(children_dir, "records", f"x{record}.json")
    argv0 = os.fsdecode(argv[0]) if argv else executable
    traced = [tracer, "trace", "exec", "--out", out, "--root", root.rstrip(os.sep), "--argv0", argv0, "--",
              executable] + [os.fsdecode(a) if isinstance(a, (bytes, os.PathLike)) else a for a in argv[1:]]
    count("traced_spawns")
    return traced, record


def _traced_started(pid: int, record: str, key: str, start: float, why: str) -> None:
    """The tracer runs as `pid`: its record, once written, joins `key` (`merge_children`)."""
    name = why.partition(":")[0]
    path = os.path.join(children_dir, "records", f"{pid}-x{record}.started")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        os.write(fd, f"{key}\nexec:{name}\n{start!r}".encode())
        os.close(fd)
    except OSError:
        count("traced_unregistered")


def _rewrite_start(program, argv: list, env, cwd):
    """Classifies a start this module can rewrite: None to start it as asked, or the traced
    argv to start instead, its record's id, target and start time."""
    decision = spawn(program, argv, env, cwd, traceable=True)
    if decision is None:
        return None
    key, why = decision
    traced = _traced(program or (argv[0] if argv else ""), argv, env, cwd, why)
    if traced is None:
        opaque(sink() or shared, why)
        return None
    return traced[0], traced[1], key, time.monotonic(), why


# --- git's queries of the repository's tree ----------------------------------------------

def _git_command(words: list[str], cwd):
    """git's command, its arguments and the directory it works in; None when an option before
    the command moves its repository or does what no model here covers."""
    work = _absolute(cwd)
    i = 0
    while i < len(words):
        word, i = words[i], i + 1
        if not word.startswith("-"):
            return word, words[i:], work
        name, eq, value = word.partition("=")
        if name in GIT_VALUED and not eq:
            value, i = (words[i] if i < len(words) else ""), i + 1
        if name == "-C" and work:
            work = os.path.join(work, value)
        elif name not in GIT_HARMLESS:
            return None
    return None


def _repo_dir(path: str) -> str | None:
    """The directory `path` from the repository root ("" for the root), dot directories
    included (git lists `.github/`); None outside it."""
    real = os.path.realpath(path)
    if real + os.sep == root:
        return ""
    return real[len(root):] if real.startswith(root) else None


def _git_list(git: str, work: str, args: list[str]) -> list[str] | None:
    """The paths `git <args>` (a `-z` listing) prints in `work`, relative to it."""
    import subprocess

    try:
        out = subprocess.run([git, *args], cwd=work, capture_output=True, timeout=120,
                             env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return [os.fsdecode(p) for p in out.stdout.split(b"\0") if p]


def _git_tree_query(git: str, words: list[str], cwd, env, fp: Footprint) -> bool:
    """Records what git's query of the repository's tree depends on, when it is one this
    models (`ls-files`, `diff` against the work tree): whether it was."""
    environment = os.environ if env is None else env
    if any(environment.get(name) for name in GIT_RELOCATING_ENV):
        return False
    parsed = _git_command(words, cwd)
    if parsed is None or parsed[2] is None:
        return False
    command, args, work = parsed
    if _repo_dir(work) is None:
        return False
    if command == "ls-files":
        return _git_ls_files(git, args, work, fp)
    if command == "diff":
        return _git_diff(git, args, work, fp)
    return False


def _git_ls_files(git: str, args: list[str], work: str, fp: Footprint) -> bool:
    """A names-only `ls-files`: tracked files (`-c`, the default) and untracked ones git
    doesn't ignore (`-o --exclude-standard`). It probes each listed path and records
    the query's tree enumeration separately from directory presence."""
    specs, flags = _git_operands(args)
    if specs is None or not flags <= GIT_LS_FILES:
        return False
    others = bool(flags & {"-o", "--others"})
    if others and "--exclude-standard" not in flags:
        return False  # ignored files too: every file under the tree
    tracked = _git_list(git, work, ["ls-files", "-z", "--", *specs])
    untracked = _git_list(git, work, ["ls-files", "-z", "--others", "--exclude-standard", "--", *specs]) \
        if others else []
    if tracked is None or untracked is None:
        return False
    listed = untracked + (tracked if flags & {"-c", "--cached"} or not others else [])
    _note_tree(work, tracked + untracked, listed, specs, fp, read=False, ignores=others)
    count("git_listings")
    return True


def _git_diff(git: str, args: list[str], work: str, fp: Footprint) -> bool:
    """`diff` against the work tree (none or one revision) reads every tracked file under its
    pathspecs, and probes their directories (a file added to the index shows up). Between
    commits (a range, two revisions) it reads only git's objects."""
    revisions, specs, dashed = [], [], False
    for word in args:
        if dashed:
            specs.append(word)
        elif word == "--":
            dashed = True
        elif word.startswith("-"):
            if word not in GIT_DIFF and not word.startswith(GIT_DIFF_VALUED):
                return False
        elif os.path.lexists(os.path.join(work, word)):
            specs.append(word)
        else:
            revisions.append(word)
    if len(revisions) >= 2 or any(".." in revision for revision in revisions):
        return True
    if any(spec.startswith(":") for spec in specs):
        return False
    tracked = _git_list(git, work, ["ls-files", "-z", "--", *specs])
    if tracked is None:
        return False
    _note_tree(work, tracked, tracked, specs, fp, read=True, ignores=False)
    count("git_diffs")
    return True


def _git_operands(args: list[str]):
    """An `ls-files`'s pathspecs and options; (None, …) for a pathspec magic (`:(glob)`)."""
    specs, flags, dashed = [], set(), False
    for word in args:
        if dashed or not word.startswith("-"):
            specs.append(word)
        elif word == "--":
            dashed = True
        else:
            flags.add(word)
    if any(spec.startswith(":") for spec in specs):
        return None, flags
    return specs, flags


def _note_tree(work: str, found: list[str], listed: list[str], specs: list[str], fp: Footprint,
               read: bool, ignores: bool) -> None:
    """A git query in `work` over `found` (paths relative to it): reads (`read`) or probes
    of the `listed` ones, and enumeration of the queried tree's directories. Presence
    alone cannot represent a new name in an existing directory. With `ignores`, each
    such directory's `.gitignore` is an input too."""
    base = _repo_dir(work)
    if base is None:
        return
    prefix = f"{base}/" if base else ""
    output = set(listed)
    dirs: set[str] = set()
    for path in found:
        rel = os.path.normpath(prefix + path)
        if rel.startswith("..") or rel == ".git" or rel.startswith(".git/"):
            continue
        (fp.reads if read and path in output else fp.probes).add(rel)
        while "/" in rel:
            rel = rel.rpartition("/")[0]
            if rel in dirs:
                break
            dirs.add(rel)
    for spec in specs or ["."]:
        literal = []
        for part in spec.split("/"):
            if any(ch in part for ch in "*?["):
                break
            literal.append(part)
        scope = _repo_dir(os.path.join(work, *literal)) if literal else base
        if scope is not None:
            fp.dirs.add(scope)
    fp.dirs.update(dirs)
    if ignores:
        for directory in dirs | {""}:
            ignore = f"{directory}/.gitignore" if directory else ".gitignore"
            if _kind(root + ignore) == "file":
                fp.reads.add(ignore)


def _propagate(fp: Footprint, env, key: str | None) -> None:
    """Tells a Python child its target, and expects its record (`merge_children`)."""
    spawn_id = os.urandom(6).hex()
    fp.spawned.add(spawn_id)
    local.python = True  # the start being classified (`_python_started`)
    os.environ[ENV_TARGET] = key or ""
    os.environ[ENV_SPAWN] = spawn_id
    if env is None or env is os.environ:
        return
    try:
        env[ENV_ROOT] = root
        env[ENV_CHILDREN] = children_dir
        env[ENV_TARGET] = key or ""
        env[ENV_SPAWN] = spawn_id
        env[ENV_CORE] = os.environ.get(ENV_CORE, "")
        env[ENV_QUIET] = os.environ.get(ENV_QUIET, "")
        env[ENV_READERS] = os.environ.get(ENV_READERS, "")
        if outer_kernel_trace:
            env[ENV_OUTER_KERNEL_TRACE] = "1"
        boot = os.path.join(children_dir, "boot")
        pythonpath = env.get("PYTHONPATH", "")
        if boot not in pythonpath.split(os.pathsep):
            env["PYTHONPATH"] = boot + (os.pathsep + pythonpath if pythonpath else "")
    except Exception:
        count("env_not_propagated")  # the child leaves no record: its target turns opaque


def opaque(fp: Footprint, why: str) -> None:
    fp.opaque.add(why)
    count("opaque_spawns")


BOOT = '''\
# Written by enact_footprint: records this Python process for the test that started it.
import importlib.util as _u, os as _os, sys as _sys
_boot = _os.path.dirname(_os.path.abspath(__file__))
try:
    _core = _os.environ.get("ENACT_FOOTPRINT_CORE")
    if _core and "enact_footprint" not in _sys.modules:
        _spec = _u.spec_from_file_location("enact_footprint", _core)
        _mod = _u.module_from_spec(_spec)
        _sys.modules["enact_footprint"] = _mod
        _spec.loader.exec_module(_mod)
        _mod.start_child()
finally:
    # The interpreter's own sitecustomize, if any (nixpkgs ships one; a virtualenv's has
    # none). The name stays taken: `site` looks it up after this module runs ("Error in
    # sitecustomize ... KeyError" on stderr without it).
    import importlib.machinery as _m
    _next = _m.PathFinder.find_spec(
        "sitecustomize", [p for p in _sys.path if _os.path.abspath(p or ".") != _boot])
    _sys.modules["sitecustomize"] = _u.module_from_spec(_next or _m.ModuleSpec("sitecustomize", None))
    if _next is not None:
        _next.loader.exec_module(_sys.modules["sitecustomize"])
'''


def _prepare_children() -> None:
    global children_dir
    import tempfile

    children_dir = tempfile.mkdtemp(prefix="enact-footprint-")
    boot = os.path.join(children_dir, "boot")
    os.makedirs(boot)
    os.makedirs(os.path.join(children_dir, "records"))
    with open(os.path.join(boot, "sitecustomize.py"), "w") as f:
        f.write(BOOT)
    os.environ[ENV_ROOT] = root
    os.environ[ENV_CHILDREN] = children_dir
    os.environ[ENV_CORE] = os.path.realpath(__file__)
    os.environ[ENV_QUIET] = ",".join(sorted(quiet))
    os.environ[ENV_READERS] = __import__("json").dumps(tree_readers)
    os.environ[ENV_TARGET] = ""
    os.environ[ENV_SPAWN] = ""
    pythonpath = os.environ.get("PYTHONPATH", "")
    os.environ["PYTHONPATH"] = boot + (os.pathsep + pythonpath if pythonpath else "")


def _mark_started(token: str, spawn_id: str) -> None:
    global child_stem
    child_stem = f"{os.getpid()}-{os.urandom(4).hex()}"
    path = os.path.join(children_dir, "records", child_stem + ".started")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    os.write(fd, f"{token}\n{spawn_id}\n{time.monotonic()!r}".encode())
    os.close(fd)


def write_child() -> None:
    """This child's record, for the parent to merge into its target."""
    global child_stem, _writing
    if not child_stem or current is None:
        return
    import json

    path = os.path.join(children_dir, "records", child_stem + ".json")
    child_stem = ""
    _writing = True
    try:
        scan_modules()
        current.loaded.update(loaded_order)
        # Loaded in this child before its recording started (its `site`), or by an extension
        # loader: no monitoring saw them run, so they are read whole. A forked child's parent
        # recorded the modules it had.
        current.reads.update(rel for rel in loaded_order[child_from:] if rel not in current.code)
        record = {"target": current_key, "ended": time.monotonic(), "footprint": current.dump()}
        with open(path + ".tmp", "w") as f:
            json.dump(record, f)
        os.rename(path + ".tmp", path)
    except OSError:
        pass  # recording ended (its directory is gone): nobody merges it
    finally:
        _writing = False
        if _signalled:
            _die(_signalled)


def _exit(code=0):
    try:
        write_child()
    finally:
        _real_exit(code)


def _on_sigterm(signum, frame) -> None:
    """SIGTERM (`Popen.terminate`, a pool's shutdown) ends a child without `atexit`: its record
    is written first, then it dies by the signal as it would have. One arriving while the
    record is written (an exiting pool worker's) waits for it."""
    global _signalled
    if _writing:
        _signalled = signum
        return
    try:
        write_child()
    finally:
        _die(signum)


def _die(signum: int) -> None:
    _signal.signal(signum, _signal.SIG_DFL)
    os.kill(os.getpid(), signum)


def _record_child(token: str, spawn_id: str) -> None:
    global child, current, current_key, footprints, depth, child_from, _writing, _signalled
    child = True
    _writing, _signalled = False, 0
    child_from = len(loaded_order)
    depth = 0
    footprints = {}
    current, current_key = Footprint(), token
    os._exit = _exit
    import atexit

    atexit.register(write_child)
    try:
        # A handler of the program's own (a server's graceful stop) runs instead; one it
        # installs later replaces this.
        if _signal.getsignal(_signal.SIGTERM) == _signal.SIG_DFL:
            _signal.signal(_signal.SIGTERM, _on_sigterm)
    except (ValueError, OSError):
        count("sigterm_unhandled")  # not the main thread: a SIGTERM leaves no record
    _mark_started(token, spawn_id)


def _after_fork_in_child() -> None:
    """A forked child (multiprocessing, a pool) records for the target that was current."""
    frame = sys._getframe(1)
    while frame is not None:
        if frame.f_code.co_name == "_execute_child":
            return  # subprocess's preexec_fn: this child execs, classified at its Popen
        frame = frame.f_back
    token = SHARED if depth > 0 else current_key
    if token is None:
        return
    if not child:
        _arm(SHARED_TOOL, 0)
    _record_child(token, "")
    _arm(TARGETS_TOOL, PY_START)
    monitoring.restart_events()


def _end_helpers() -> None:
    """multiprocessing ends its children and helpers when the interpreter exits, after this
    records: end them now, so their records come in. Its exit function terminates the daemonic
    children (SIGTERM: they record, `_on_sigterm`) and joins the others; a resource tracker
    and a forkserver (multiprocessing's, loky's) stop when the descriptor keeping them alive
    closes, as the interpreter's exit would close it."""
    util = sys.modules.get("multiprocessing.util")
    if util is not None:
        try:
            util._exit_function()
        except Exception as e:
            count(f"helpers_error:{type(e).__name__}")
    for name, module in list(sys.modules.items()):
        if not name.endswith(("resource_tracker", "forkserver")):
            continue
        for holder, attribute in (("_resource_tracker", "_fd"), ("_forkserver", "_forkserver_alive_fd")):
            helper = getattr(module, holder, None)
            fd = getattr(helper, attribute, None)
            if not isinstance(fd, int):
                continue
            try:
                setattr(helper, attribute, None)
                os.close(fd)
                count("helpers_stopped")
            except Exception as e:
                count(f"helpers_error:{type(e).__name__}")


def _running(pid: int) -> bool:
    """Whether process `pid` still runs (a zombie has ended)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    try:
        with open(f"/proc/{pid}/stat", "rb") as f:
            return f.read().rpartition(b")")[2].split()[0] != b"Z"
    except (OSError, IndexError):
        return True


def _started_children(records: str) -> dict[str, tuple[str, str, float | None]]:
    """Each child that started recording (its file stem): its target, spawn id and start."""
    try:
        names = os.listdir(records)
    except OSError:
        names = []
    started = {}
    for stem in sorted(n[: -len(".started")] for n in names if n.endswith(".started")):
        try:
            with open(os.path.join(records, stem + ".started")) as f:
                token, _, rest = f.read().partition("\n")
        except OSError:
            continue
        spawn_id, _, at = rest.partition("\n")
        try:
            started[stem] = (token, spawn_id, float(at))
        except ValueError:
            started[stem] = (token, spawn_id, None)
    return started


def _record_of(stem: str) -> str:
    """The record file of the child `stem` started: a traced program's (`<pid>-x<id>`) is
    named by its id alone, the tracer writing it before its pid is known."""
    _, _, rest = stem.partition("-")
    return (rest if rest.startswith("x") else stem) + ".json"


def _await_children(records: str, started) -> set[str]:
    """The children without a record yet that still run, after waiting up to `CHILD_WAIT`
    seconds for them to end (a pool's workers ending with the process)."""
    deadline = time.monotonic() + CHILD_WAIT
    while True:
        try:
            names = set(os.listdir(records))
        except OSError:
            names = set()
        running = {
            stem for stem in started if _record_of(stem) not in names and _running(int(stem.partition("-")[0]))
        }
        if not running or time.monotonic() >= deadline:
            return running
        time.sleep(0.02)


def _served(token: str, start: float | None, end: float | None) -> str:
    """The target a child's record joins: the one it started for, unless the parent was on
    another while it ran (a worker a later target reused; a forkserver's child, which starts
    for the forkserver's target): then every target's, shared."""
    from bisect import bisect_left, bisect_right

    if start is None:
        return SHARED
    first = max(bisect_right(switched_at, start) - 1, 0)
    last = len(switched_at) if end is None else bisect_left(switched_at, end)
    ran_into = set(switched_to[first:last]) - {None, token}
    return SHARED if ran_into else token


def merge_children() -> None:
    """Merges the children's records into the targets they served (`_served`). A Python child
    expected (spawned) without a record, or started without leaving one, makes them opaque."""
    import json

    records = os.path.join(children_dir, "records")
    started = _started_children(records)
    running = _await_children(records, started) if started else set()
    for stem, (token, spawn_id, start) in started.items():
        traced = spawn_id.startswith("exec:")
        what = f"a traced {spawn_id[len('exec:'):]}" if traced else "a Python child process"
        try:
            with open(os.path.join(records, _record_of(stem))) as f:
                record = json.load(f)
        except (OSError, ValueError):
            fp = footprint(_served(token, start, None))
            if stem in running:
                fp.opaque.add(f"{what} was still running when recording ended")
                count("children_running")
            else:
                fp.opaque.add(f"{what} ended without its record")
                count("children_unrecorded")
            continue
        key = _served(token, start, record.get("ended"))
        child = Footprint.load(record["footprint"], native=traced)
        if traced:
            child.opaque = {f"{what}: {why}" for why in child.opaque}
        footprint(key).update(child)
        count("children_merged" if key == token else "children_shared")
    spawned = {spawn_id for _, spawn_id, _ in started.values()}
    for fp in footprints.values():
        missing = fp.spawned - spawned
        if missing:
            fp.opaque.add(f"{len(missing)} Python child process(es) left no record (no site, or never ran)")
            count("children_unstarted", len(missing))
        fp.spawned.clear()


# --- shared extents ----------------------------------------------------------------------

def enter_shared() -> None:
    """What runs from here to `leave_shared` serves every later target: it is shared."""
    global depth
    if child:
        return
    depth += 1
    if depth == 1:
        _arm(SHARED_TOOL, PY_START)


def leave_shared() -> None:
    global depth
    if child:
        return
    depth -= 1
    if depth == 0:
        _arm(SHARED_TOOL, 0)


def extent(function):
    """`function`, run as a shared extent."""
    import functools

    @functools.wraps(function)
    def shared_extent(*args, **kwargs):
        enter_shared()
        try:
            return function(*args, **kwargs)
        finally:
            leave_shared()

    return shared_extent


caches: list = []


def _patch_caches() -> None:
    """`functools.lru_cache` (and `cache`, which calls it): a miss computes in an extent."""
    import functools

    original = functools.lru_cache

    def lru_cache(maxsize=128, typed=False):
        if callable(maxsize) and isinstance(typed, bool):
            wrapper = original(extent(maxsize), typed)
            caches.append(wrapper)
            return wrapper
        decorating = original(maxsize, typed)

        def decorating_function(user_function):
            wrapper = decorating(extent(user_function))
            caches.append(wrapper)
            return wrapper

        return decorating_function

    functools.lru_cache = lru_cache


def _patch_imports() -> None:
    """A module's lookup probes each path entry it checks (`_probe_lookup`). A module found
    is every later importer's (`sys.modules`), so its lookup's probes are shared; one not
    found is looked up again by each importer, so they are the importer's."""
    import _frozen_importlib as bootstrap
    import _frozen_importlib_external as external

    external._LoaderBasics.exec_module = noting(external._LoaderBasics.exec_module)
    external.ExtensionFileLoader.exec_module = noting(external.ExtensionFileLoader.exec_module)
    if not child:
        external._LoaderBasics.exec_module = extent(external._LoaderBasics.exec_module)
    finder = external.FileFinder
    find_in_entry = finder.find_spec
    find_spec = bootstrap._find_spec

    def find_spec_probing(self, fullname, target=None):
        spec = find_in_entry(self, fullname, target)
        probes = getattr(local, "probes", None)
        if probes is not None and not getattr(local, "busy", False):
            directory = relative(self.path or ".")
            if directory is not None:
                _probe_lookup(probes, directory, self, fullname.rpartition(".")[2], spec)
        return spec

    def find_spec_recording(name, path, target=None):
        outer = getattr(local, "probes", None)
        local.probes = probes = []
        try:
            spec = find_spec(name, path, target)
        finally:
            local.probes = outer
        fp = sink() if spec is None else shared if not child else current
        if fp is not None:
            fp.probes.update(probes)
        return spec

    finder.find_spec = find_spec_probing
    bootstrap._find_spec = find_spec_recording


def _probe_lookup(probes: list, directory: str, finder, tail: str, spec) -> None:
    """The files a lookup of `tail` in `directory` checked before the one it took: each was
    missing, and would have been found, so adding one changes what the import gets."""
    prefix = f"{directory}/" if directory else ""
    suffixes = [suffix for suffix, _loader in getattr(finder, "_loaders", ())]
    candidates = [f"{prefix}{tail}/__init__{s}" for s in suffixes] + [f"{prefix}{tail}{s}" for s in suffixes]
    origin = getattr(spec, "origin", None) if spec is not None else None
    found = relative(origin) if origin else None
    count("lookups_probed")
    for candidate in candidates:
        if candidate == found:
            return
        probes.append(candidate)
    if spec is None or found is None:
        probes.append(f"{prefix}{tail}")  # its namespace package's directory, missing or bare


def _checked(path, call):
    """A `stat` the code under test made: a missing path is a probe, a file a presence
    predicate found too (`_presence_only`), any other file is found. The recorder's own (this
    thread busy) is none."""
    if getattr(local, "busy", False):
        return call()
    try:
        result = call()
    except (FileNotFoundError, NotADirectoryError):
        fp = sink()
        if fp is not None and not _unrecorded(sys._getframe(2)):
            local.busy = True
            try:
                count("stat_probes")
                note(path, "missing", fp)
            finally:
                local.busy = False
        raise
    fp = sink()
    regular = (result.st_mode & 0o170000) == 0o100000
    if fp is not None and regular and not _unrecorded(sys._getframe(2)):
        local.busy = True
        try:
            absolute = _absolute(path)
            rel = relative(absolute) if absolute else None
            if rel and _presence_only(sys._getframe(2)):
                count("presence_probes")
                fp.probes.add(rel)
            elif rel:
                fp.present.add(rel)
        finally:
            local.busy = False
    return result


# The standard library's predicates that `stat` a path only to tell whether it exists or
# what kind it is, by module; pathlib's `stat`/`lstat` pass their caller's question on.
PRESENCE = {
    "genericpath": {"exists", "lexists", "isfile", "isdir", "islink"},
    "posixpath": {"exists", "lexists", "isfile", "isdir", "islink"},
}
PATHLIB = {"pathlib", "pathlib._local", "pathlib._abc"}
PATHLIB_PRESENCE = {"exists", "is_dir", "is_file", "is_symlink", "is_block_device",
                    "is_char_device", "is_fifo", "is_socket"}


def _stdlib_module(filename: str) -> str | None:
    """The standard library module `filename` (a code object's) is, frozen or not."""
    if filename.startswith("<frozen "):
        return filename[len("<frozen "):-1]
    if not filename.startswith(STDLIB) or "-packages" in filename:
        return None
    name = filename[len(STDLIB):].removesuffix(".py").removesuffix(f"{os.sep}__init__")
    return name.replace(os.sep, ".")


def _presence_only(frame) -> bool:
    """Whether the `stat` `frame` made (through pathlib's `stat` or `lstat`) is a presence
    predicate's: it uses the result's kind, never its times or size."""
    for _ in range(3):
        if frame is None:
            return False
        code = frame.f_code
        module = _stdlib_module(code.co_filename)
        if module in PATHLIB:
            if code.co_name in PATHLIB_PRESENCE:
                return True
            if code.co_name not in ("stat", "lstat"):
                return False
        else:
            return code.co_name in PRESENCE.get(module, ())
        frame = frame.f_back
    return False


def _patch_stat() -> None:
    def stat(path, *, dir_fd=None, follow_symlinks=True):
        if getattr(local, "busy", False) or dir_fd is not None or isinstance(path, int):
            return _real_stat(path, dir_fd=dir_fd, follow_symlinks=follow_symlinks)
        return _checked(path, lambda: _real_stat(path, follow_symlinks=follow_symlinks))

    def lstat(path, *, dir_fd=None):
        if getattr(local, "busy", False) or dir_fd is not None:
            return _real_lstat(path, dir_fd=dir_fd)
        return _checked(path, lambda: _real_lstat(path))

    os.stat = stat
    os.lstat = lstat


def _patch_fork_exec() -> None:
    """Launchers below `subprocess` (multiprocessing's spawn and its helpers, loky's workers)
    start programs with `_posixsubprocess.fork_exec`, which raises no audit event: each is
    classified as a `subprocess.Popen` is, a Python child told its target (`spawn`), a
    program no model covers started under the tracer."""
    try:
        import _posixsubprocess
    except ImportError:
        return
    real = _posixsubprocess.fork_exec

    def fork_exec(*args):
        caller = sys._getframe(1).f_code
        if (caller.co_name == "_execute_child" and caller.co_filename.endswith("subprocess.py")) \
                or sink() is None or getattr(local, "busy", False):
            return real(*args)  # subprocess.Popen's, classified by `_patch_popen`
        args = list(args)
        local.busy = True
        _expect_python()
        try:
            rewritten = None
            try:
                env = None if args[5] is None else dict(os.fsdecode(e).partition("=")[::2] for e in args[5])
                executables = [os.fsdecode(e) for e in args[1] or ()]
                program = next((e for e in executables if os.access(e, os.X_OK)), executables[0] if executables else None)
                rewritten = _rewrite_start(program, list(args[0]), env, args[4])
                if env is not None:
                    args[5] = [os.fsencode(f"{k}={v}") for k, v in env.items()]
                if rewritten is not None:
                    args[0] = [os.fsencode(a) for a in rewritten[0]]
                    args[1] = [os.fsencode(tracer)]
            except Exception as e:  # never break the code under test
                count(f"fork_exec_error:{type(e).__name__}")
            pid = real(*args)
            if rewritten is not None:
                _traced_started(pid, *rewritten[1:])
            _python_started(pid)
            return pid
        finally:
            local.busy = False

    _posixsubprocess.fork_exec = fork_exec


def _unix_shell(execute_child) -> str:
    """The shell `subprocess` runs `shell=True` commands with (a nix Python's own)."""
    shells = [c for c in execute_child.__code__.co_consts
              if isinstance(c, str) and c.endswith("/sh") and not c.startswith("/system/")]
    return shells[0] if shells else "/bin/sh"


def _patch_popen() -> None:
    """`subprocess.Popen` starts its program in `_execute_child`: each start is classified
    there (its audit event comes too late to change it), and a program no model covers
    starts under the tracer instead, as the same process to its caller (`enact trace
    exec`). Patched once `subprocess` is imported: a child that never imports it doesn't
    pay for the import."""
    global _popen_pending
    if "subprocess" in sys.modules:
        _patch_popen_in(sys.modules["subprocess"])
    else:
        _popen_pending = True


def _patch_popen_in(subprocess) -> None:
    global _popen_pending
    _popen_pending = False
    real = subprocess.Popen._execute_child
    names = real.__code__.co_varnames[1:real.__code__.co_argcount]
    shell_path = _unix_shell(real)

    def _execute_child(self, *args, **kwargs):
        if sink() is None or getattr(local, "busy", False) or kwargs:
            return real(self, *args, **kwargs)
        call = dict(zip(names, args))
        local.busy = True
        _expect_python()
        try:
            rewritten = None
            try:
                given, executable, shell = call["args"], call["executable"], call["shell"]
                if isinstance(given, (str, bytes, os.PathLike)):
                    argv = [given]
                else:
                    argv = list(given)
                if shell:
                    argv = [shell_path, "-c"] + argv
                    if executable:
                        argv[0] = executable
                program = executable if executable is not None else argv[0]
                rewritten = _rewrite_start(program, argv, call["env"], call["cwd"])
                if rewritten is not None:
                    call.update(args=rewritten[0], executable=None, shell=False)
                    args = tuple(call[name] for name in names)
            except Exception as e:  # never break the code under test
                count(f"popen_error:{type(e).__name__}")
            result = real(self, *args)
            if rewritten is not None:
                _traced_started(self.pid, *rewritten[1:])
            _python_started(self.pid)
            return result
        finally:
            local.busy = False

    subprocess.Popen._execute_child = _execute_child


def _patch_posix_spawn() -> None:
    """`os.posix_spawn` and `os.posix_spawnp` called directly: classified, and a program no
    model covers started under the tracer (`subprocess`'s own come through `_patch_popen`)."""
    for name, search in (("posix_spawn", False), ("posix_spawnp", True)):
        real = getattr(os, name, None)
        if real is None:
            continue

        def posix_spawn(path, argv, env, *args, _real=real, _search=search, **kwargs):
            caller = sys._getframe(1).f_code
            if (caller.co_name == "_posix_spawn" and caller.co_filename.endswith("subprocess.py")) \
                    or sink() is None or getattr(local, "busy", False):
                return _real(path, argv, env, *args, **kwargs)
            local.busy = True
            _expect_python()
            try:
                rewritten = None
                try:
                    program = os.fsdecode(path)
                    if not _search and "/" not in program:
                        program = os.path.join(".", program)  # posix_spawn takes a path as is
                    rewritten = _rewrite_start(program, list(argv), env, None)
                except Exception as e:  # never break the code under test
                    count(f"posix_spawn_error:{type(e).__name__}")
                if rewritten is not None:
                    pid = _real(tracer, rewritten[0], env, *args, **kwargs)
                    _traced_started(pid, *rewritten[1:])
                    return pid
                pid = _real(path, argv, env, *args, **kwargs)
                _python_started(pid)
                return pid
            finally:
                local.busy = False

        setattr(os, name, posix_spawn)


def _expect_python() -> None:
    local.python = False


def _python_started(pid: int) -> None:
    """The start just made, as `pid`, was a Python child's (`_propagate`)."""
    if getattr(local, "python", False):
        _unstarted.add(pid)
        local.python = False


def _patch_kill() -> None:
    """A parent may end a Python child it started before the child's recording started
    (dagster terminates its compute-log watcher as soon as a fast step ends): the child
    then leaves no record, and its target turns opaque though it ran none of its code.
    Ending one (`os.kill`, which `Popen.terminate` and multiprocessing call) with a signal
    it can record by (not 0, not SIGKILL) first waits until its recording has started
    (`CHILD_START_WAIT` at most): its SIGTERM handler or `atexit` then writes its record.
    One that never starts recording (no site, `-I`) still turns its target opaque."""
    real = os.kill

    def kill(pid, sig):
        if pid in _unstarted and sig not in (0, _signal.SIGKILL):
            _unstarted.discard(pid)
            busy, local.busy = getattr(local, "busy", False), True
            try:
                _await_start(pid)
            finally:
                local.busy = busy
        return real(pid, sig)

    os.kill = kill


def _await_start(pid: int) -> None:
    """Until child `pid` started recording (its `.started` record), or ended."""
    records = os.path.join(children_dir, "records")
    prefix = f"{pid}-"
    deadline = time.monotonic() + CHILD_START_WAIT
    waited = False
    while _running(pid):
        try:
            if any(n.startswith(prefix) and n.endswith(".started") for n in os.listdir(records)):
                break
        except OSError:
            break
        if time.monotonic() >= deadline:
            count("children_ended_unstarted")
            break
        waited = True
        time.sleep(0.005)
    if waited:
        count("children_awaited_start")


def _patch_spawners() -> None:
    """Every start this module can rewrite (`_patch_popen`, `_patch_fork_exec`,
    `_patch_posix_spawn`), and the ending of the Python children they start (`_patch_kill`);
    `os.exec*` and `os.system` are classified by their audit events."""
    _patch_fork_exec()
    _patch_popen()
    _patch_posix_spawn()
    _patch_kill()


# --- imports and own modules -------------------------------------------------------------

def _importer(frame) -> str:
    """Who an import statement running in `frame` imports for: the repository module whose
    body (or class body) runs it, the current target when one of its functions does (SHARED
    in a shared extent or with no target recording), `EXTERNAL` for code outside it."""
    code = frame.f_code
    rel = relative(code.co_filename)
    if rel is None:
        return EXTERNAL
    if not code.co_flags & CO_NEWLOCALS:
        return rel
    active_key = _ctx_target.get() or current_key
    if depth > 0 or active_key in (None, SHARED):
        return SHARED
    return KEY + active_key


def _imported(name: str, globals_: dict, fromlist, level: int) -> list[str]:
    """The modules an import statement binds or loads: the one it names, its packages, and
    the submodules its `from` list names."""
    if level:
        import _frozen_importlib as bootstrap

        name = bootstrap._resolve_name(name, bootstrap._calc___package__(globals_), level)
    parts = name.split(".")
    names = [".".join(parts[:i]) for i in range(1, len(parts) + 1)]
    names += [f"{name}.{item}" for item in fromlist or () if isinstance(item, str) and item != "*"]
    return names


def _note_import(frame, name: str, globals_: dict, fromlist, level: int) -> None:
    importer = _importer(frame)
    package = globals_.get("__package__") or globals_.get("__name__") if level else None
    key = (importer, name, tuple(fromlist or ()), level, package)
    if key in _imports_seen:
        return
    _imports_seen.add(key)
    modules = sys.modules
    for imported in _imported(name, globals_, fromlist, level):
        module = modules.get(imported)
        path = _module_file(module) if module is not None else None
        rel = relative(path) if path else None
        if rel:
            import_edges.add((importer, rel))


def _patch_import_statements() -> None:
    """`builtins.__import__`: each import statement's edge (`import_edges`), whether it loads
    the module or finds it loaded (the import system's own loads show only the first)."""
    import builtins

    original = builtins.__import__

    def __import__(name, globals=None, locals=None, fromlist=(), level=0):
        module = original(name, globals, locals, fromlist, level)
        if not getattr(local, "busy", False):
            local.busy = True
            try:
                _note_import(sys._getframe(1), name, globals if isinstance(globals, dict) else {},
                             fromlist, level)
            except Exception:
                count("imports_unnoted")
                import_edges.add((EXTERNAL, "*"))  # every own module stays every target's
            finally:
                local.busy = False
        return module

    builtins.__import__ = __import__


def _own_holders(module: str, owners: dict[str, list[str]], importers: dict[str, set[str]],
                 fps: dict[str, Footprint]) -> set[str] | None:
    """The targets of `fps` an own `module` belongs to: its own targets, and those whose own
    modules or code imported it, through own modules only. None: it is every target's."""
    common = fps[SHARED]
    if module in common.reads or common.code.get(module) or (EXTERNAL, "*") in import_edges:
        return None
    loader = first_loaded_by.get(module, SHARED)
    if loader in (None, SHARED):
        return None
    modules, keys, todo = {module}, set(), [module]
    while todo:
        for importer in importers.get(todo.pop(), ()):
            if importer.startswith(KEY):
                keys.add(importer[len(KEY):])
            elif importer in owners or importer in own_modules:
                if importer not in modules:
                    modules.add(importer)
                    todo.append(importer)
            else:
                return None  # start-up, a shared extent, another module, outside code
    holders = keys | {key for m in modules for key in owners.get(m, ())}
    if loader not in holders:
        return None  # loaded by what no import statement shows (a runner's, a registry's)
    return holders | {key for key, fp in fps.items() if key != SHARED and module in fp.code}


def narrow_own_modules(fps: dict[str, Footprint] | None = None, order: list[str] | None = None,
                       marks: dict[str, int] | None = None) -> int:
    """Gives each own module whose holders are known (`_own_holders`) to them alone: out of
    the shared footprint and the load order, into each holder's code and `loaded`. Returns
    how many it narrowed. `fps`, `order` and `marks` (a checkpoint's copies) default to the
    recording's own footprints, `loaded_order` and `loaded_marks`."""
    fps = footprints if fps is None else fps
    order = loaded_order if order is None else order
    marks = loaded_marks if marks is None else marks
    common = fps[SHARED]
    owners: dict[str, list[str]] = {}
    for key in fps:
        if key != SHARED:
            owners.setdefault(key.split("::", 1)[0], []).append(key)
    importers: dict[str, set[str]] = {}
    for importer, module in import_edges:
        importers.setdefault(module, set()).add(importer)
    narrowed = {}
    for module in sorted((own_modules | set(owners)) & set(common.code)):
        holders = _own_holders(module, owners, importers, fps)
        if holders is not None:
            narrowed[module] = holders
    for module, holders in narrowed.items():
        del common.code[module]
        present = module in common.present
        common.present.discard(module)
        for key in holders:
            fp = fps.get(key)
            if fp is not None:
                fp.code.setdefault(module, set())
                fp.loaded.add(module)
                if present:
                    fp.present.add(module)
    if narrowed:
        kept, before = 0, [0]
        for rel in order:
            kept += rel not in narrowed
            before.append(kept)
        for key, mark in marks.items():
            marks[key] = before[mark]
        order[:] = [rel for rel in order if rel not in narrowed]
    count("own_modules_narrowed", len(narrowed))
    return len(narrowed)


# --- driving -----------------------------------------------------------------------------

def wsgi_middleware(app):
    """WSGI middleware extracting `X-Enact-Target` into `request_target`."""
    def wrapped(environ, start_response):
        target = environ.get("HTTP_X_ENACT_TARGET")
        if target:
            with request_target(target.strip()):
                return list(app(environ, start_response))
        return app(environ, start_response)
    return wrapped


def asgi_middleware(app):
    """ASGI middleware extracting `x-enact-target` into `request_target`."""
    async def wrapped(scope, receive, send):
        target = None
        for k, v in scope.get("headers") or ():
            if k.lower() == b"x-enact-target":
                target = v.decode("latin1").strip()
                break
        if target:
            with request_target(target):
                return await app(scope, receive, send)
        return await app(scope, receive, send)
    return wrapped


def _patch_http_context() -> None:
    """Propagates `X-Enact-Target` on outbound `http.client` calls and scopes inbound
    `http.server` / `wsgiref` requests to `request_target`."""
    try:
        import http.client
        orig_putrequest = http.client.HTTPConnection.putrequest
        orig_endheaders = http.client.HTTPConnection.endheaders

        def putrequest(self, method, url, *args, **kwargs):
            self._enact_has_target_hdr = False
            return orig_putrequest(self, method, url, *args, **kwargs)

        orig_putheader = http.client.HTTPConnection.putheader

        def putheader(self, header, *values):
            if isinstance(header, str) and header.lower() == "x-enact-target":
                self._enact_has_target_hdr = True
            elif isinstance(header, bytes) and header.lower() == b"x-enact-target":
                self._enact_has_target_hdr = True
            return orig_putheader(self, header, *values)

        def endheaders(self, message_body=None, *, encode_chunked=False):
            target = active_target_key()
            if target and not getattr(self, "_enact_has_target_hdr", False):
                orig_putheader(self, "X-Enact-Target", target)
                self._enact_has_target_hdr = True
            return orig_endheaders(self, message_body, encode_chunked=encode_chunked)

        http.client.HTTPConnection.putrequest = putrequest
        http.client.HTTPConnection.putheader = putheader
        http.client.HTTPConnection.endheaders = endheaders
    except Exception:
        pass
    try:
        import http.server
        orig_parse = http.server.BaseHTTPRequestHandler.parse_request

        def parse_request(self):
            ok = orig_parse(self)
            if ok and hasattr(self, "headers") and self.headers is not None:
                target = self.headers.get("X-Enact-Target")
                if target:
                    self._enact_ctx = request_target(target.strip())
                    self._enact_ctx.__enter__()
            return ok

        orig_handle_one = http.server.BaseHTTPRequestHandler.handle_one_request

        def handle_one_request(self):
            self._enact_ctx = None
            try:
                return orig_handle_one(self)
            finally:
                ctx = getattr(self, "_enact_ctx", None)
                if ctx is not None:
                    self._enact_ctx = None
                    ctx.__exit__(None, None, None)

        http.server.BaseHTTPRequestHandler.parse_request = parse_request
        http.server.BaseHTTPRequestHandler.handle_one_request = handle_one_request
    except Exception:
        pass
    try:
        import wsgiref.handlers
        orig_run = wsgiref.handlers.BaseHandler.run

        def run(self, application):
            target = self.environ.get("HTTP_X_ENACT_TARGET") if hasattr(self, "environ") and self.environ else None
            if target:
                with request_target(target.strip()):
                    return orig_run(self, application)
            return orig_run(self, application)

        wsgiref.handlers.BaseHandler.run = run
    except Exception:
        pass


def _install(repo: str, recorders) -> None:
    global root, own, tracer, outer_kernel_trace
    root = os.path.realpath(repo) + os.sep
    outer_kernel_trace = os.environ.get(ENV_OUTER_KERNEL_TRACE, "").lower() in ("1", "true", "yes")
    exe = os.environ.get(ENV_EXE, "")
    tracer = "" if outer_kernel_trace else (exe if sys.platform == "linux" and exe and os.access(exe, os.X_OK) else "")
    own = tuple(os.path.realpath(r) for r in recorders) + (os.path.realpath(__file__),)
    monitoring.use_tool_id(TARGETS_TOOL, TARGETS_NAME)
    monitoring.register_callback(TARGETS_TOOL, PY_START, on_start)
    sys.addaudithook(on_audit)
    _patch_imports()
    _patch_stat()
    _patch_http_context()


def start(repo: str, recorders=(), quiet_programs=(), unlisted_callers=(), readers=None) -> None:
    """Records this process: start-up into the shared footprint until the first `switch`.
    `recorders`: the adapter's own files, never recorded; `quiet_programs`: programs that
    read nothing of the repository unless an argument names a path in it; `readers`:
    programs that read the paths their arguments name (directories whole) and, by name,
    paths relative to their working directory (`{"sqlx": (".env",)}`);
    `unlisted_callers`: fragments of the file names of code whose directory listings say
    nothing about the tests (a test runner's collection walk, whose findings are targets
    themselves, and whose `conftest.py`/`__init__.py` checks are probes)."""
    global current, current_key, SHARED_TOOL, unlisted
    quiet.update(quiet_programs)
    tree_readers.update({name: tuple(paths) for name, paths in (readers or {}).items()})
    unlisted = tuple(unlisted_callers)
    SHARED_TOOL = next(t for t in (4, 3, 5, 0) if monitoring.get_tool(t) is None)
    _install(repo, recorders)
    monitoring.use_tool_id(SHARED_TOOL, SHARED_NAME)
    monitoring.register_callback(SHARED_TOOL, PY_START, on_shared_start)
    _prepare_children()
    _patch_caches()
    _patch_spawners()
    _patch_import_statements()
    os.register_at_fork(after_in_child=_after_fork_in_child)
    _note_started_modules(shared)
    current, current_key = shared, SHARED
    switched_at.append(time.monotonic())
    switched_to.append(SHARED)
    monitoring.set_events(TARGETS_TOOL, PY_START)


def _note_started_modules(fp: Footprint) -> None:
    """The repository modules loaded before recording started: no monitoring saw their
    bodies run, nor what those called, so `fp` reads them whole."""
    scan_modules()
    fp.reads.update(loaded_order)


def start_child() -> None:
    """In a child process (sitecustomize): records all of it for the target that started it."""
    global children_dir
    token = os.environ.get(ENV_TARGET, "")
    children_dir = os.environ.get(ENV_CHILDREN, "")
    if not token or not children_dir or not os.path.isdir(children_dir):
        return
    quiet.update(filter(None, os.environ.get(ENV_QUIET, "").split(",")))
    try:
        tree_readers.update({k: tuple(v) for k, v in __import__("json").loads(os.environ.get(ENV_READERS) or "{}").items()})
    except ValueError:
        count("readers_unreadable")  # its programs make their targets opaque
    _record_child(token, os.environ.get(ENV_SPAWN, ""))
    _install(os.environ[ENV_ROOT], ())
    _patch_spawners()
    os.register_at_fork(after_in_child=_after_fork_in_child)
    monitoring.set_events(TARGETS_TOOL, PY_START)


def footprint(key: str) -> Footprint:
    return footprints.setdefault(key, Footprint())


STATS = bool(os.environ.get("ENACT_FOOTPRINT_STATS"))
_cache_seen: dict[int, tuple[int, int]] = {}
cache_use: dict[int, tuple[set, set]] = {}


def _account_caches(key: str | None) -> None:
    """With ENACT_FOOTPRINT_STATS: which targets read each cache, and which computed it."""
    for wrapper in caches:
        info = wrapper.cache_info()
        hits, misses = _cache_seen.get(id(wrapper), (0, 0))
        if (info.hits, info.misses) == (hits, misses):
            continue
        _cache_seen[id(wrapper)] = (info.hits, info.misses)
        read_by, computed_by = cache_use.setdefault(id(wrapper), (set(), set()))
        if info.hits > hits:
            read_by.add(key)
        if info.misses > misses:
            computed_by.add(key)


def _arm(tool: int, events: int) -> None:
    """Sets `tool`'s events while the recorder holds it: another tool's are never touched."""
    if monitoring.get_tool(tool) in (TARGETS_NAME, SHARED_NAME):
        monitoring.set_events(tool, events)


def _check_monitoring() -> None:
    """Another tool may have freed or taken a recorder's monitoring id, replaced its
    callback or turned its events off (a profiler on PROFILER_ID, `sys.monitoring.set_events`
    in a test): what ran since the last check went unseen. The target recording then is
    opaque rather than holding too few functions (every target, for the shared tool), and a
    tool still free is taken back for the next."""
    for tool, name, callback, fp, on in (
        (TARGETS_TOOL, TARGETS_NAME, on_start, current, current is not None),
        (SHARED_TOOL, SHARED_NAME, on_shared_start, shared, depth > 0),
    ):
        lost = _rearm(tool, name, callback, on)
        if lost:
            count("monitoring_lost")
            if fp is not None:
                fp.opaque.add(f"sys.monitoring tool {tool} {lost}: the code it ran went unseen")


def _rearm(tool: int, name: str, callback, on: bool) -> str | None:
    """How `tool` stopped seeing calls since it was armed (None: it didn't); it is armed again
    when it can be."""
    owner = monitoring.get_tool(tool)
    if owner != name:
        if owner is not None:
            return f"taken by {owner}"
        monitoring.use_tool_id(tool, name)
        lost = "freed"
    else:
        lost = None
    if monitoring.register_callback(tool, PY_START, callback) is not callback:
        lost = lost or "given another callback"
    if on and not monitoring.get_events(tool) & PY_START:
        lost = lost or "silenced"
    if lost:
        monitoring.set_events(tool, PY_START if on else 0)
    return lost


def switch(key: str | None) -> None:
    """Records into `key`'s footprint (SHARED: every target's); None: a target not recorded,
    which runs unmonitored (its imports and cache computations are still shared)."""
    global current, current_key
    if child:
        return
    if STATS:
        _account_caches(current_key)
    fp = None if key is None else footprint(key)
    if fp is current:
        return
    _check_monitoring()
    _mark_loaded(current_key)
    _arm(TARGETS_TOOL, 0 if fp is None else PY_START)
    current, current_key = fp, key
    switched_at.append(time.monotonic())
    switched_to.append(key)
    os.environ[ENV_TARGET] = key or ""
    monitoring.restart_events()


def finish() -> tuple[dict, dict[str, tuple[dict, list[str]]]]:
    """Stops recording: the shared footprint's map entry, each target's own entry, and why
    each target is opaque (the shared footprint's reasons too)."""
    global current
    if STATS:
        _account_caches(current_key)
    _check_monitoring()
    _mark_loaded(current_key)
    _arm(TARGETS_TOOL, 0)
    _arm(SHARED_TOOL, 0)
    current = None
    switched_at.append(time.monotonic())
    switched_to.append(None)
    _end_helpers()
    merge_children()
    import shutil

    shutil.rmtree(children_dir, ignore_errors=True)
    kinds: dict[str, str | None] = {}
    count("probes_recorded", sum(len(fp.probes) for fp in footprints.values()))
    for fp in footprints.values():
        fp.collapse_probes(kinds)
    count("probes_kept", sum(len(fp.probes) for fp in footprints.values()))
    scan_modules()
    narrow_own_modules()
    # Loaded by the end of every target: shared. A module whose body no monitoring saw run
    # (an extension module) is read whole, as loaded modules are among the files.
    marks = {key: loaded_marks.get(key, len(loaded_order)) for key in footprints if key != SHARED}
    common = min(marks.values(), default=len(loaded_order))
    ran = set(shared.code).union(*(fp.code for fp in footprints.values()))
    shared.reads.update(rel for rel in loaded_order if rel not in ran)
    at = {rel: i for i, rel in enumerate(loaded_order)}
    out = {}
    for key, fp in footprints.items():
        if key != SHARED:
            # What it ran itself was loaded by its end (a file run by path, not imported).
            own = (f for f in fp.code if f.endswith(".py"))
            out[key] = (fp.entry(marks[key], at, own, shared), sorted(fp.opaque | shared.opaque))
    return shared.entry(common, at), out


def checkpoint(keys) -> tuple[dict, dict[str, tuple[dict, list[str]]], list[str]] | None:
    """What `finish` would give for the targets in `keys`, each ended (none of its code runs
    again), while recording goes on: from copies, for the map a process killed before its
    end leaves. The adapter publishes each completed target once. The children's
    records written so far are merged into the copies, and a child spawned without a
    record, or ended without one, makes its target opaque, as at the end. A target left out
    is one a child still running may record for (it started before the target ended): what
    it does there is unknown yet; one serving every target (a helper running since start-up)
    leaves none. Also returns the load order its entries name. None: no target to write.
    Shared teardown not run yet (session fixtures') is in no checkpoint: a killed process
    never runs it either."""
    if child:
        return None
    busy = getattr(local, "busy", False)
    local.busy = True  # what it opens and stats is the recorder's own
    try:
        return _checkpoint(keys)
    finally:
        local.busy = busy


def _checkpoint(keys):
    import json
    from bisect import bisect_right

    _mark_loaded(current_key)
    scan_modules()
    fps = {SHARED: shared.copy()}
    fps.update((key, footprints[key].copy()) for key in keys if key in footprints and key != SHARED)
    records = os.path.join(children_dir, "records")
    started = _started_children(records)
    unknown: set[str] = set()
    for stem, (token, spawn_id, start) in started.items():
        traced = spawn_id.startswith("exec:")
        what = f"a traced {spawn_id[len('exec:'):]}" if traced else "a Python child process"
        try:
            with open(os.path.join(records, _record_of(stem))) as f:
                record = json.load(f)
        except (OSError, ValueError):
            if _running(int(stem.partition("-")[0])):
                first = 0 if start is None else max(bisect_right(switched_at, start) - 1, 0)
                unknown.update(key for key in switched_to[first:] if key)
            else:
                fp = fps.get(_served(token, start, None))
                if fp is not None:
                    fp.opaque.add(f"{what} ended without its record")
            continue
        fp = fps.get(_served(token, start, record.get("ended")))
        if fp is not None:
            child_fp = Footprint.load(record["footprint"], native=traced)
            if traced:
                child_fp.opaque = {f"{what}: {why}" for why in child_fp.opaque}
            fp.update(child_fp)
    if SHARED in unknown:
        count("checkpoints_held")
        return None  # a child serving every target still runs
    for key in unknown:
        fps.pop(key, None)
    if len(fps) == 1:
        return None
    spawned = {spawn_id for _, spawn_id, _ in started.values()}
    for fp in fps.values():
        if fp.spawned - spawned:
            fp.opaque.add(f"{len(fp.spawned - spawned)} Python child process(es) left no record (no site, or never ran)")
        fp.spawned.clear()
    kinds: dict[str, str | None] = {}
    for fp in fps.values():
        fp.collapse_probes(kinds)
    order, marks = list(loaded_order), {key: loaded_marks.get(key, len(loaded_order)) for key in fps}
    marks.pop(SHARED, None)
    narrow_own_modules(fps, order, marks)
    common = min(marks.values())
    ran = set(shared.code).union(*(fp.code for fp in footprints.values()), *(fp.code for fp in fps.values()))
    fps[SHARED].reads.update(rel for rel in order if rel not in ran)
    at = {rel: i for i, rel in enumerate(order)}
    out = {}
    for key, fp in fps.items():
        if key != SHARED:
            own = (f for f in fp.code if f.endswith(".py"))
            out[key] = (fp.entry(marks[key], at, own, fps[SHARED]), sorted(fp.opaque | fps[SHARED].opaque))
    count("checkpoints")
    return fps[SHARED].entry(common, at), out, order


def write_map(out_dir: str, prefix: str, shared_entry: dict, targets: dict, path: str | None = None,
              order: list[str] | None = None) -> str:
    """Writes the map: `shared` once, which enact lays over every target (each holds it),
    the targets' own entries, and the order the process loaded its modules in
    (`load_order`, a checkpoint's `order`), whose prefixes they name (`loaded_through`).
    Returns its path, unique in `out_dir` (shards run side by side, in sandboxes where pids
    repeat), or `path` (a checkpoint's), which it replaces whole: a reader, or a kill while
    it writes, finds the last one complete."""
    import json
    import tempfile

    os.makedirs(out_dir, exist_ok=True)
    fd, temp = tempfile.mkstemp(suffix=".partial", prefix=prefix, dir=out_dir)
    if path is None:
        path = temp.removesuffix(".partial") + ".json"
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(
                {
                    "version": 1,
                    "recorder": RECORDER,
                    "outcomes": True,
                    "load_order": loaded_order if order is None else order,
                    "shared": shared_entry,
                    "targets": targets,
                },
                f,
                separators=(",", ":"),
            )
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    return path


def write_stats(map_path: str, targets: int, opaque: dict) -> None:
    """The recording's summary and opaque targets beside its map (`<map>.stats`), and in
    $ENACT_FOOTPRINT_STATS when that names a directory (enact removes the map's)."""
    import json

    stats_path = map_path[: -len(".json")] + ".stats"
    report = {**summary(targets), "map_bytes": os.path.getsize(map_path), "opaque": opaque}
    record = json.dumps(report, indent=1)
    keep = os.environ.get("ENACT_FOOTPRINT_STATS", "")
    for path in (stats_path, os.path.join(keep, os.path.basename(stats_path)) if os.path.isdir(keep) else None):
        if path:
            with open(path, "w") as f:
                f.write(record)


def summary(targets: int) -> dict:
    """What the recording saw, for its log and diagnostics."""
    report = dict(sorted(stats.items()))
    report["targets"] = targets
    report["opaque_targets"] = sum(1 for k, fp in footprints.items() if k != SHARED and fp.opaque)
    report["shared_opaque"] = sorted(shared.opaque)
    report["shared_files"] = len(set(shared.code) | shared.reads | shared.present)
    report["shared_probes"] = len(shared.probes)
    report["shared_dirs"] = len(shared.dirs)
    if STATS:
        # Targets that read a cached result another target computed: the old recorder left
        # the computing code out of their footprints.
        lost = [len(read_by - computed_by - {None, SHARED}) for read_by, computed_by in cache_use.values()]
        report["cache_reads_of_other_targets_results"] = sum(lost)
        report["caches_read_across_targets"] = sum(1 for n in lost if n)
        report["caches"] = len(caches)
    return report
