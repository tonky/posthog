"""A local run's shards install nothing into the backend runtime.

`enact run base:test` starts four shards of run_sharded_pytest.sh in one checkout. Each used
to find no .venv and run `setup.sh backend`: four installs into one venv (`Failed to install:
flameprof`, ruff `failed to copy`) and four GeoLite2 downloads (`File exists`). The venv is now
enact's prepare phase's (ci.cue's toolchain.python.install, once before any shard); the
GeoIP download stays the shards' own, under exclusive.sh. Here uv and bin/download-mmdb are
stubs that fail as those did when two of them overlap; the shards run side by side.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hermetic import helper_env  # noqa: E402

SCRIPTS = Path(__file__).resolve().parents[1]

# uv sync: fails like the colliding installs when another sync is running, else makes the venv.
# uv run --no-sync [--directory <dir>] <command...>: the import check, or a shard's pytest.
UV_STUB = """#!/usr/bin/env bash
case "$1" in
sync)
    mkdir "$STUB_LOG.syncing" 2>/dev/null || { echo "Failed to install: flameprof-0.4" >&2; exit 2; }
    sleep 0.5
    mkdir -p .venv && : > .venv/pyvenv.cfg
    echo sync >> "$STUB_LOG"
    rmdir "$STUB_LOG.syncing"
    ;;
run)
    # setup.sh's check that grpc's native module loads.
    case "$*" in *"import grpc"*) [ -z "${FAIL_IMPORT:-}" ] || exit 4 ;; esac
    echo "run $*" >> "$STUB_LOG"
    ;;
esac
"""

# backend_runtime.py: the stamp is the provisioning, as the real one's record and check.
RUNTIME_STUB = """import os, sys
from pathlib import Path
stamp = Path(".venv/.replay-provisioned.json")
if sys.argv[1] == "record":
    stamp.write_text("{}")
elif sys.argv[1] == "check":
    sys.exit(0 if stamp.is_file() and Path(".venv/pyvenv.cfg").is_file() else 78)
else:
    os.execvp(sys.argv[2], sys.argv[2:])
"""

# bin/download-mmdb: looks, then writes without clobbering, as brotli --output does.
MMDB_STUB = """#!/usr/bin/env bash
set -euo pipefail
mkdir -p share
if [ ! -f share/GeoLite2-City.mmdb ]; then
    sleep 0.3
    set -o noclobber
    echo db > share/GeoLite2-City.mmdb
    echo download >> "$STUB_LOG"
fi
"""


@unittest.skipUnless(all(map(shutil.which, ("bash", "rg", "flock"))), "needs bash, rg and flock")
class ShardProvisioningTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name).resolve()
        scripts = self.repo / "showcase/scripts"
        scripts.mkdir(parents=True)
        for name in ("run_sharded_pytest.sh", "product_pytest.py", "exclusive.sh", "setup.sh"):
            shutil.copy2(SCRIPTS / name, scripts / name)
        (scripts / "backend_runtime.py").write_text(RUNTIME_STUB)
        self.write("bin/uv", UV_STUB)
        self.write("bin/download-mmdb", MMDB_STUB)
        self.log = self.repo / "stub.log"

    def write(self, name: str, text: str) -> None:
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def shards(self, count: int, **env: str) -> list[subprocess.CompletedProcess]:
        base = {**helper_env(), "STUB_LOG": str(self.log), "ENACT_SERVICES_ACTIVE": "0", **env}
        running = [
            subprocess.Popen(
                ["bash", "showcase/scripts/run_sharded_pytest.sh", f"posthog/test/test_{i}.py"],
                cwd=self.repo,
                env={**base, "ENACT_SHARD_INDEX": str(i)},
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            for i in range(1, count + 1)
        ]
        return [subprocess.CompletedProcess(p.args, p.wait(), p.communicate()[0]) for p in running]

    def entries(self, kind: str) -> int:
        return self.log.read_text().split().count(kind) if self.log.exists() else 0

    def test_side_by_side_shards_install_nothing_and_download_once(self) -> None:
        for shard in self.shards(4):
            self.assertEqual(0, shard.returncode, shard.stdout)
        self.assertEqual(0, self.entries("sync"))
        self.assertEqual(1, self.entries("download"))
        # Every shard ran its pytest afterwards.
        self.assertEqual(4, sum("pytest" in line for line in self.log.read_text().splitlines()))

    def test_a_failed_setup_leaves_no_stamp(self) -> None:
        # The prepare phase's install: its sync works, its grpc check fails, so the runtime
        # is broken, unstamped, and the install fails (no fallback `uv sync` + record).
        env = {**helper_env(), "STUB_LOG": str(self.log), "FAIL_IMPORT": "1", "PATH": f"{self.repo / 'bin'}:{os.environ['PATH']}"}
        done = subprocess.run(
            ["bash", "showcase/scripts/setup.sh", "backend"], cwd=self.repo, env=env, capture_output=True, text=True
        )
        self.assertNotEqual(0, done.returncode, done.stdout + done.stderr)
        self.assertFalse((self.repo / ".venv/.replay-provisioned.json").exists())
        self.assertEqual(1, self.entries("sync"))

if __name__ == "__main__":
    unittest.main()
