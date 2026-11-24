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
    mkdir -p .venv/bin .venv/lib/site-packages
    : > .venv/pyvenv.cfg
    : > .venv/bin/python3
    if [ ! -e .venv/bin/pytest ]; then
        printf '#!%s/.venv/bin/python3\\nprint("pytest")\\n' "$PWD" > .venv/bin/pytest
        chmod +x .venv/bin/pytest
    fi
    chmod +x .venv/bin/python3
    printf '%s\\n' "$PWD" > .venv/lib/site-packages/_editable.pth
    echo sync >> "$STUB_LOG"
    case "$*" in
        *--compile-bytecode*) echo cold-sync >> "$STUB_LOG" ;;
        *) echo warm-sync >> "$STUB_LOG" ;;
    esac
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
        for name in ("run_sharded_pytest.sh", "run_sharded_pytest.py", "product_pytest.py", "exclusive.sh", "setup.sh"):
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

    def env(self) -> dict[str, str]:
        # Without the job's UV_CACHE_DIR: setup.sh would prune the caller's real venv cache, and
        # its cache key hashes a uv.lock this scratch repo lacks (the nightly's helper_tests).
        return {k: v for k, v in helper_env().items() if k != "UV_CACHE_DIR"}

    def shards(self, count: int, **env: str) -> list[subprocess.CompletedProcess]:
        base = {**self.env(), "STUB_LOG": str(self.log), "ENACT_SERVICES_ACTIVE": "0", **env}
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
        env = {**self.env(), "STUB_LOG": str(self.log), "FAIL_IMPORT": "1", "PATH": f"{self.repo / 'bin'}:{os.environ['PATH']}"}
        done = subprocess.run(
            ["bash", "showcase/scripts/setup.sh", "backend"], cwd=self.repo, env=env, capture_output=True, text=True
        )
        self.assertNotEqual(0, done.returncode, done.stdout + done.stderr)
        self.assertFalse((self.repo / ".venv/.replay-provisioned.json").exists())
        self.assertEqual(1, self.entries("sync"))

    def stage_checkout(self, target: Path) -> None:
        (target / "showcase/scripts").mkdir(parents=True, exist_ok=True)
        for name in ("setup.sh", "backend_runtime.py"):
            shutil.copy2(self.repo / "showcase/scripts" / name, target / "showcase/scripts" / name)
        (target / "uv.lock").write_text("lock\n")
        (target / "pyproject.toml").write_text("[project]\nname = 'x'\n")

    def test_uv_venv_cache_is_bounded_and_shared_across_ephemeral_proof_dirs(self) -> None:
        uv_cache = self.repo / "uv-cache"
        for idx, age in enumerate((300, 200, 100)):
            d = uv_cache / f"venv-v3-old{idx}"
            d.mkdir(parents=True)
            ts = 1_700_000_000 - age
            os.utime(d, (ts, ts))
        (self.repo / "uv.lock").write_text("lock\n")
        (self.repo / "pyproject.toml").write_text("[project]\nname = 'x'\n")
        env = {
            **self.env(),
            "UV_CACHE_DIR": str(uv_cache),
            "STUB_LOG": str(self.log),
            "PATH": f"{self.repo / 'bin'}:{os.environ['PATH']}",
        }
        done = subprocess.run(
            ["bash", "showcase/scripts/setup.sh", "backend"], cwd=self.repo, env=env, capture_output=True, text=True
        )
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)
        remaining = sorted(p.name for p in uv_cache.glob("venv-v3-*"))
        self.assertEqual(2, len(remaining), remaining)
        self.assertFalse((uv_cache / "venv-v3-old0").exists())
        self.assertFalse((uv_cache / "venv-v3-old1").exists())
        self.assertEqual(1, self.entries("cold-sync"))
        self.assertEqual(0, self.entries("warm-sync"))
        cached_dirs = [p for p in uv_cache.glob("venv-v3-*") if p.name != "venv-v3-old2"]
        self.assertEqual(1, len(cached_dirs), cached_dirs)
        cached_venv = cached_dirs[0]

        # (b) Running inside readiness-outputs/proof-abc123/runtime hits the cached venv-v3-<key>
        #     without creating a 3rd directory or mutating hardlinked files inside VENV_CACHE.
        ephemeral_a = self.repo / "readiness-outputs/proof-abc123/runtime"
        self.stage_checkout(ephemeral_a)
        before = set(uv_cache.glob("venv-v3-*"))
        done = subprocess.run(
            ["bash", "showcase/scripts/setup.sh", "backend"], cwd=ephemeral_a, env=env, capture_output=True, text=True
        )
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)
        self.assertEqual(before, set(uv_cache.glob("venv-v3-*")))
        self.assertEqual(1, self.entries("cold-sync"))
        self.assertEqual(1, self.entries("warm-sync"))
        self.assertEqual(f"{ephemeral_a}\n", (ephemeral_a / ".venv/lib/site-packages/_editable.pth").read_text())
        self.assertIn(str(ephemeral_a), (ephemeral_a / ".venv/bin/pytest").read_text())
        self.assertEqual(f"{self.repo}\n", (cached_venv / "lib/site-packages/_editable.pth").read_text())
        self.assertNotEqual(
            (ephemeral_a / ".venv/lib/site-packages/_editable.pth").stat().st_ino,
            (cached_venv / "lib/site-packages/_editable.pth").stat().st_ino,
        )
        self.assertNotEqual(
            (ephemeral_a / ".venv/bin/pytest").stat().st_ino,
            (cached_venv / "bin/pytest").stat().st_ino,
        )

        # (c) Starting from an empty uv_cache, proof-abc123 populates venv-v3-<key> and
        #     proof-def456 reuses it cleanly on warm restore.
        empty_cache = self.repo / "uv-cache-empty"
        self.log.unlink()
        env_empty = {**env, "UV_CACHE_DIR": str(empty_cache)}
        proof_1 = self.repo / "readiness-outputs/proof-cold1/runtime"
        proof_2 = self.repo / "readiness-outputs/proof-warm2/runtime"
        self.stage_checkout(proof_1)
        self.stage_checkout(proof_2)
        done1 = subprocess.run(
            ["bash", "showcase/scripts/setup.sh", "backend"], cwd=proof_1, env=env_empty, capture_output=True, text=True
        )
        self.assertEqual(0, done1.returncode, done1.stdout + done1.stderr)
        populated = list(empty_cache.glob("venv-v3-*"))
        self.assertEqual(1, len(populated), populated)
        self.assertEqual(1, self.entries("cold-sync"))
        self.assertEqual(0, self.entries("warm-sync"))

        done2 = subprocess.run(
            ["bash", "showcase/scripts/setup.sh", "backend"], cwd=proof_2, env=env_empty, capture_output=True, text=True
        )
        self.assertEqual(0, done2.returncode, done2.stdout + done2.stderr)
        self.assertEqual(populated, list(empty_cache.glob("venv-v3-*")))
        self.assertEqual(1, self.entries("cold-sync"))
        self.assertEqual(1, self.entries("warm-sync"))
        self.assertEqual(f"{proof_2}\n", (proof_2 / ".venv/lib/site-packages/_editable.pth").read_text())
        self.assertEqual(f"{proof_1}\n", (populated[0] / "lib/site-packages/_editable.pth").read_text())

        # (d) Hosted GitHub Actions without ENACT_HOST_CACHE must not populate venv-v3-* inside
        #     UV_CACHE_DIR (which gets archived into GitHub's 10 GiB L1 cache).
        hosted_cache = self.repo / "uv-cache-hosted"
        hosted_checkout = self.repo / "hosted-checkout"
        self.stage_checkout(hosted_checkout)
        env_hosted = {**env, "UV_CACHE_DIR": str(hosted_cache), "GITHUB_ACTIONS": "true"}
        env_hosted.pop("ENACT_HOST_CACHE", None)
        done_hosted = subprocess.run(
            ["bash", "showcase/scripts/setup.sh", "backend"],
            cwd=hosted_checkout,
            env=env_hosted,
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, done_hosted.returncode, done_hosted.stdout + done_hosted.stderr)
        self.assertEqual([], list(hosted_cache.glob("venv-v3-*")))
        self.assertFalse((hosted_cache / "work").exists())


if __name__ == "__main__":
    unittest.main()
