#!/usr/bin/env python3
"""Run enact's newline-delimited repository-relative targets through frontend Jest."""
import os
from pathlib import Path
import sys


def command(argv):
    root = Path(__file__).resolve().parents[2]
    if len(argv) != 1:
        raise ValueError("usage: run_jest.py <targets_file>")
    targets = []
    for line in Path(argv[0]).read_text().splitlines():
        if not line:
            continue
        path = (root / line).resolve()
        if Path(line).is_absolute() or not path.is_relative_to(root) or not path.is_file():
            raise ValueError(f"missing or invalid Jest target: {line}")
        if str(path) not in targets:
            targets.append(str(path))
    if not targets:
        raise ValueError("Jest target list is empty; refusing an unscoped run")
    if not (root / "frontend/node_modules/.bin/jest").is_file():
        raise ValueError("Jest dependencies are missing. Run `just setup frontend` in this checkout (or `just provision <workspace_name>` from tests/replay).")
    return ["pnpm", "--filter=@posthog/frontend", "exec", "jest", "--forceExit", "--maxWorkers=2", "--runTestsByPath", *targets]


if __name__ == "__main__":
    try:
        args = command(sys.argv[1:])
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(78)
    os.execvp(args[0], args)
