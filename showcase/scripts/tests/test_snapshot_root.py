"""Host-cache snapshot root wiring (`snapshot_root.sh`) outside `test_databases.sh`.

Proves:
1. `test_databases.sh`'s computed `v3` template key is byte-identical with and
   without `ENACT_TEMPLATE_SNAPSHOT_DIR` / `ENACT_HOST_CACHE` wiring.
2. Exact resolved paths for all three namespaces (`v3`, `live-v1`, `ch-v1`) under:
   - managed self-hosted (`ENACT_HOST_CACHE` set with writable `repo/`)
   - hosted GitHub Actions / local dev (`ENACT_HOST_CACHE` unset)
   - non-writable or missing `$ENACT_HOST_CACHE/repo` (safe fallback)
   - explicit `ENACT_TEMPLATE_SNAPSHOT_DIR` override
3. `live_posthog.sh` honors `ENACT_TEMPLATE_SNAPSHOT_DIR` / `ENACT_HOST_CACHE`
   consistently both after `test_databases.sh` and when sourced standalone.
4. Every runner script sourcing `test_databases.sh` sources `snapshot_root.sh`
   first, and `.enact/ci.cue`'s hosted cache paths align with all three
   namespaces.
"""

from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hermetic import helper_env

SCRIPTS = Path(__file__).resolve().parents[1]
OVERLAY = SCRIPTS.parents[1]
SNAPSHOT_ROOT_SH = SCRIPTS / "snapshot_root.sh"
TEST_DATABASES_SH = SCRIPTS / "test_databases.sh"
LIVE_POSTHOG_SH = SCRIPTS / "live_posthog.sh"

ENVE_CUE = """profiles: dev: {
\tenvironment: {
\t\tDATABASE_URL: "postgres://posthog:posthog@127.0.0.1:${ENVE_SERVICE_POSTGRES_PORT}/posthog"
\t\tPGPORT: "${ENVE_SERVICE_POSTGRES_PORT}"
\t\tPGUSER: "posthog"
\t\tTZ: "UTC"
\t}
\tservices: postgres: {
\t\tcommand: "postgres -D \\"$DATA_DIR\\" -c max_connections=1000"
\t\tlifecycle: init: ["initdb -D \\"$DATA_DIR\\" --locale=C.UTF-8"]
\t}
}
"""


def _init_fixture_repo(root: Path) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    (root / "enve.cue").write_text(ENVE_CUE, encoding="utf-8")
    (root / "posthog/migrations").mkdir(parents=True, exist_ok=True)
    (root / "posthog/migrations/0001_initial.py").write_text("operations = []\n", encoding="utf-8")
    (root / "products").mkdir(parents=True, exist_ok=True)
    (root / "products/db_routing.yaml").write_text("routes: []\n", encoding="utf-8")
    (root / "rust/persons_migrations").mkdir(parents=True, exist_ok=True)
    (root / "rust/persons_migrations/20240101_init.sql").write_text("SELECT 1;\n", encoding="utf-8")

    # Copy the real scripts into the fixture repo so `pg_template`'s --schema-file
    # inputs hash the exact tracked test_databases.sh and template_inputs.py.
    scripts_dir = root / "showcase/scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)
    for name in ("snapshot_root.sh", "test_databases.sh", "live_posthog.sh", "live_posthog.py", "template_inputs.py"):
        dst = scripts_dir / name
        dst.write_bytes((SCRIPTS / name).read_bytes())
        dst.chmod(0o755)

    bin_dir = root / ".test-bin"
    bin_dir.mkdir(exist_ok=True)
    sqlx = bin_dir / "sqlx"
    sqlx.write_text("#!/bin/sh\necho 'sqlx-cli 0.8.6'\n", encoding="utf-8")
    sqlx.chmod(0o755)
    psql = bin_dir / "psql"
    psql.write_text("#!/bin/sh\necho '150013'\n", encoding="utf-8")
    psql.chmod(0o755)
    (root / ".gitignore").write_text(".test-bin/\n", encoding="utf-8")

    subprocess.run(["git", "add", "."], cwd=root, check=True)
    return bin_dir


class SnapshotRootWiringTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.repo = self.base / "repo"
        self.bin_dir = _init_fixture_repo(self.repo)
        self.fake_home = self.base / "home"
        self.fake_home.mkdir()
        self.host_cache = self.base / "host-cache"
        (self.host_cache / "repo").mkdir(parents=True)

    def _base_env(self) -> dict[str, str]:
        env = helper_env()
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["HOME"] = str(self.fake_home)
        env["PGHOST"] = "127.0.0.1"
        env["PGPORT"] = "54011"
        env["PGUSER"] = "posthog"
        env["TZ"] = "UTC"
        env["DATABASE_URL"] = "postgres://posthog:posthog@127.0.0.1:54011/posthog"
        env.pop("ENACT_HOST_CACHE", None)
        env.pop("ENACT_TEMPLATE_SNAPSHOT_DIR", None)
        env.pop("SNAPSHOT_ROOT", None)
        return env

    def _probe(self, script: str, extra_env: dict[str, str] | None = None) -> dict[str, str]:
        env = self._base_env()
        if extra_env:
            env.update(extra_env)
        done = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", script],
            cwd=self.repo,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, done.returncode, f"stdout={done.stdout}\nstderr={done.stderr}")
        return json.loads(done.stdout)

    def test_template_key_is_byte_identical_with_and_without_snapshot_root_wiring(self) -> None:
        probe_without_wiring = r"""
source showcase/scripts/test_databases.sh
configure_template_cache
python3 -c 'import json, os; print(json.dumps({
    "key": os.environ["K"],
    "snapshot_root": os.environ["SR"],
    "v3_dir": os.environ["SD"],
}))'
"""
        probe_with_wiring = r"""
source showcase/scripts/snapshot_root.sh
source showcase/scripts/test_databases.sh
configure_template_cache
K="$TEMPLATE_KEY" SR="$SNAPSHOT_ROOT" SD="$SNAPSHOT_DIR" \
python3 -c 'import json, os; print(json.dumps({
    "key": os.environ["K"],
    "snapshot_root": os.environ["SR"],
    "v3_dir": os.environ["SD"],
}))'
"""
        baseline = self._probe(
            """
source showcase/scripts/test_databases.sh
configure_template_cache
K="$TEMPLATE_KEY" SR="$SNAPSHOT_ROOT" SD="$SNAPSHOT_DIR" \
python3 -c 'import json, os; print(json.dumps({
    "key": os.environ["K"],
    "snapshot_root": os.environ["SR"],
    "v3_dir": os.environ["SD"],
}))'
"""
        )
        managed = self._probe(
            probe_with_wiring,
            {"ENACT_HOST_CACHE": str(self.host_cache)},
        )
        explicit = self._probe(
            probe_with_wiring,
            {
                "ENACT_HOST_CACHE": str(self.host_cache),
                "ENACT_TEMPLATE_SNAPSHOT_DIR": str(self.base / "explicit-root"),
            },
        )
        hosted = self._probe(probe_with_wiring)

        self.assertRegex(baseline["key"], r"^[a-f0-9]{64}$")
        self.assertEqual(baseline["key"], hosted["key"])
        self.assertEqual(baseline["key"], managed["key"])
        self.assertEqual(baseline["key"], explicit["key"])

    def test_all_three_namespaces_resolve_for_managed_hosted_and_explicit(self) -> None:
        probe_all = r"""
source showcase/scripts/snapshot_root.sh
source showcase/scripts/test_databases.sh
source showcase/scripts/live_posthog.sh
configure_template_cache
python3 - "$ENACT_TEMPLATE_SNAPSHOT_DIR" "$SNAPSHOT_ROOT" "$SNAPSHOT_DIR" "$COLD_BUILD_SECONDS_FILE" "$TEMPLATE_KEY" <<'PY'
import json, sys
env_dir, root, v3_dir, cold_file, key = sys.argv[1:]
print(json.dumps({
    "env_dir": env_dir,
    "snapshot_root": root,
    "v3_dir": v3_dir,
    "cold_file": cold_file,
    "live_v1": f"{root}/live-v1",
    "ch_v1": f"{root}/ch-v1",
    "key": key,
}))
PY
"""
        # 1. Managed self-hosted runner (writable $ENACT_HOST_CACHE/repo, trailing slash normalized).
        managed = self._probe(probe_all, {"ENACT_HOST_CACHE": f"{self.host_cache}/"})
        expected_managed = f"{self.host_cache}/repo/pg-templates"
        self.assertEqual(expected_managed, managed["env_dir"])
        self.assertEqual(expected_managed, managed["snapshot_root"])
        self.assertEqual(f"{expected_managed}/v3/{managed['key']}", managed["v3_dir"])
        self.assertEqual(f"{expected_managed}/v3/cold-build-seconds", managed["cold_file"])
        self.assertEqual(f"{expected_managed}/live-v1", managed["live_v1"])
        self.assertEqual(f"{expected_managed}/ch-v1", managed["ch_v1"])

        # 2. Hosted GitHub Actions / local dev (ENACT_HOST_CACHE unset).
        hosted = self._probe(probe_all)
        expected_hosted = f"{self.fake_home}/.cache/enact/snapshots"
        self.assertEqual(expected_hosted, hosted["env_dir"])
        self.assertEqual(expected_hosted, hosted["snapshot_root"])
        self.assertEqual(f"{expected_hosted}/v3/{hosted['key']}", hosted["v3_dir"])
        self.assertEqual(f"{expected_hosted}/v3/cold-build-seconds", hosted["cold_file"])
        self.assertEqual(f"{expected_hosted}/live-v1", hosted["live_v1"])
        self.assertEqual(f"{expected_hosted}/ch-v1", hosted["ch_v1"])

        # 3. Missing $ENACT_HOST_CACHE/repo falls back to ~/.cache/enact/snapshots.
        missing_repo = self.base / "host-no-repo"
        missing_repo.mkdir()
        fallback = self._probe(probe_all, {"ENACT_HOST_CACHE": str(missing_repo)})
        self.assertEqual(expected_hosted, fallback["snapshot_root"])
        self.assertEqual(f"{expected_hosted}/v3/{fallback['key']}", fallback["v3_dir"])
        self.assertEqual(f"{expected_hosted}/live-v1", fallback["live_v1"])
        self.assertEqual(f"{expected_hosted}/ch-v1", fallback["ch_v1"])

        # 4. Read-only $ENACT_HOST_CACHE/repo falls back to ~/.cache/enact/snapshots.
        if os.geteuid() != 0:
            ro_cache = self.base / "host-ro"
            ro_repo = ro_cache / "repo"
            ro_repo.mkdir(parents=True)
            ro_repo.chmod(stat.S_IRUSR | stat.S_IXUSR)
            self.addCleanup(lambda: ro_repo.chmod(stat.S_IRWXU))
            ro_res = self._probe(probe_all, {"ENACT_HOST_CACHE": str(ro_cache)})
            self.assertEqual(expected_hosted, ro_res["snapshot_root"])

        # 5. Explicit ENACT_TEMPLATE_SNAPSHOT_DIR overrides both ENACT_HOST_CACHE and HOME.
        explicit_dir = str(self.base / "custom-snapshots")
        explicit = self._probe(
            probe_all,
            {
                "ENACT_HOST_CACHE": str(self.host_cache),
                "ENACT_TEMPLATE_SNAPSHOT_DIR": explicit_dir,
            },
        )
        self.assertEqual(explicit_dir, explicit["env_dir"])
        self.assertEqual(explicit_dir, explicit["snapshot_root"])
        self.assertEqual(f"{explicit_dir}/v3/{explicit['key']}", explicit["v3_dir"])
        self.assertEqual(f"{explicit_dir}/live-v1", explicit["live_v1"])
        self.assertEqual(f"{explicit_dir}/ch-v1", explicit["ch_v1"])

    def test_live_posthog_standalone_honors_snapshot_root_contract(self) -> None:
        probe_live = r"""
source showcase/scripts/live_posthog.sh
python3 - "$SNAPSHOT_ROOT" <<'PY'
import json, sys
root = sys.argv[1]
print(json.dumps({"snapshot_root": root, "live_v1": f"{root}/live-v1", "ch_v1": f"{root}/ch-v1"}))
PY
"""
        managed = self._probe(probe_live, {"ENACT_HOST_CACHE": str(self.host_cache)})
        self.assertEqual(f"{self.host_cache}/repo/pg-templates/live-v1", managed["live_v1"])
        self.assertEqual(f"{self.host_cache}/repo/pg-templates/ch-v1", managed["ch_v1"])

        hosted = self._probe(probe_live)
        self.assertEqual(f"{self.fake_home}/.cache/enact/snapshots/live-v1", hosted["live_v1"])
        self.assertEqual(f"{self.fake_home}/.cache/enact/snapshots/ch-v1", hosted["ch_v1"])

        explicit_dir = str(self.base / "explicit-live")
        explicit = self._probe(
            probe_live,
            {"ENACT_HOST_CACHE": str(self.host_cache), "ENACT_TEMPLATE_SNAPSHOT_DIR": explicit_dir},
        )
        self.assertEqual(f"{explicit_dir}/live-v1", explicit["live_v1"])
        self.assertEqual(f"{explicit_dir}/ch-v1", explicit["ch_v1"])

    def test_all_test_databases_callers_source_snapshot_root_first(self) -> None:
        callers = []
        for path in sorted(SCRIPTS.glob("*.sh")):
            if path.name in ("test_databases.sh", "snapshot_root.sh"):
                continue
            text = path.read_text(encoding="utf-8")
            db_match = re.search(r"^\s*source\s+.*test_databases\.sh\b", text, re.MULTILINE)
            if not db_match:
                continue
            callers.append(path.name)
            snap_match = re.search(r"^\s*source\s+.*snapshot_root\.sh\b", text, re.MULTILINE)
            self.assertIsNotNone(snap_match, f"{path.name} sources test_databases.sh without snapshot_root.sh")
            self.assertLess(
                snap_match.start(),
                db_match.start(),
                f"{path.name} must source snapshot_root.sh before test_databases.sh",
            )
        self.assertGreaterEqual(len(callers), 8, f"expected >= 8 test_databases.sh callers, found {callers}")

    def test_ci_cue_hosted_paths_align_with_all_three_namespaces(self) -> None:
        ci_cue = (OVERLAY / ".enact/ci.cue").read_text(encoding="utf-8")
        for ns in ("v3", "live-v1", "ch-v1"):
            self.assertIn(f'"~/.cache/enact/snapshots/{ns}"', ci_cue)
        self.assertIn(r'template_publications.py \"$HOME/.cache/enact/snapshots/v3\"', ci_cue)
        self.assertIn(r'live_migrate_cache.py verify \"$HOME/.cache/enact/snapshots\"', ci_cue)
        ci_matrix = (OVERLAY / ".github/workflows/ci-matrix.yml").read_text(encoding="utf-8")
        self.assertIn('template_publications.py "$HOME/.cache/enact/snapshots/v3"', ci_matrix)
        self.assertIn('live_migrate_cache.py verify "$HOME/.cache/enact/snapshots"', ci_matrix)
        for ns in ("v3", "live-v1", "ch-v1"):
            self.assertIn(f"~/.cache/enact/snapshots/{ns}", ci_matrix)


if __name__ == "__main__":
    unittest.main()
