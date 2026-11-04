#!/usr/bin/env python3
"""Record a PostHog Rust test job's per-binary reach footprint via `enact trace cargo-footprint`."""

from __future__ import annotations

import os
import shutil
import sys


def main() -> None:
    enact = os.environ.get("ENACT_EXE") or os.environ.get("ENACT_BIN") or shutil.which("enact")
    if not enact:
        raise SystemExit("enact binary not found on PATH (or ENACT_EXE / ENACT_BIN)")
    os.execv(enact, [enact, "trace", "cargo-footprint", *sys.argv[1:]])


if __name__ == "__main__":
    main()
