"""Check complete v3 publications before transport; delegates to `enact helper pg-template verify`."""

import os
import shutil
import subprocess
import sys
from pathlib import Path


def _unchanged_since_restore(snapshot_dir: Path) -> bool:
    if os.environ.get("GITHUB_EVENT_NAME") == "schedule":
        return False
    runner_temp = os.environ.get("RUNNER_TEMP")
    if not runner_temp:
        return False
    restored_file = Path(runner_temp) / "enact-cache-delta" / "cache_backend_templates.restored"
    if not restored_file.is_file():
        return False
    before = {line.strip() for line in restored_file.read_text(encoding="utf-8").splitlines() if line.strip()}
    if not before or not snapshot_dir.is_dir():
        return False
    resolved = snapshot_dir.resolve()
    for dirpath, dirnames, filenames in os.walk(snapshot_dir):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        rel_dir = Path(dirpath).relative_to(snapshot_dir)
        for fname in filenames:
            if fname.startswith(".") or fname.endswith(".lock"):
                continue
            rel = (rel_dir / fname).as_posix() if rel_dir != Path(".") else fname
            if before.isdisjoint({f"{snapshot_dir.as_posix()}/{rel}", f"{resolved.as_posix()}/{rel}", rel}):
                return False
    return True


def main() -> int:
    enact = os.environ.get("ENACT_EXE") or os.environ.get("ENACT_BIN") or shutil.which("enact") or "enact"
    github_output = os.environ.get("GITHUB_OUTPUT")
    if len(sys.argv) >= 2 and github_output and _unchanged_since_restore(Path(sys.argv[1])):
        res = subprocess.run(
            [enact, "helper", "pg-template", "verify", *sys.argv[1:]],
            env={k: v for k, v in os.environ.items() if k != "GITHUB_OUTPUT"},
            check=False,
        )
        with open(github_output, "a", encoding="utf-8") as out:
            out.write("eligible=false\n")
        return res.returncode
    os.execv(enact, [enact, "helper", "pg-template", "verify", *sys.argv[1:]])


if __name__ == "__main__":
    sys.exit(main())
