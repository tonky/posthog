"""Concurrency regression tests for the B4a per-key publish.lock / flock -s split.

Drives the real `test_databases.sh` + `template_lock.sh` with real util-linux
`flock` across independent worker subshells (each with its own `$TEST_DB_LOCK`,
modeling concurrent JIT runners / detached worktrees sharing `$SNAPSHOT_ROOT`).

Proves:
1. Two concurrent warm readers on the same key acquire `flock -s` simultaneously
   and overlap inside `restore_from_snapshots` (no warm-warm serialization).
2. A cold writer holding `flock -x` on per-key `publish.lock` excludes a racing
   cold writer on the same key (double-check prevents duplicate cold build), and
   a waiting reader sees the complete atomically published directory.
3. Two different snapshot keys (cold vs. warm and cold vs. cold) use distinct
   per-key `publish.lock` files and never block each other.
4. Per-key locks live under `$SNAPSHOT_ROOT/locks/v3/<key>/publish.lock`
   (keeping `$SNAPSHOT_ROOT/v3/` clean for `enact helper pg-template verify`),
   and every `test_databases.sh` caller sources `template_lock.sh` after it.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
TEST_DATABASES_SH = SCRIPTS / "test_databases.sh"
TEMPLATE_LOCK_SH = SCRIPTS / "template_lock.sh"

KEY_A = "a" * 64
KEY_B = "b" * 64
KEY_C = "c" * 64


def _publish_fixture_snapshot(snapshot_root: Path, key: str, gen: str = "v3.init0001") -> Path:
    gen_dir = snapshot_root / "v3" / key / gen
    gen_dir.mkdir(parents=True, exist_ok=True)
    for fname in ("manifest", "postgres.dump", "persons.dump", "migrations.json"):
        (gen_dir / fname).write_text(f"{key}:{gen}:{fname}\n", encoding="utf-8")
    (snapshot_root / "v3" / key / "current-v3").write_text(f"{gen}\n", encoding="utf-8")
    return gen_dir


def _wait_for(path: Path, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() > deadline:
            raise TimeoutError(f"Timed out waiting for {path}")
        time.sleep(0.02)


@unittest.skipUnless(shutil.which("flock"), "requires util-linux flock (run inside enve)")
class TemplateLockSplitTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.snapshots = self.base / "snapshots"
        self.snapshots.mkdir()
        self.sync_dir = self.base / "sync"
        self.sync_dir.mkdir()

    def _spawn_worker(
        self,
        name: str,
        key: str,
        body: str,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.Popen[str]:
        worker_lock = self.base / "worker-locks" / f"{name}.lock"
        env = {
            **os.environ,
            "ENACT_TEMPLATE_SNAPSHOT_DIR": str(self.snapshots),
            "ENACT_TEST_DB_LOCK": str(worker_lock),
            "TEST_DATABASES_SH": str(TEST_DATABASES_SH),
            "TEMPLATE_LOCK_SH": str(TEMPLATE_LOCK_SH),
            "SYNC_DIR": str(self.sync_dir),
            "WORKER_NAME": name,
            "TEST_KEY": key,
        }
        if extra_env:
            env.update(extra_env)
        script = f"""
set -euo pipefail
source "$TEST_DATABASES_SH"
source "$TEMPLATE_LOCK_SH"

# Stub Postgres/sqlx helpers so only the real lock + snapshot-store state machine runs.
current_template_key() {{ echo "$TEST_KEY"; }}
template_ready() {{ return 1; }}
sync_sqlx_migrations() {{ return 0; }}
wait_templates_free() {{ return 0; }}

{body}

with_templates true
"""
        return subprocess.Popen(
            ["bash", "-c", script],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def _finish(self, proc: subprocess.Popen[str], timeout: float = 10.0) -> tuple[int, str, str]:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out, err

    def test_two_concurrent_warm_readers_overlap_with_shared_lock(self) -> None:
        _publish_fixture_snapshot(self.snapshots, KEY_A)

        # Each reader signals entry and waits for the OTHER reader to enter before
        # exiting restore_from_snapshots. Under an exclusive lock this deadlocks;
        # under flock -s both enter concurrently and succeed immediately.
        reader_body = r"""
