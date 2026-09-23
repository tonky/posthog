#!/usr/bin/env python3
"""Keep per-shard execution read-only with respect to the provisioned environment."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

STAMP = Path(".venv/.replay-provisioned.json")

def fingerprint():
    # Include local workspace metadata, including new untracked manifests, but
    # not installed dependencies. Sparse paths absent from this archive are ignored.
    paths = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "uv.lock", "pyproject.toml", "**/pyproject.toml"]).decode().split("\0")
    inputs = sorted({p for p in paths if p and Path(p).is_file()})
    for required in ("uv.lock", "pyproject.toml", ".venv/pyvenv.cfg"):
        if not Path(required).is_file():
            raise ValueError(f"missing {required}")
    digest = hashlib.sha256()
    for name in sorted(set(inputs + [".venv/pyvenv.cfg"])):
        digest.update(name.encode() + b"\0" + Path(name).read_bytes() + b"\0")
    return {"schema": 1, "inputs": digest.hexdigest(), "python": str(Path(".venv/bin/python").resolve(strict=True))}

def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action not in {"record", "check", "exec"}:
        raise ValueError("usage: backend_runtime.py record|check|exec <command>...")
    current = fingerprint()
    if action == "record":
        temporary = STAMP.with_suffix(".tmp")
        temporary.write_text(json.dumps(current) + "\n")
        temporary.replace(STAMP)
        return
    if not STAMP.is_file() or json.loads(STAMP.read_text()) != current:
        raise ValueError("Python provisioning is missing or stale")
    if action == "exec":
        if len(sys.argv) < 3:
            raise ValueError("exec requires a command")
        os.environ["ENACT_PYTEST_STARTED_NS"] = str(time.time_ns())
        os.execvp(sys.argv[2], sys.argv[2:])

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        workspace = os.environ.get("ENACT_REPLAY_WORKSPACE", "<workspace_name>")
        print(f"Replay backend: {error}. From tests/replay run: just provision {workspace}", file=sys.stderr)
        raise SystemExit(78)
