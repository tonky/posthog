"""Two jobs' shards of one index get their own databases.

A run's jobs share its services (one Postgres, ClickHouse, Redis and Kafka per run or slot,
not per job), and base:test's and products:test's shards run at once. Both were worker
"shard1": the same test_posthog_shard1, dropped and recloned under the other's tests. The
worker is now <component>_<job>_shard<N> (ENACT_COMPONENT, ENACT_JOB). Postgres, ClickHouse
and the topics are stubbed: the test reads the names test_databases.sh gives each.
"""

import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hermetic import helper_env  # noqa: E402

SCRIPTS = Path(__file__).resolve().parents[1]

# Runs prepare_worker_databases for one worker, the services stubbed, and prints what it named.
PREPARE = r"""
source "$SCRIPT"
pg() { printf 'pg %s\n' "${*: -1}" >> "$LOG"; }
clickhouse-client() { printf 'ch %s\n' "${*: -1}" >> "$LOG"; }
clone_database() { printf 'clone %s\n' "$1" >> "$LOG"; }
with_templates() { "$@"; }
PGUSER=posthog PGHOST=127.0.0.1 PGPORT=5432 REDIS_PORT=6379 CLICKHOUSE_TCP_PORT=9000
worker=$(test_worker_name "$COMPONENT" "$JOB" "$SHARD") || exit 1
prepare_worker_databases "$worker" || exit 1
printf 'worker %s\n' "$worker"
for url in "$DATABASE_URL" "$PERSONS_DATABASE_URL" "$DAGSTER_TEST_POSTGRES_URL"; do printf 'db %s\n' "${url##*/}"; done
printf 'db %s\n' "$CLICKHOUSE_DATABASE"
printf 'xdist %s\nredis %s\ngateway %s\n' "$PYTEST_XDIST_WORKER" "$REDIS_URL" "$AI_GATEWAY_TEST_REDIS_DB"
"""

KAFKA_STUB = """#!/usr/bin/env bash
printf 'topics %s\\n' "${*: -1}" >> "$LOG"
"""