restore_from_snapshots() {
    local other="$OTHER_NAME"
    local key_lock
    key_lock=$(template_key_lock_path)
    # While we hold flock -s, an exclusive non-blocking lock on publish.lock must fail.
    if flock -x -n "$key_lock" true 2>/dev/null; then
        echo "ERROR: exclusive lock succeeded while shared lock should be held" >&2
        return 1
    fi
    touch "$SYNC_DIR/${WORKER_NAME}.entered"
    local deadline=$((SECONDS + 5))
    while [ ! -f "$SYNC_DIR/${other}.entered" ]; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "ERROR: ${WORKER_NAME} timed out waiting for ${other} to overlap under flock -s" >&2
            return 1
        fi
        sleep 0.02
    done
    [ -f "$SNAPSHOT_DIR/current-v3" ] || return 1
    touch "$SYNC_DIR/${WORKER_NAME}.restored"
}
"""
        p1 = self._spawn_worker("r1", KEY_A, reader_body, {"OTHER_NAME": "r2"})
        p2 = self._spawn_worker("r2", KEY_A, reader_body, {"OTHER_NAME": "r1"})

        rc1, out1, err1 = self._finish(p1)
        rc2, out2, err2 = self._finish(p2)
        self.assertEqual(0, rc1, f"r1 failed: out={out1!r} err={err1!r}")
        self.assertEqual(0, rc2, f"r2 failed: out={out2!r} err={err2!r}")
        self.assertTrue((self.sync_dir / "r1.restored").is_file())
        self.assertTrue((self.sync_dir / "r2.restored").is_file())

        # Per-key lock file lives under locks/v3/<key>/publish.lock, outside v3/.
        expected_lock = self.snapshots / "locks" / "v3" / KEY_A / "publish.lock"
        self.assertTrue(expected_lock.is_file())
        self.assertEqual(
            {"current-v3", "v3.init0001"},
            {p.name for p in (self.snapshots / "v3" / KEY_A).iterdir()},
        )

    def test_cold_writer_excludes_racing_writer_and_reader_sees_complete_publish(self) -> None:
        # Producer 1 enters bootstrap_templates under flock -x on KEY_B's publish.lock,
        # waits until Producer 2 and Reader 3 are contending, then atomically publishes.
        # Producer 2 must double-check after acquiring flock -x and restore instead of
        # re-running bootstrap_templates; Reader 3 must wait and see the complete publish.
        producer1_body = r"""
bootstrap_templates() {
    local key_lock
    key_lock=$(template_key_lock_path)
    # Under flock -x, neither a shared nor exclusive non-blocking lock can succeed.
    if flock -s -n "$key_lock" true 2>/dev/null; then
        echo "ERROR: shared lock succeeded while cold writer held flock -x" >&2
        return 1
    fi
    printf '%s\n' "$WORKER_NAME" >> "$SYNC_DIR/bootstraps.log"
    touch "$SYNC_DIR/p1.in_bootstrap"

    local deadline=$((SECONDS + 5))
    while [ ! -f "$SYNC_DIR/release_p1" ]; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "ERROR: p1 timed out waiting for release_p1" >&2
            return 1
        fi
        sleep 0.02
    done

    # Stage generation directory and atomically rename pointer, matching dump_snapshots.
    local gen="v3.cold0001"
    local gen_dir="$SNAPSHOT_DIR/$gen"
    mkdir -p "$gen_dir"
    printf 'enact-test-template-v3:%s pg17\n' "$TEMPLATE_KEY" > "$gen_dir/manifest"
    printf 'pg-bytes\n' > "$gen_dir/postgres.dump"
    printf 'persons-bytes\n' > "$gen_dir/persons.dump"
    printf '{"django":[]}\n' > "$gen_dir/migrations.json"
    local pointer="$SNAPSHOT_DIR/$gen.pointer"
    printf '%s\n' "$gen" > "$pointer"
    mv "$pointer" "$SNAPSHOT_DIR/current-v3"
    touch "$SYNC_DIR/p1.published"
}
restore_from_snapshots() {
    echo "ERROR: p1 should have bootstrapped, not restored" >&2
    return 1
}
"""
        contender_body = r"""
