"""Regression tests for showcase/scripts/setup.sh backend venv caching and leasing."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SETUP_SH = Path(__file__).resolve().parents[1] / "setup.sh"


class SetupVenvTests(unittest.TestCase):
    def _make_fake_uv(self, bin_dir: Path, fail_first_sync: bool = False) -> Path:
        marker = bin_dir / "sync_calls.log"
        uv = bin_dir / "uv"
        fail_flag = "1" if fail_first_sync else "0"
        uv.write_text(
            f"""#!/usr/bin/env python3
import os, sys
from pathlib import Path

args = sys.argv[1:]
marker = Path({str(marker)!r})
calls = marker.read_text().splitlines() if marker.exists() else []
calls.append(" ".join(args))
marker.write_text("\\n".join(calls) + "\\n")

if args and args[0] == "venv":
    py = args[args.index("--python") + 1]
    dest = Path(args[-1])
    if dest.exists() and any(dest.iterdir()):
        sys.stderr.write("error: target venv dir is not empty\\n")
        sys.exit(2)
    (dest / "bin").mkdir(parents=True, exist_ok=True)
    os.symlink(py, dest / "bin" / "python")
    os.symlink(py, dest / "bin" / "python3")
    (dest / "pyvenv.cfg").write_text(f"home = {{Path(py).parent}}\\n")
    sys.exit(0)

if args and args[0] == "sync":
    venv = Path.cwd() / ".venv"
    if venv.exists() and not (venv / "bin" / "python").exists():
        sys.stderr.write(
            f"error: Project virtual environment directory `{{venv}}` cannot be used "
            "because it is not a valid Python environment (no Python executable was found)\\n"
        )
        sys.exit(2)
    if {fail_flag} and len([c for c in calls if c.startswith("sync")]) == 1:
        sys.exit(1)
    sys.exit(0)

if args and args[0] == "run":
    sys.exit(0)