@unittest.skipUnless(shutil.which("bash"), "needs bash")
class WorkerNamesTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name).resolve()
        self.write("products/db_routing.yaml", "routes:\n  - app_label: stamphog\n    database: stamphog\n  - app_label: queue\n    database: warehouse_sources_queue\n")
        self.write("showcase/scripts/create_test_kafka_topics.py", "")
        self.write(".venv/bin/python", KAFKA_STUB, executable=True)

    def write(self, name: str, text: str, executable: bool = False) -> None:
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        if executable:
            path.chmod(0o755)

    def prepare(self, component: str, job: str, shard: int, slot: str = "") -> tuple[str, set[str], str]:
        """The worker's name, every database and topic suffix it names, and its Redis URL."""
        out, names = self.prepared(component, job, shard, slot)
        return out["worker"], names, out["redis"]

    def run_prepare(self, component: str, job: str, shard: int, slot: str = "") -> dict[str, str]:
        """What prepare_worker_databases exported: worker, xdist, redis and gateway."""
        return self.prepared(component, job, shard, slot)[0]

    def prepared(self, component: str, job: str, shard: int, slot: str) -> tuple[dict[str, str], set[str]]:
        log = self.repo / f"{component}-{job}-{shard}.log"
        env = {
            **helper_env(),
            "SCRIPT": str(SCRIPTS / "test_databases.sh"),
            "LOG": str(log),
            "COMPONENT": component,
            "JOB": job,
            "SHARD": str(shard),
            "ENACT_SERVICE_SLOT": slot,
        }
        done = subprocess.run(["bash", "-c", PREPARE], cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(0, done.returncode, done.stderr)
        out = dict(line.split(" ", 1) for line in done.stdout.splitlines() if not line.startswith("db "))
        names = {line.split(" ", 1)[1] for line in done.stdout.splitlines() if line.startswith("db ")}
        for line in log.read_text().splitlines():
            kind, rest = line.split(" ", 1)
            if kind in ("pg", "ch"):  # the last argument, its SQL: DROP/CREATE DATABASE <name>
                names.update(re.findall(r"DATABASE (?:IF (?:NOT )?EXISTS )?(\w+)", rest))
            else:
                names.add(rest)
        self.assertEqual(out["worker"], out["xdist"])
        return out, names

    def test_two_jobs_shard_one_share_no_database(self) -> None:
        base, base_names, base_redis = self.prepare("base", "test", 1)
        products, products_names, _ = self.prepare("products", "test", 1)
        self.assertEqual(("base_test_shard1", "products_test_shard1"), (base, products))
        self.assertIn("test_posthog_base_test_shard1", base_names)
        self.assertIn("test_posthog_products_test_shard1_warehouse_sources_queue", products_names)
        self.assertIn("base_test_shard1", base_names)  # the Kafka topics' suffix
        self.assertEqual(set(), base_names & products_names)
        self.assertEqual("redis://127.0.0.1:6379/17", base_redis)

    def test_a_long_component_and_job_stay_distinct_within_postgres_identifiers(self) -> None:
        workers = {}
        for comp, job, shard in [
            ("Plugin-Server.Ingestion", "integration_tests", 12),
            ("Plugin-Server.Ingestion", "integration_tests", 11),
            ("Plugin-Server.Ingestion", "integration_tests_slow", 12),
        ]:
            worker, names, redis = self.prepare(comp, job, shard)
            self.assertRegex(worker, rf"^[a-z0-9_]{{1,26}}_shard{shard}$")
            # Postgres cuts identifiers at 63 bytes: a cut name would be another's.
            self.assertTrue(all(len(n) <= 63 for n in names), sorted(names))
            # Redis' database is the shard's, not the digits of the names.
            self.assertTrue(redis.endswith(f"/{16 + shard}"), redis)
            workers[worker] = names
        self.assertEqual(3, len(workers))
        a, b, c = workers.values()
        self.assertEqual(set(), (a & b) | (a & c) | (b & c))

    def test_two_jobs_shard_one_take_their_service_slots_redis_dbs(self) -> None:
        # Under enact both run at once on the run's Redis: each its own slot's db.
        _, _, base_redis = self.prepare("base", "test", 1, slot="1")
        _, _, products_redis = self.prepare("products", "test", 1, slot="2")
        self.assertEqual(("redis://127.0.0.1:6379/17", "redis://127.0.0.1:6379/18"), (base_redis, products_redis))

    def test_a_shards_redis_databases_are_no_other_suites(self) -> None:
        # Slot 1's database was 1, the one the Rust feature-flags tests add to TEST_REDIS_URL
        # as their dedicated flags Redis, and the AI-gateway tests flushed a fixed 15 under
        # every shard (and slot 15's own). A shard takes 16+n and its gateway tests 32+n.
        gateways = set()
        for slot in range(1, 16):
            env = self.run_prepare("base", "test", 1, slot=str(slot))
            redis_db = int(env["redis"].rsplit("/", 1)[1])
            gateway = int(env["gateway"])
            self.assertEqual((16 + slot, 32 + slot), (redis_db, gateway))
            self.assertNotIn(redis_db, {0, 1, 15})
            gateways.add(gateway)
        self.assertEqual(15, len(gateways))
        self.assertTrue(all(16 < db < 48 for db in gateways))

    def test_the_profile_names_no_fixed_redis_database(self) -> None:
        # Every shard reads the profile's environment: a fixed database there is one all
        # shards share (FLAGS_REDIS_URL's "/1" was also slot 1's and Rust's flags db).
        profile = (SCRIPTS.parents[1] / "enve.cue").read_text()
        self.assertEqual([], re.findall(r'"redis://[^"]*/\d+"', profile))

    def test_a_shard_redis_has_no_database_for_fails(self) -> None:
        log = self.repo / "over.log"
        env = {**helper_env(), "SCRIPT": str(SCRIPTS / "test_databases.sh"), "LOG": str(log),
               "COMPONENT": "base", "JOB": "test", "SHARD": "1", "ENACT_SERVICE_SLOT": "16"}
        done = subprocess.run(["bash", "-c", PREPARE], cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertNotEqual(0, done.returncode)
        self.assertIn("Redis has databases for shards 1-15, not 16", done.stderr)

    def test_a_worker_outside_a_job_keeps_its_name(self) -> None:
        # A run outside enact (no ENACT_COMPONENT or ENACT_JOB): shard<N>, as before.
        worker, _, _ = self.prepare("", "", 2)
        self.assertEqual("shard2", worker)


if __name__ == "__main__":
    unittest.main()