bootstrap_templates() {
    printf '%s\n' "$WORKER_NAME" >> "$SYNC_DIR/bootstraps.log"
    echo "ERROR: ${WORKER_NAME} duplicated cold bootstrap instead of restoring published key" >&2
    return 1
}
restore_from_snapshots() {
    local gen
    gen=$(cat "$SNAPSHOT_DIR/current-v3")
    if [ "$gen" != "v3.cold0001" ]; then
        echo "ERROR: ${WORKER_NAME} saw unexpected generation: $gen" >&2
        return 1
    fi
    for f in manifest postgres.dump persons.dump migrations.json; do
        if [ ! -s "$SNAPSHOT_DIR/$gen/$f" ]; then
            echo "ERROR: ${WORKER_NAME} saw incomplete file $f in $gen" >&2
            return 1
        fi
    done
    printf '%s:%s\n' "$WORKER_NAME" "$gen" >> "$SYNC_DIR/restores.log"
}
"""
        p1 = self._spawn_worker("p1", KEY_B, producer1_body)
        _wait_for(self.sync_dir / "p1.in_bootstrap")

        # Launch racing cold writer (p2) and waiting reader (r3) while p1 holds flock -x.
        p2 = self._spawn_worker("p2", KEY_B, contender_body)
        r3 = self._spawn_worker("r3", KEY_B, contender_body)

        # Give p2 and r3 time to reach publish.lock and prove neither proceeds prematurely.
        time.sleep(0.25)
        self.assertIsNone(p2.poll(), "p2 exited before p1 finished publishing")
        self.assertIsNone(r3.poll(), "r3 exited before p1 finished publishing")
        self.assertFalse((self.sync_dir / "restores.log").exists())

        # Release p1 so it completes atomic publish and releases flock -x.
        (self.sync_dir / "release_p1").write_text("go\n", encoding="utf-8")

        for label, proc in (("p1", p1), ("p2", p2), ("r3", r3)):
            rc, out, err = self._finish(proc)
            self.assertEqual(0, rc, f"{label} failed: out={out!r} err={err!r}")

        bootstraps = (self.sync_dir / "bootstraps.log").read_text(encoding="utf-8").splitlines()
        restores = sorted((self.sync_dir / "restores.log").read_text(encoding="utf-8").splitlines())
        self.assertEqual(["p1"], bootstraps)
        self.assertEqual(["p2:v3.cold0001", "r3:v3.cold0001"], restores)
        self.assertEqual(
            {"current-v3", "v3.cold0001"},
            {p.name for p in (self.snapshots / "v3" / KEY_B).iterdir()},
        )

    def test_different_snapshot_keys_do_not_block_each_other(self) -> None:
        # KEY_B is pre-published (warm); KEY_A and KEY_C are cold.
        _publish_fixture_snapshot(self.snapshots, KEY_B)

        # Producer A holds flock -x on KEY_A's publish.lock and refuses to exit until
        # BOTH warm reader B (on KEY_B) AND cold producer C (on KEY_C) complete.
        producer_a_body = r"""
bootstrap_templates() {
    touch "$SYNC_DIR/ka.in_bootstrap"
    local deadline=$((SECONDS + 5))
    while [ ! -f "$SYNC_DIR/kb.done" ] || [ ! -f "$SYNC_DIR/kc.done" ]; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "ERROR: key A timed out waiting for independent keys B and C" >&2
            return 1
        fi
        sleep 0.02
    done
    mkdir -p "$SNAPSHOT_DIR/v3.keya0001"
    printf 'v3.keya0001\n' > "$SNAPSHOT_DIR/current-v3"
    touch "$SYNC_DIR/ka.done"
}
"""
        warm_b_body = r"""
restore_from_snapshots() {
    [ -f "$SNAPSHOT_DIR/current-v3" ] || return 1
    touch "$SYNC_DIR/kb.done"
}
"""
        cold_c_body = r"""
bootstrap_templates() {
    mkdir -p "$SNAPSHOT_DIR/v3.keyc0001"
    printf 'v3.keyc0001\n' > "$SNAPSHOT_DIR/current-v3"
    touch "$SYNC_DIR/kc.done"
}
"""
        pa = self._spawn_worker("pa", KEY_A, producer_a_body)
        _wait_for(self.sync_dir / "ka.in_bootstrap")

        pb = self._spawn_worker("pb", KEY_B, warm_b_body)
        pc = self._spawn_worker("pc", KEY_C, cold_c_body)

        for label, proc in (("pb", pb), ("pc", pc), ("pa", pa)):
            rc, out, err = self._finish(proc)
            self.assertEqual(0, rc, f"{label} failed: out={out!r} err={err!r}")

        self.assertTrue((self.sync_dir / "ka.done").is_file())
        self.assertTrue((self.sync_dir / "kb.done").is_file())
        self.assertTrue((self.sync_dir / "kc.done").is_file())

    def test_all_test_databases_callers_source_template_lock_after_test_databases(self) -> None:
        callers = []
        for path in sorted(SCRIPTS.glob("*.sh")):
            if path.name in ("test_databases.sh", "snapshot_root.sh", "template_lock.sh"):
                continue
            text = path.read_text(encoding="utf-8")
            db_match = re.search(r"^\s*source\s+.*test_databases\.sh\b", text, re.MULTILINE)
            if not db_match:
                continue
            callers.append(path.name)
            lock_match = re.search(r"^\s*source\s+.*template_lock\.sh\b", text, re.MULTILINE)
            self.assertIsNotNone(lock_match, f"{path.name} sources test_databases.sh without template_lock.sh")
            self.assertGreater(
                lock_match.start(),
                db_match.start(),
                f"{path.name} must source template_lock.sh after test_databases.sh",
            )
        self.assertGreaterEqual(len(callers), 8, f"expected >= 8 test_databases.sh callers, found {callers}")


if __name__ == "__main__":
    unittest.main()