sys.exit(0)
"""
        )
        uv.chmod(uv.stat().st_mode | stat.S_IXUSR)
        return marker

    def _run_setup_backend(
        self, repo: Path, uv_cache: Path, bin_dir: Path, extra_env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                "UV_CACHE_DIR": str(uv_cache),
                "GITHUB_ACTIONS": "true",
                "ENACT_HOST_CACHE": "/cache",
                "GHA_JOB_LEASE_ID": "test-worker-1",
            }
        )
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", str(repo / "showcase/scripts/setup.sh"), "backend"],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
        )

    def _init_repo(self, root: Path) -> Path:
        repo = root / "repo"
        (repo / "showcase/scripts").mkdir(parents=True)
        shutil.copy2(SETUP_SH, repo / "showcase/scripts/setup.sh")
        (repo / "showcase/scripts/backend_runtime.py").write_text("import sys; sys.exit(0)\n")
        (repo / "uv.lock").write_text("version = 1\n")
        (repo / "pyproject.toml").write_text("[project]\nname = 'demo'\n")
        (repo / "enve.lock").write_text("{}\n")
        return repo

    def test_cold_managed_ci_creates_venv_before_lease(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._init_repo(root)
            uv_cache = root / "uv-cache"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            self._make_fake_uv(bin_dir)

            res = self._run_setup_backend(repo, uv_cache, bin_dir)
            self.assertEqual(res.returncode, 0, res.stderr + res.stdout)
            venv = repo / ".venv"
            self.assertTrue(venv.is_symlink())
            self.assertTrue((venv / "bin/python").exists())
            self.assertEqual((venv / ".gha-job-lease").read_text().strip(), "container=test-worker-1")

    def test_warm_clone_relinks_interpreter_and_recovers_on_sync_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._init_repo(root)
            uv_cache = root / "uv-cache"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            # Seed a warm cache with a stale interpreter path, then fail first sync to prove cold fallback.
            self._make_fake_uv(bin_dir, fail_first_sync=False)
            first = self._run_setup_backend(repo, uv_cache, bin_dir)
            self.assertEqual(first.returncode, 0, first.stderr + first.stdout)

            # Corrupt the cached venv's python symlinks & pyvenv.cfg home to simulate a Nix store path change.
            cached_dirs = [p for p in uv_cache.glob("venv-*") if p.is_dir()]
            self.assertEqual(len(cached_dirs), 1)
            cached = cached_dirs[0]
            (cached / "bin/python").unlink()
            os.symlink("/nix/store/stale-python/bin/python3", cached / "bin/python")
            (cached / "pyvenv.cfg").write_text("home = /nix/store/stale-python/bin\n")

            (repo / ".venv").unlink()
            second = self._run_setup_backend(repo, uv_cache, bin_dir)
            self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
            py_home = str(Path(shutil.which("python3") or sys.executable).parent)
            self.assertIn(f"home = {py_home}", (repo / ".venv/pyvenv.cfg").read_text())

            # Now force warm sync failure and verify cold fallback succeeds with a valid leased venv.
            self._make_fake_uv(bin_dir, fail_first_sync=True)
            (repo / ".venv").unlink()
            third = self._run_setup_backend(repo, uv_cache, bin_dir)
            self.assertEqual(third.returncode, 0, third.stderr + third.stdout)
            self.assertTrue((repo / ".venv/bin/python").exists())
            self.assertTrue((repo / ".venv/.gha-job-lease").exists())

    def test_malformed_cache_dir_is_replaced_without_touching_active_work_lease(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._init_repo(root)
            uv_cache = root / "uv-cache"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            self._make_fake_uv(bin_dir)

            # Seed once to discover the exact cache key directory name, then replace it with a malformed dir.
            first = self._run_setup_backend(repo, uv_cache, bin_dir)
            self.assertEqual(first.returncode, 0, first.stderr + first.stdout)
            cached_dirs = [p for p in uv_cache.glob("venv-*") if p.is_dir()]
            self.assertEqual(len(cached_dirs), 1)
            cached = cached_dirs[0]
            shutil.rmtree(cached)
            cached.mkdir()
            (cached / "stale-junk").write_text("corrupt\n")

            # Place an active sibling lease under work/ and verify it is untouched.
            active_work = uv_cache / "work" / "venv.active"
            active_work.mkdir(parents=True, exist_ok=True)
            active_lease = active_work / ".gha-job-lease"
            active_lease.write_text("container=other-worker\n")

            (repo / ".venv").unlink()
            second = self._run_setup_backend(repo, uv_cache, bin_dir)
            self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
            self.assertTrue((cached / "pyvenv.cfg").is_file(), "cold install must replace malformed cache entry")
            self.assertFalse((cached / "stale-junk").exists())
            self.assertTrue(active_lease.is_file(), "active lease in work/ must not be deleted")

    def test_warm_failure_does_not_evict_concurrently_replaced_cache(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._init_repo(root)
            uv_cache = root / "uv-cache"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            self._make_fake_uv(bin_dir)

            # Seed initial cache entry.
            first = self._run_setup_backend(repo, uv_cache, bin_dir)
            self.assertEqual(first.returncode, 0, first.stderr + first.stdout)
            cached_dirs = [p for p in uv_cache.glob("venv-*") if p.is_dir()]
            self.assertEqual(len(cached_dirs), 1)
            cached = cached_dirs[0]

            # Build a fake uv that, on the first sync call, atomically replaces `cached` with a
            # fresh directory (different inode, carrying a sentinel) and fails the warm sync.
            uv = bin_dir / "uv"
            sentinel = "fresh-concurrent-replacement"
            uv.write_text(
                f"""#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path

args = sys.argv[1:]
cached = Path({str(cached)!r})
marker = Path({str(bin_dir / 'race.log')!r})
calls = marker.read_text().splitlines() if marker.exists() else []
calls.append(" ".join(args))
marker.write_text("\\n".join(calls) + "\\n")

if args and args[0] == "venv":
    py = args[args.index("--python") + 1]
    dest = Path(args[-1])
    (dest / "bin").mkdir(parents=True, exist_ok=True)
    os.symlink(py, dest / "bin" / "python")
    os.symlink(py, dest / "bin" / "python3")
    (dest / "pyvenv.cfg").write_text(f"home = {{Path(py).parent}}\\n")
    sys.exit(0)

