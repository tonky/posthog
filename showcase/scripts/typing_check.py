#!/usr/bin/env python3
"""Backend static typing on changed Python files, with per-file JUnit evidence.

Upstream gates the PR with `mypy .` over the whole tree. Checking the changed
files (and whatever they import) reproduces the diagnostics that belong to the
diff in a fraction of the time. Each changed file becomes one JUnit testcase;
files outside the diff appear only when they carry diagnostics. Failure text
is the canonical `file:line: error: message [code]` form, which the capture
side derives identically from the upstream job log.
"""
import os
import re
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import quoteattr

SUITE = "static-typing"
ERROR = re.compile(r"^(?P<file>[^:\s]+\.pyi?):(?P<line>\d+):(?:\d+:)? error: (?P<msg>.*?)\s+\[(?P<code>[\w-]+)\]$")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x1b\(.")


def canonical(match):
    return f"{match['file']}:{match['line']}: error: {match['msg']} [{match['code']}]"


def diagnostics(output):
    """Diagnostics per file, in report order, without duplicates."""
    errors = {}
    seen = set()
    for raw in output.splitlines():
        match = ERROR.match(ANSI.sub("", raw).strip())
        if match and canonical(match) not in seen:
            seen.add(canonical(match))
            errors.setdefault(match["file"], []).append(canonical(match))
    return errors


def junit(changed, errors):
    cases = []
    for path in sorted(set(changed) | set(errors)):
        if path in errors:
            text = "\n".join(errors[path])
            cases.append(f'  <testcase classname="mypy" file={quoteattr(path)} name={quoteattr(path)}>\n'
                         f"    <failure message={quoteattr(text)}>{quoteattr(text)[1:-1]}</failure>\n  </testcase>")
        else:
            cases.append(f'  <testcase classname="mypy" file={quoteattr(path)} name={quoteattr(path)}/>')
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            f'<testsuite name="{SUITE}" tests="{len(cases)}" failures="{len(errors)}">\n'
            + "\n".join(cases) + "\n</testsuite>\n")


def main(argv):
    changed = sorted({f for f in argv if f.endswith((".py", ".pyi")) and Path(f).is_file()})
    if not changed:
        return 0
    env = dict(os.environ, NO_COLOR="1", MYPY_FORCE_COLOR="0")
    # Upstream uses two workers; one halves peak memory on shared hosts and
    # yields the same diagnostics. Override with MYPY_NUM_WORKERS.
    env.setdefault("MYPY_NUM_WORKERS", "1")
    result = subprocess.run(["uv", "run", "--no-sync", "mypy", "--no-color-output", "--show-error-codes", *changed],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, text=True)
    sys.stdout.write(result.stdout)
    errors = diagnostics(result.stdout)
    if result.returncode not in (0, 1):
        print(f"mypy failed to run (exit {result.returncode})", file=sys.stderr)
        return result.returncode
    if result.returncode == 1 and not errors:
        print("mypy reported failure without parseable diagnostics", file=sys.stderr)
        return 70
    results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
    if results_dir:
        Path(results_dir).mkdir(parents=True, exist_ok=True)
        (Path(results_dir) / "typing.xml").write_text(junit(changed, errors))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
