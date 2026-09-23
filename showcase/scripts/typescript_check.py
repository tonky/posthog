#!/usr/bin/env python3
"""Frontend static type checking on changed TypeScript files, with per-file JUnit evidence.

Runs hermetic `oxlint` (from enve tools, without pnpm) with `--type-aware --type-check`
on changed `.ts`/`.tsx` files. If any changed file matches Kea logic patterns, invokes
`node frontend/bin/check-typegen.mjs` first to validate Kea logic contracts.
Each changed TypeScript file becomes one JUnit testcase; files outside the diff appear
only when they carry diagnostics. Failure text is normalized to the canonical
`file:line: error: message [code]` form.
"""
import os
import re
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import quoteattr

SUITE = "frontend-typing"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x1b\(.")

# Matches oxlint format:
# path/to/file.tsx:10:5: error typescript(TS2322): Type 'string' is not assignable to type 'number'.
# or general oxlint error: path/to/file.tsx:10:5: error rule-name: message
OXLINT_ERROR = re.compile(
    r"^(?P<file>[^:\s]+\.[mc]?[jt]sx?):(?P<line>\d+):(?:\d+:)? error (?:typescript\((?P<code>TS\d+)\)|(?P<altcode>[\w-]+)): (?P<msg>.*)$"
)

# Matches tsc / tsgo format:
# path/to/file.tsx:10:5 - error TS2322: Type 'string' is not assignable to type 'number'.
TSC_ERROR = re.compile(
    r"^(?P<file>[^:\s]+\.[mc]?[jt]sx?):(?P<line>\d+):(?:\d+)?\s*-\s*error\s+(?P<code>TS\d+):\s*(?P<msg>.*)$"
)


def canonical(file_path, line, msg, code):
    return f"{file_path}:{line}: error: {msg.strip()} [{code}]"


def diagnostics(output):
    """Diagnostics per file, in report order, without duplicates."""
    errors = {}
    seen = set()
    for raw in output.splitlines():
        plain = ANSI.sub("", raw).strip()
        m = OXLINT_ERROR.match(plain)
        if m:
            code = m.group("code") or m.group("altcode")
            c = canonical(m.group("file"), m.group("line"), m.group("msg"), code)
            if c not in seen:
                seen.add(c)
                errors.setdefault(m.group("file"), []).append(c)
            continue
        m = TSC_ERROR.match(plain)
        if m:
            c = canonical(m.group("file"), m.group("line"), m.group("msg"), m.group("code"))
            if c not in seen:
                seen.add(c)
                errors.setdefault(m.group("file"), []).append(c)
    return errors


def junit(changed, errors):
    cases = []
    for path in sorted(set(changed) | set(errors)):
        if path in errors:
            text = "\n".join(errors[path])
            cases.append(f'  <testcase classname="typescript" file={quoteattr(path)} name={quoteattr(path)}>\n'
                         f"    <failure message={quoteattr(text)}>{quoteattr(text)[1:-1]}</failure>\n  </testcase>")
        else:
            cases.append(f'  <testcase classname="typescript" file={quoteattr(path)} name={quoteattr(path)}/>')
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            f'<testsuite name="{SUITE}" tests="{len(cases)}" failures="{len(errors)}">\n'
            + "\n".join(cases) + "\n</testsuite>\n")


def is_kea_logic(file_path):
    p = Path(file_path)
    if re.search(r"Logic(Type)?\.[jt]sx?$", p.name):
        return True
    try:
        content = p.read_text(encoding="utf-8", errors="ignore")
        return bool(re.search(r"\bkea\s*[<(]", content))
    except Exception:
        return False


def main(argv):
    ts_suffixes = (".ts", ".tsx", ".mts", ".cts")
    changed = sorted({f for f in argv if f.endswith(ts_suffixes) and Path(f).is_file()})
    if not changed:
        print("No changed TypeScript files to check.")
        return 0

    has_error = False

    # 1. Antecedent Kea typegen check if any changed file is a Kea logic
    kea_files = [f for f in changed if is_kea_logic(f)]
    typegen_script = Path("frontend/bin/check-typegen.mjs")
    if kea_files and typegen_script.is_file():
        print(f"Checking Kea logic typegen for {len(kea_files)} file(s)...")
        res = subprocess.run(["node", str(typegen_script), *kea_files], check=False)
        if res.returncode != 0:
            has_error = True

    # 2. Main hermetic oxlint type check on all changed TypeScript files
    cmd = ["oxlint", "--quiet", "--type-aware", "--type-check"]
    if Path("tsconfig.json").is_file():
        cmd.extend(["--tsconfig", "tsconfig.json"])
    cmd.extend(changed)

    print(f"Running oxlint typecheck on {len(changed)} changed TypeScript file(s)...")
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.stdout:
        sys.stdout.write(result.stdout)

    errors = diagnostics(result.stdout)
    if result.returncode != 0 and not errors:
        # Fallback if oxlint failed with general error
        print(f"oxlint exited with code {result.returncode}", file=sys.stderr)
        has_error = True
    elif errors:
        has_error = True

    results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
    if results_dir:
        Path(results_dir).mkdir(parents=True, exist_ok=True)
        (Path(results_dir) / "frontend-typing.xml").write_text(junit(changed, errors))

    return 1 if has_error else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