if args and args[0] == "sync":
    if len([c for c in calls if c.startswith("sync")]) == 1:
        # Simulate another worker replacing the cache entry on a brand-new inode.
        fresh = cached.with_name(cached.name + ".fresh")
        shutil.copytree(cached, fresh, symlinks=True)
        (fresh / "sentinel.txt").write_text({sentinel!r})
        shutil.rmtree(cached)
        fresh.rename(cached)
        sys.exit(1)
    sys.exit(0)

sys.exit(0)
"""
            )
            uv.chmod(uv.stat().st_mode | stat.S_IXUSR)

            (repo / ".venv").unlink()
            second = self._run_setup_backend(repo, uv_cache, bin_dir)
            self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
            self.assertTrue((cached / "sentinel.txt").is_file(), "concurrently replaced valid cache must survive")
            self.assertEqual((cached / "sentinel.txt").read_text(), sentinel)

    def test_lock_inode_survives_venv_cache_pruning(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._init_repo(root)
            uv_cache = root / "uv-cache"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            self._make_fake_uv(bin_dir)

            # Seed extra older venv-v2-* directories so prune_venv_cache exercises retention.
            for idx in range(4):
                old = uv_cache / f"venv-v2-old-{idx}"
                old.mkdir(parents=True, exist_ok=True)
                (old / "pyvenv.cfg").write_text("home = /tmp\n")
                os.utime(old, (1000 + idx, 1000 + idx))

            first = self._run_setup_backend(repo, uv_cache, bin_dir)
            self.assertEqual(first.returncode, 0, first.stderr + first.stdout)
            lock_files = list((uv_cache / "locks").glob("*.lock"))
            self.assertEqual(len(lock_files), 1, "lock file must live under uv-cache/locks/")
            ino_before = lock_files[0].stat().st_ino
            # Ensure no lock files were placed directly under uv_cache matching venv-v2-*.
            self.assertEqual(list(uv_cache.glob("venv-*.lock")), [])

            # Run a second time with additional stale venv-v2-* entries to trigger pruning again.
            for idx in range(4, 7):
                old = uv_cache / f"venv-v2-old-{idx}"
                old.mkdir(parents=True, exist_ok=True)
                os.utime(old, (1000 + idx, 1000 + idx))
            (repo / ".venv").unlink()
            second = self._run_setup_backend(repo, uv_cache, bin_dir)
            self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
            self.assertTrue(lock_files[0].is_file())
            self.assertEqual(lock_files[0].stat().st_ino, ino_before, "pruning must not unlink the lock inode")

    def test_enact_uv_work_dir_isolates_work_venv_and_shares_cache(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._init_repo(root)
            uv_cache = root / "uv-cache"
            private_work = root / "proof-123" / "uv-work"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            self._make_fake_uv(bin_dir)

            # Cold run with ENACT_UV_WORK_DIR allocates work venv inside private_work
            # while publishing venv-v2-* into shared uv_cache.
            res = self._run_setup_backend(
                repo,
                uv_cache,
                bin_dir,
                extra_env={"ENACT_UV_WORK_DIR": str(private_work)},
            )
            self.assertEqual(res.returncode, 0, res.stderr + res.stdout)
            venv_target = (repo / ".venv").resolve()
            self.assertTrue(
                venv_target.is_relative_to(private_work.resolve()),
                f"expected .venv target under {private_work}, got {venv_target}",
            )
            self.assertFalse(
                (uv_cache / "work").exists(),
                "shared uv_cache/work must not be used when ENACT_UV_WORK_DIR is set",
            )
            published = list(uv_cache.glob("venv-v2-*"))
            self.assertEqual(len(published), 1, "venv-v2-* must still be published to shared UV_CACHE_DIR")

            # Warm run clones from shared venv-v2-* into a fresh dir under private_work.
            (repo / ".venv").unlink()
            res2 = self._run_setup_backend(
                repo,
                uv_cache,
                bin_dir,
                extra_env={"ENACT_UV_WORK_DIR": str(private_work)},
            )
            self.assertEqual(res2.returncode, 0, res2.stderr + res2.stdout)
            venv_target2 = (repo / ".venv").resolve()
            self.assertTrue(venv_target2.is_relative_to(private_work.resolve()))
            self.assertNotEqual(venv_target2, venv_target)


if __name__ == "__main__":
    unittest.main()
