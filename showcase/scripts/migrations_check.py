#!/usr/bin/env python3
"""Change-scoped Django migration drift check with per-file JUnit evidence.

Upstream runs `hogli db:check-migrations` (or `makemigrations --check --dry-run`).
Running full migration introspection on PRs that touch no models is a huge waste.
This script checks if any `{changed_files}` affect Django models or migrations:
- `posthog/models/**`, `ee/**/models/**`, `products/**/models/**`, `*/models.py`
- `*/migrations/**`
If none are modified, it exits 0 immediately (0ms) without loading Python/Django.
If model files changed, it runs `makemigrations --check --dry-run` and outputs
canonical failure signatures into `$ENACT_REPLAY_RESULTS/migrations-check.xml`.
"""
import os
import re
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import quoteattr

SUITE = "migrations-check"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x1b\(.")


def is_model_or_migration(path_str):
    p = Path(path_str)
    if p.suffix not in {".py", ".pyi"}:
        return False
    parts = p.parts
    if any("migration" in part or "model" in part for part in parts):
        return True
    if p.name == "models.py" or p.name.startswith("model_"):
        return True
    return False


def junit(changed, errors):
    cases = []
    for path in sorted(set(changed) | set(errors)):
        if path in errors:
            text = "\n".join(errors[path])
            cases.append(f'  <testcase classname="django-migrations" file={quoteattr(path)} name={quoteattr(path)}>\n'
                         f"    <failure message={quoteattr(text)}>{quoteattr(text)[1:-1]}</failure>\n  </testcase>")
        else:
            cases.append(f'  <testcase classname="django-migrations" file={quoteattr(path)} name={quoteattr(path)}/>')
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            f'<testsuite name="{SUITE}" tests="{len(cases)}" failures="{len(errors)}">\n'
            + "\n".join(cases) + "\n</testsuite>\n")


def main(argv):
    model_changed = sorted({f for f in argv if is_model_or_migration(f) and Path(f).is_file()})
    results_dir = os.environ.get("ENACT_REPLAY_RESULTS")
    if not model_changed:
        if results_dir:
            Path(results_dir).mkdir(parents=True, exist_ok=True)
            (Path(results_dir) / f"{SUITE}.xml").write_text(junit([], {}))
        return 0

    cmd = [
        sys.executable,
        "showcase/scripts/backend_runtime.py",
        "exec",
        "uv",
        "run",
        "--no-sync",
        "python",
        "manage.py",
        "makemigrations",
        "--check",
        "--dry-run",
    ]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    if result.stdout:
        sys.stdout.write(result.stdout)

    errors = {}
    if result.returncode != 0:
        msg = "Models have changes that are not reflected in a migration file"
        for raw in result.stdout.splitlines():
            line = ANSI.sub("", raw).strip()
            if "Migrations for" in line or "Create model" in line or "Add field" in line or "Alter field" in line:
                msg = line
                break
        for f in model_changed:
            errors[f] = [f"{f}:1: error: {msg} [makemigrations]"]

    if results_dir:
        Path(results_dir).mkdir(parents=True, exist_ok=True)
        (Path(results_dir) / f"{SUITE}.xml").write_text(junit(model_changed, errors))

    return result.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
