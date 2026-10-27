"""A local run's nodejs shards share no service state.

CI runs each shard of ci-nodejs.yml's tests on its own runner, with its own services. `enact run
nodejs:test` starts the three shards of run_nodejs_tests.sh side by side; on one Postgres,
ClickHouse, Kafka and Redis each reset all of them (`fresh_django_clone test_posthog_nodejs`,
`migrate-entry all --fresh`, `setup_test_environment --only-clickhouse`) while the others ran
jest, and a lock between the shards then ran the serial lanes alone. Each shard now runs in an
enve service instance of its own. Here the services are a log: the setup commands record what
they reset, the jest lanes (sleeps) what they use and when they start and end, each named by the
server it is on (host and port) and its name there. The shards start staggered, so each arrives
while the others run jest.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hermetic import declared_services, helper_env  # noqa: E402

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parents[1]

# Every line: <shard> <event> [resources...]. Appends of a line are atomic, so the log's order
# is the order things happened in.
LOG = 'log() { echo "$ENACT_SHARD_INDEX $*" >> "$STUB_LOG"; }\n'

# test_databases.sh: the template lock is test_databases_test's; the clone is a reset.
TEST_DATABASES_STUB = LOG + """
with_templates() { "$@"; }
fresh_django_clone() { log reset "pg:$PGHOST:$PGPORT/$1"; }
"""

# enve run --instance <id> ... --with-services=<names> -- <command>: the instance's services on
# ports of its own, as enve's named instances. Each service asked for gets the variables enve
# exports for it, ENVE_SERVICE_<NAME>_HOST, _PORT and _PORT_<SLOT> for each named port, from the
# checkout's declarations ($STUB_DIR/services: `enve services --json`'s), and the profile's
# variables the jobs read follow them, as enve.cue's profile derives them. A service enve.cue
# doesn't declare fails, as enve does. An instance one supervisor holds refuses a second.
ENVE_STUB = (
    "#!/usr/bin/env bash\n"
    + LOG
    + """
set -u
[ "$1" = run ] || exit 64
shift
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    case "$1" in
    --instance) instance="$2"; shift ;;
    --with-services=*) services="${1#*=}" ;;
    --keep-data*) kept=yes ;;
    esac
    shift
done
shift
held="$STUB_DIR/instances/$instance"
mkdir -p "$STUB_DIR/instances"
mkdir "$held" 2>/dev/null || { echo "enve stub: instance $instance is held" >&2; exit 75; }
trap 'rmdir "$held"' EXIT
log instance "$instance" "$services" "keep-data=${kept:-no}"
port=$(( $(printf %s "$instance" | cksum | cut -d' ' -f1) % 400 * 100 + 20000 ))
IFS=, read -r -a wanted <<<"$services"
for service in "${wanted[@]}"; do
    rows=$(awk -v s="$service" '$1 == s' "$STUB_DIR/services")
    [ -n "$rows" ] || { echo "enve stub: enve.cue declares no service $service" >&2; exit 2; }
    var="ENVE_SERVICE_$(printf %s "$service" | tr 'a-z-' 'A-Z_')"
    export "${var}_HOST=127.0.0.1"
    while read -r _ slot _; do
        port=$((port + 1))
        if [ "$slot" = - ]; then
            export "${var}_PORT=$port"
        else
            export "${var}_PORT_$(printf %s "$slot" | tr 'a-z-' 'A-Z_')=$port"
        fi
    done <<<"$rows"
done
export ENVE_INSTANCE="$instance" PGHOST=127.0.0.1 PGPORT="$ENVE_SERVICE_POSTGRES_PORT" REDIS_PORT="$ENVE_SERVICE_REDIS_PORT"
export CLICKHOUSE_TCP_PORT="$ENVE_SERVICE_CLICKHOUSE_PORT_NATIVE" KAFKA_HOSTS="127.0.0.1:$ENVE_SERVICE_KAFKA_PORT"
export DATABASE_URL="postgres://posthog@127.0.0.1:$PGPORT/posthog" REDIS_URL="redis://127.0.0.1:$REDIS_PORT"
export OBJECT_STORAGE_ENDPOINT="http://localhost:$ENVE_SERVICE_SEAWEEDFS_PORT"
set +u
"$@"
"""
)


# rust/bin/migrate-entry, choosing the database as the real one does: the kind's URL, else
# its NAME, else the default.
MIGRATE_ENTRY_STUB = (
    "#!/usr/bin/env bash\n"
    + LOG
    + """
