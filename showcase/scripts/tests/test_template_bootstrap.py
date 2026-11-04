"""test_databases.sh's bootstrap on a key miss: the newest dump the checkout's migrations
extend is restored and migrated forward; templates are built from nothing only without one.

Postgres, pytest and sqlx are stubbed: the test drives bootstrap_templates through
consecutive keys, as consecutive checkouts would, and reads what it ran.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "test_databases.sh"

STUBS = r"""
source "$SCRIPT"
log() { printf '%s\n' "$*" >> "$LOG"; }
pg() {
    local sql="${*: -1}"
    case "$sql" in
        *server_version_num*) echo 170005 ;;
        *pg_stat_activity*) echo 0 ;;
        *to_regclass*) echo t ;;
        *shobj_description*) echo 2 ;;
        *) log "pg $sql" ;;
    esac
}
pg_restore() { log "pg_restore ${*: -1}"; }
pg_dump() {
    local out
    while [ $# -gt 0 ]; do [ "$1" = -f ] && out=$2; shift; done
    echo "dump of $KEY" > "$out"
}
sqlx() { :; }
run_bootstrap_test() {
    log "bootstrap $*"
    [ -n "$*" ] || [ -z "${TOP_UP_FAILS:-}" ]
}
current_template_key() { echo "$KEY"; }
configure_template_cache && bootstrap_templates
"""


@unittest.skipUnless(shutil.which("sha256sum"), "needs coreutils' sha256sum")
class BootstrapTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name) / "repo"
        self.snapshots = Path(tmp.name) / "snapshots"
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        self.write("posthog/migrations/0001_initial.py", "operations = []\n")

    def write(self, name: str, text: str) -> None:
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def bootstrap(self, key: str, **env: str) -> list[str]:
        return self.bootstrap_said(key, **env)[0]

    def bootstrap_said(self, key: str, **env: str) -> tuple[list[str], str]:
        """What the bootstrap ran, and what it told the developer (stderr)."""
        log = self.repo / "bootstrap.log"
        log.unlink(missing_ok=True)
        done = subprocess.run(
            ["bash", "-c", STUBS],
            cwd=self.repo,
            check=True,
            capture_output=True,
            env={
                **os.environ,
                **env,
                "SCRIPT": str(SCRIPT),
                "LOG": str(log),
                "KEY": key * 64,
                "ENACT_TEMPLATE_SNAPSHOT_DIR": str(self.snapshots),
            },
            text=True,
        )
        return log.read_text().splitlines(), done.stderr

    def restored(self, ran: list[str]) -> set[str]:
        return {Path(line.split()[-1]).parent.parent.name[:1] for line in ran if line.startswith("pg_restore")}

    def test_a_miss_migrates_the_newest_dump_forward(self) -> None:
        first = self.bootstrap("a")
        self.assertIn("bootstrap --create-db", first)
        self.assertEqual(set(), self.restored(first))

        # A new migration: a's dump is restored and migrated forward, then saved as b's.
        self.write("posthog/migrations/0002_x.py", "operations = []\n")
        second = self.bootstrap("b")
        self.assertEqual({"a"}, self.restored(second))
        self.assertIn("bootstrap ", second)
        self.assertNotIn("bootstrap --create-db", second)
        self.assertTrue((self.snapshots / "v3" / ("b" * 64) / "current-v3").is_file())

        # Another one: b's dump is newer than a's, and both are bases.
        self.write("products/x/backend/migrations/0001_initial.py", "operations = []\n")
        self.assertEqual({"b"}, self.restored(self.bootstrap("c")))

    def test_a_dump_the_checkout_cant_extend_is_rebuilt(self) -> None:
        self.bootstrap("a")
        # An edited migration: no saved dump has the checkout's history.
        self.write("posthog/migrations/0001_initial.py", "operations = [1]\n")
        ran = self.bootstrap("b")
        self.assertEqual(set(), self.restored(ran))
        self.assertIn("bootstrap --create-db", ran)

    def test_a_cold_build_says_how_long_before_it_starts(self) -> None:
        # Minutes of migrations print nothing: a developer saw a run stall with no reason.
        _, said = self.bootstrap_said("a")
        self.assertIn("from all 1 migrations: about 8 min", said)
        self.write("posthog/migrations/0001_initial.py", "operations = [1]\n")
        _, said = self.bootstrap_said("b")
        self.assertRegex(said, r"from all 1 migrations: the last one here took 0 min \d+ s")
        # Migrating a dump forward isn't a cold build.
        self.write("posthog/migrations/0002_x.py", "operations = []\n")
        _, said = self.bootstrap_said("c")
        self.assertIn("migrating", said)
        self.assertNotIn("Building the test database templates", said)

    def test_a_failed_migration_forward_builds_from_nothing(self) -> None:
        self.bootstrap("a")
        self.write("posthog/migrations/0002_x.py", "operations = []\n")
        ran = self.bootstrap("b", TOP_UP_FAILS="1")
        self.assertEqual({"a"}, self.restored(ran))
        self.assertEqual(["bootstrap ", "bootstrap --create-db"], [line for line in ran if line.startswith("bootstrap")])
        self.assertTrue((self.snapshots / "v3" / ("b" * 64) / "current-v3").is_file())


WORKER_STUBS = r"""
source "$SCRIPT"
pg() { printf '%s\n' "${*: -1}" >> "$LOG"; }
clickhouse-client() { :; }
clone_database() { printf 'clone %s\n' "$1" >> "$LOG"; }
PGUSER=posthog PGHOST=127.0.0.1 PGPORT=5432 REDIS_PORT=6379 CLICKHOUSE_TCP_PORT=9000
clone_worker_databases shard2 && export_worker_database shard2
printf 'env %s %s\n' "$PGDATABASE" "${DATABASE_URL##*/}" >> "$LOG"
"""


@unittest.skipUnless(shutil.which("bash"), "needs bash")
class WorkerDatabaseTest(unittest.TestCase):
    """A worker's product databases are the ones its tests reach: conftest.py points them at
    test_<default>_<product>, and pytest-django's TOX_PARALLEL_ENV suffix had Django
    create test_posthog_<product>_<worker> instead (test_team_project_differential's
    shard failed on a missing test_posthog_shard2_stamphog)."""

    def test_each_product_database_is_dropped_under_the_name_the_tests_use(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / "products").mkdir()
            (repo / "products/db_routing.yaml").write_text(
                "routes:\n    - app_label: stamphog\n      database: stamphog\n"
                "    - app_label: other\n      database: stamphog\n"
            )
            log = repo / "worker.log"
            subprocess.run(
                ["bash", "-c", WORKER_STUBS],
                cwd=repo,
                check=True,
                env={**os.environ, "SCRIPT": str(SCRIPT), "LOG": str(log)},
            )
            ran = log.read_text().splitlines()
        env = next(line.split()[1:] for line in ran if line.startswith("env "))
        self.assertEqual(["posthog_shard2", "posthog_shard2"], env)
        # Django's test database for the alias: "test_" + its name, PGDATABASE's + product.
        product_test_db = f"test_{env[0]}_stamphog"
        drops = [line for line in ran if line.startswith("DROP DATABASE")]
        self.assertEqual(1, sum(product_test_db + " " in line for line in drops), drops)
        self.assertIn("clone test_posthog_shard2", ran)

    def test_the_worker_database_the_environment_names_is_created_fresh(self) -> None:
        # batch_exports' postgres destination connects to DATABASE_URL's database itself:
        # 'database "posthog_shard3" does not exist' while nothing created it.
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "worker.log"
            subprocess.run(
                ["bash", "-c", WORKER_STUBS],
                cwd=tmp,
                check=True,
                env={**os.environ, "SCRIPT": str(SCRIPT), "LOG": str(log)},
            )
            ran = log.read_text().splitlines()
        drop = "DROP DATABASE IF EXISTS posthog_shard2 WITH (FORCE);"
        create = "CREATE DATABASE posthog_shard2;"
        self.assertIn(drop, ran)
        self.assertIn(create, ran)
        self.assertLess(ran.index(drop), ran.index(create))


if __name__ == "__main__":
    unittest.main()