db() { local url="$1" name="$2"; if [ -n "$url" ]; then echo "${url#*@}"; else echo "localhost:5432/$name"; fi; }
kinds="$1"; [ "$1" = all ] && kinds="persons cyclotron-node behavioral-cohorts flags-read-store"
for kind in $kinds; do
    case "$kind" in
    persons) name=$(db "${PERSONS_DATABASE_URL:-}" "${PERSONS_DATABASE_NAME:-posthog_persons}") ;;
    cyclotron-node) name=$(db "${CYCLOTRON_NODE_DATABASE_URL:-}" "${CYCLOTRON_NODE_DATABASE_NAME:-cyclotron_node}") ;;
    behavioral-cohorts) name=$(db "${BEHAVIORAL_COHORTS_DATABASE_URL:-}" "${BEHAVIORAL_COHORTS_DATABASE_NAME:-behavioral_cohorts}") ;;
    flags-read-store) name=$(db "${FLAGS_READ_STORE_DATABASE_URL:-}" "${FLAGS_READ_STORE_DATABASE_NAME:-flags_read_store}") ;;
    esac
    log reset "pg:$name"
done
"""
)

# uv: the ClickHouse schema and the Kafka topics are resets of the services.
UV_STUB = (
    "#!/usr/bin/env bash\n"
    + LOG
    + """
case "$*" in
*setup_test_environment*) log reset "ch:$CLICKHOUSE_TCP_PORT/$CLICKHOUSE_DATABASE"; sleep 0.3 ;;
*create_test_kafka_topics*) log reset "kafka:$KAFKA_HOSTS/_test" ;;
esac
"""
)

# pnpm: the install is a no-op; package.json's setup:test:rust as upstream's; the lanes log their
# arguments and what jest reads (the suite's databases, test_cyclotron_node, which a few files
# name on $PGPORT, ClickHouse, Kafka, Redis, the S3 stores, Valkey, DynamoDB and maildev) around
# a sleep. --listTests prints the lane's
# files matching the arguments: LIST_<lane>.
PNPM_STUB = (
    "#!/usr/bin/env bash\n"
    + LOG
    + """
[ "$1" = --silent ] && shift
case "$1 $2" in
"run setup:test:rust")
    CYCLOTRON_NODE_DATABASE_NAME=test_cyclotron_node PERSONS_DATABASE_NAME=test_persons \\
        BEHAVIORAL_COHORTS_DATABASE_NAME=test_behavioral_cohorts ../rust/bin/migrate-entry all --fresh ;;
"run test:parallel" | "run test:serial")
    lane="${2#test:}"
    if [[ " $* " == *" --listTests "* ]]; then
        list="LIST_$lane"
        printf '%s\n' ${!list:-}
        exit 0
    fi
    log "args-$lane" "${@:3}"
    uses="pg:${DATABASE_URL#*@} pg:${PERSONS_DATABASE_URL#*@} pg:${BEHAVIORAL_COHORTS_DATABASE_URL#*@}"
    uses="$uses pg:${CYCLOTRON_NODE_DATABASE_URL#*@} pg:localhost:$PGPORT/test_cyclotron_node"
    uses="$uses ch:$CLICKHOUSE_TCP_PORT/$CLICKHOUSE_DATABASE kafka:$KAFKA_HOSTS/_test redis:$REDIS_PORT"
    uses="$uses s3:$OBJECT_STORAGE_ENDPOINT s3:$SESSION_RECORDING_V2_S3_ENDPOINT valkey:$CDP_VALKEY_HOST:$CDP_VALKEY_PORT"
    uses="$uses dynamodb:$DYNAMODB_ENDPOINT smtp:$MAILDEV_PORT maildev:$MAILDEV_WEB_PORT"
    log "start-$lane" $uses
    log "brokers-$lane" $(env | grep -E '^[A-Z0-9_]+_METADATA_BROKER_LIST=' | sort)
    sleep "${JEST_SECONDS:-1.5}"
    log "end-$lane" $uses
    ;;
esac
"""
)


@unittest.skipUnless(all(map(shutil.which, ("bash", "flock", "cksum"))), "needs bash, flock and cksum")
class NodejsShardDatabasesTest(unittest.TestCase):
    services: list[tuple[str, str, int]]

    @classmethod
    def setUpClass(cls) -> None:
        cls.services = declared_services(ROOT)

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name).resolve()
        for name in ("run_nodejs_tests.sh", "exclusive.sh"):
            self.write(f"showcase/scripts/{name}", (SCRIPTS / name).read_text())
        self.write("showcase/scripts/test_databases.sh", TEST_DATABASES_STUB)
        self.write("showcase/scripts/create_test_kafka_topics.py", "")
        self.write("rust/bin/migrate-entry", MIGRATE_ENTRY_STUB)
        self.write("bin/turbo", "#!/usr/bin/env bash\n" + LOG + 'log turbo "SHARD_INDEX=${SHARD_INDEX:-}" "SHARD_COUNT=${SHARD_COUNT:-}"\n')
        # hogvm's dist, built once for every job (build_hogvm.sh, build_once.sh's git key).
        self.write("showcase/scripts/build_hogvm.sh", "#!/usr/bin/env bash\n" + LOG + "log hogvm\n")
        self.write("stubs/uv", UV_STUB)
        self.write("stubs/pnpm", PNPM_STUB)
        self.write("stubs/enve", ENVE_STUB)
        self.write("stubs/clickhouse-client", "#!/usr/bin/env bash\necho 1\n")
        self.write("stub-state/services", "".join(f"{name} {slot} {port}\n" for name, slot, port in self.services))
        (self.repo / "nodejs").mkdir()
        self.log = self.repo / "stub.log"

    def write(self, name: str, text: str) -> None:
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def shards(self, count: int, stagger: float, *args: str, **lists: str) -> list[tuple[int, str]]:
        env = {
            **helper_env(self.services),
            "PATH": f"{self.repo / 'stubs'}{os.pathsep}{os.environ['PATH']}",
            "STUB_LOG": str(self.log),
            "STUB_DIR": str(self.repo / "stub-state"),
            # The run's services, as enact's run instance serves them.
            "ENVE_INSTANCE": "enact-3",
            "PGUSER": "posthog",
            "PGHOST": "127.0.0.1",
            "PGPORT": "5432",
            "REDIS_PORT": "6379",
            "CLICKHOUSE_TCP_PORT": "9000",
            "KAFKA_HOSTS": "127.0.0.1:9092",
            "ENACT_SHARD_TOTAL": str(count),
            **{f"LIST_{lane}": files for lane, files in lists.items()},
        }
        running = []
        for index in range(1, count + 1):
            running.append(
                subprocess.Popen(
                    ["bash", "showcase/scripts/run_nodejs_tests.sh", *args],
                    cwd=self.repo,
                    # A shard's service slot is the run's lowest free one, not its index.
                    env={**env, "ENACT_SHARD_INDEX": str(index), "ENACT_SERVICE_SLOT": str(index + 4)},
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
            )
            time.sleep(stagger)
        return [(p.wait(timeout=60), p.communicate()[0]) for p in running]

    def events(self) -> list[tuple[str, str, set[str]]]:
        lines = self.log.read_text().splitlines()
        return [(shard, event, set(resources)) for shard, event, *resources in map(str.split, lines)]

    def lanes(self) -> list[tuple[str, str, int, int, set[str]]]:
        """Each jest lane a shard ran: (shard, lane, start line, end line, what it used)."""
        events = self.events()
        lanes = []
        for start, (shard, event, uses) in enumerate(events):
            if event.startswith("start-"):
                lane = event.removeprefix("start-")
                end = next(i for i, e in enumerate(events) if i > start and e[:2] == (shard, f"end-{lane}"))
                lanes.append((shard, lane, start, end, uses))
        return lanes

    def test_overlapping_shards_reset_nothing_another_shard_uses(self) -> None:
        for status, output in self.shards(3, stagger=0.4):
            self.assertEqual(0, status, output)
        events, lanes = self.events(), self.lanes()
        self.assertEqual(6, len(lanes), self.log.read_text())
        # The shards ran side by side, serial lanes too: the setup alone is no proof otherwise.
        for kind in ("parallel", "serial"):
            self.assertTrue(
                any(a[0] != b[0] and a[1] == kind and a[2] < b[3] and b[2] < a[3] for a in lanes for b in lanes),
                f"no {kind} lane ran beside another shard's jest:\n" + self.log.read_text(),
            )
        for line, (shard, event, resources) in enumerate(events):
            if event != "reset":
                continue
            for other, lane, start, end, uses in lanes:
                self.assertFalse(
                    other != shard and start < line < end and resources & uses,
                    f"shard {shard} reset {resources} while shard {other}'s {lane} jest used it:\n"
                    + self.log.read_text(),
                )
        # Each shard sets its ClickHouse database up once, before its own jest reads it.
        for shard in ("1", "2", "3"):
            resets = [i for i, (s, event, res) in enumerate(events) if s == shard and event == "reset" and any(r.startswith("ch:") for r in res)]
            self.assertEqual(1, len(resets), self.log.read_text())
            self.assertLess(resets[0], min(start for s, _, start, _, _ in lanes if s == shard))

    def test_the_shards_build_under_one_turbo_cache_key(self) -> None:
        # turbo.json's build hashes SHARD_INDEX and SHARD_COUNT: a shard building under its own
        # missed the cache and rebuilt @posthog/hogvm's dist (`rm -rf dist`) while another
        # shard's jest loaded it ("Cannot find module '@posthog/hogvm'").
        for status, output in self.shards(3, stagger=0.0):
            self.assertEqual(0, status, output)
        builds = [(shard, res) for shard, event, res in self.events() if event == "turbo"]
        self.assertEqual(["1", "2", "3"], sorted(shard for shard, _ in builds), self.log.read_text())
        self.assertEqual([{"SHARD_INDEX=", "SHARD_COUNT="}] * 3, [res for _, res in builds])

    def test_each_shard_runs_in_an_instance_of_its_slot(self) -> None:
        for status, output in self.shards(3, stagger=0.0):
            self.assertEqual(0, status, output)
        instances = {shard: res for shard, event, res in self.events() if event == "instance"}
        self.assertEqual(
            {
                "1": {"enact-3-nodejs5", "postgres,redis,clickhouse,kafka,seaweedfs,seaweedfs-open,valkey-cluster,dynamodb,maildev", "keep-data=no"},
                "2": {"enact-3-nodejs6", "postgres,redis,clickhouse,kafka,seaweedfs,seaweedfs-open,valkey-cluster,dynamodb,maildev", "keep-data=no"},
                "3": {"enact-3-nodejs7", "postgres,redis,clickhouse,kafka,seaweedfs,seaweedfs-open,valkey-cluster,dynamodb,maildev", "keep-data=no"},
            },
            instances,
            self.log.read_text(),
        )

    def lane_args(self) -> dict[str, list[set[str]]]:
        """Each lane's jest arguments, one set per run of it."""
        args: dict[str, list[set[str]]] = {}
        for _, event, given in self.events():
            if event.startswith("args-"):
                args.setdefault(event.removeprefix("args-"), []).append(given)
        return args

    def test_a_whole_suite_run_runs_both_lanes_and_serial_without_pass_with_no_tests(self) -> None:
        (status, output), = self.shards(1, stagger=0.0)
        self.assertEqual(0, status, output)
        self.assertEqual(["parallel", "serial"], [lane for _, lane, *_ in self.lanes()])
        # A serial lane that ran no file would fail: its shard of the suite always holds some.
        self.assertNotIn("--passWithNoTests", set().union(*self.lane_args()["serial"]))

    def test_targets_run_only_the_lanes_holding_them(self) -> None:
        target = "tests/cdp/rerun-e2e.serial.test.ts"
        (status, output), = self.shards(1, 0.0, target, parallel="", serial=f"/repo/nodejs/{target}")
        self.assertEqual(0, status, output)
        self.assertEqual(["serial"], [lane for _, lane, *_ in self.lanes()], self.log.read_text())
        self.assertEqual([{"--ci", target}], self.lane_args()["serial"])

    def test_targets_that_match_no_test_fail(self) -> None:
        # jest's --passWithNoTests turned a run of tests that ran none into a pass.
        (status, output), = self.shards(1, 0.0, "src/gone.test.ts", parallel="", serial="")
        self.assertNotEqual(0, status, output)
        self.assertIn("no test of either lane matches: src/gone.test.ts", output)
        self.assertEqual([], self.lanes(), self.log.read_text())

    def test_shards_share_no_service_state(self) -> None:
        # The whole class: no database, ClickHouse database, Kafka topics or Redis a shard's jest
        # uses is another shard's, the names the suite hard-codes included.
        for status, output in self.shards(3, stagger=0.0):
            self.assertEqual(0, status, output)
        used: dict[str, set[str]] = {}
        for shard, _, _, _, uses in self.lanes():
            used.setdefault(shard, set()).update(uses)
        for shard, uses in used.items():
            self.assertEqual(14, len(uses), uses)
            for other, theirs in used.items():
                self.assertFalse(shard != other and uses & theirs, used)

    def test_every_kafka_client_reaches_the_shards_broker(self) -> None:
        # CI resolves `kafka` to its broker on 9092, the default broker list of every Kafka
        # client the suite configures none for; here `kafka` resolves nowhere ("Local: Broker
        # transport failure" in ~950 tests a run). Every broker list setting the sources read
        # is the shard's own broker; a test file's names are no settings.
        self.write(
            "nodejs/src/common/kafka/config.ts",
            "export type KafkaConfigTarget =\n    | 'PRODUCER'\n    | 'CONSUMER'\n\nconst x = 1\n",
        )
        self.write(
            "nodejs/src/cdp/outputs/producers.ts",
            "    'metadata.broker.list': 'KAFKA_WAREHOUSE_PRODUCER_METADATA_BROKER_LIST',\n"
            "    CDP_INTERNAL_EVENTS_CONSUMER_METADATA_BROKER_LIST: '',\n",
        )
        self.write("nodejs/src/cdp/outputs/producers.test.ts", "KAFKA_ONLY_IN_A_TEST_METADATA_BROKER_LIST\n")
        for status, output in self.shards(2, stagger=0.0):
            self.assertEqual(0, status, output)
        hosts = {
            shard: next(r.removeprefix("kafka:").removesuffix("/_test") for r in uses if r.startswith("kafka:"))
            for shard, _, _, _, uses in self.lanes()
        }
        self.assertEqual(2, len(set(hosts.values())), hosts)
        brokers = [(shard, given) for shard, event, given in self.events() if event.startswith("brokers-")]
        self.assertEqual(4, len(brokers), self.log.read_text())
        names = {
            "KAFKA_PRODUCER_METADATA_BROKER_LIST",
            "KAFKA_CONSUMER_METADATA_BROKER_LIST",
            "KAFKA_WAREHOUSE_PRODUCER_METADATA_BROKER_LIST",
            "CDP_INTERNAL_EVENTS_CONSUMER_METADATA_BROKER_LIST",
        }
        for shard, given in brokers:
            self.assertEqual({f"{name}={hosts[shard]}" for name in names}, given)


if __name__ == "__main__":
    unittest.main()
