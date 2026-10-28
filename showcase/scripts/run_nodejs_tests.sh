#!/usr/bin/env bash
# The plugin server's jest suite (nodejs/), as ci-nodejs.yml's tests job runs it: test databases
# (the Django schema, the rust services' sqlx databases, ClickHouse and its Kafka topics), the
# workspace build, then the parallel and the serial lane. Arguments (test paths,
# --findRelatedTests ...) go to the jest of each lane holding a file they match, whole (enact splits
# its targets between the shards); arguments that match none fail (a run told to run tests that runs none is no pass).
#
# CI runs each shard on its own runner, with its own services. A local `enact run` starts the
# shards side by side, and the suite names what it resets with no worker suffix: ClickHouse's
# posthog_test, its Kafka engine tables' consumer group group1, the <topic>_test topics, and
# test_cyclotron_node (on $PGPORT, patches/0001). So each shard runs in an enve service instance
# of its own, with its own Postgres, Redis, ClickHouse, Kafka, both object stores (objectstorage
# and the open seaweedfs), Valkey cluster, DynamoDB and maildev, and sets them up as CI's
# runner does. Only the
# Django database is the run's: a fresh clone of the migrated template on the run's Postgres,
# under its service slot's name.
#
# Two phases in one file: in the run's environment the Django clone, the install and build, and
# the lanes the arguments select; then `enve run --instance <the shard's> --with-services` runs
# this script again (NODEJS_SHARD_INSTANCE set) for the instance's setup and the jest lanes.
#
# `--rust-ingestion-e2e` (first, alone) runs ci-nodejs.yml's rust_ingestion_e2e job instead of
# the lanes, set up the same way: the debug build of ingestion-consumer, then
# `pnpm run test:rust-ingestion-e2e`, whose test spawns the consumer (`cargo run`) and the Node
# ingestion API workers on the instance's services. Its argument, if any, is that test's file.
# In a recording run on Linux that wants it, the e2e runs under `enact trace run`, and
# rust_footprint.py adds what the consumer was built from.
set -euo pipefail
caller="$PWD"
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# The suite: the jest lanes, or the e2e (the instance's phase has it from NODEJS_SUITE).
suite="${NODEJS_SUITE:-jest}"
rust_e2e_test=nodejs/tests/service-e2e/rust-ingestion-consumer.serial.test.ts
if [ "${1:-}" = "--rust-ingestion-e2e" ]; then
    suite=rust-ingestion-e2e
    shift
    # Its one test, given relative to the caller's directory (nodejs/, as enact does).
    for target in "$@"; do
        dir="$(cd "$caller" && cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || dir=""
        [ "${dir#"$(pwd -P)"/}/$(basename "$target")" = "$rust_e2e_test" ] || {
            echo "✗ run_nodejs_tests.sh: --rust-ingestion-e2e runs $rust_e2e_test, not $target" >&2
            exit 64
        }
    done
    set --
    # The Rust jobs' build settings, so the consumer's build shares the workspace target dir's
    # artifacts with theirs (and links as theirs).
    # shellcheck source=rust_ci_env.sh
    source showcase/scripts/rust_ci_env.sh
fi

# Normalize selected paths before the service-instance re-exec. Only explicit test files
# are already assigned by enact; directories, patterns and selectors still need jest's
# original shard for discovery. Keep that index for this shard's services and database.
if [ "$suite" = jest ] && [ "$#" -eq 0 ] && [ -n "${ENACT_TARGETS_FILE:-}" ]; then
    targets=()
    while IFS= read -r target || [ -n "$target" ]; do
        if [[ "$target" =~ [^[:space:]] ]]; then targets+=("$target"); fi
    done < "$ENACT_TARGETS_FILE"
    caller="$PWD"
    set -- ${targets[@]+"${targets[@]}"}
fi
given=()
for target in "$@"; do
    if [[ "$target" != -* ]] && dir="$(cd "$caller" && [ -e "$target" ] && cd "$(dirname "$target")" 2>/dev/null && pwd -P)"; then
        given+=("$dir/$(basename "$target")")
    else
        given+=("$target")
    fi
done
set -- ${given[@]+"${given[@]}"}
shard_index="${ENACT_SHARD_INDEX:-${SHARD_INDEX:-1}}"
[[ "$shard_index" =~ ^[0-9]{1,4}$ ]] || { echo "Invalid shard index: $shard_index" >&2; exit 64; }
explicit_files=false
if [ "$#" -gt 0 ]; then
    explicit_files=true
    for target in "$@"; do
        if [[ "$target" != *.test.ts ]] || [ ! -f "$target" ]; then explicit_files=false; fi
    done
fi
if [ "$explicit_files" = true ]; then
    export SHARD_INDEX=1 SHARD_COUNT=1
else
    export SHARD_INDEX="$shard_index" SHARD_COUNT="${ENACT_SHARD_TOTAL:-${SHARD_COUNT:-1}}"
fi

# The broker list settings the plugin server reads from env: every *_METADATA_BROKER_LIST name
# its sources hold, and KAFKA_<target>_METADATA_BROKER_LIST for each getKafkaConfigFromEnv
# target (common/kafka/config.ts's KafkaConfigTarget).
kafka_broker_settings() {
    {
        grep -rhoE --include='*.ts' --exclude='*.test.ts' '\b[A-Z][A-Z0-9_]*_METADATA_BROKER_LIST\b' nodejs/src
        sed -n '/^export type KafkaConfigTarget/,/^$/p' nodejs/src/common/kafka/config.ts 2>/dev/null |
            sed -nE "s/^ *\| *'([A-Z0-9_]+)'.*/KAFKA_\1_METADATA_BROKER_LIST/p"
    } | sort -u
}

if [ -n "${NODEJS_SHARD_INSTANCE:-}" ]; then
    # In the shard's instance. jest writes to the shard's own stdout and stderr (fds 3 and 4);
    # enve's output, the services' logs, goes to the instance's log.
    if { true >&3 && true >&4; } 2>/dev/null; then exec 1>&3 2>&4 3>&- 4>&-; fi
    [ "${ENVE_INSTANCE:-}" = "$NODEJS_SHARD_INSTANCE" ] || {
        echo "✗ run_nodejs_tests.sh: in instance '${ENVE_INSTANCE:-}', not the shard's $NODEJS_SHARD_INSTANCE" >&2
        exit 70
    }
    # The databases ci-nodejs.yml points the suite at, by its names, on the instance's
    # Postgres; the Django one is the run's clone.
    pg_url="postgres://${PGUSER}:${PGPASSWORD:-posthog}@${PGHOST}:${PGPORT}"
    export DATABASE_URL="${NODEJS_DJANGO_DATABASE_URL:?the Django clone}"
    export PERSONS_DATABASE_URL="$pg_url/test_persons"
    export PERSONS_READONLY_DATABASE_URL="$PERSONS_DATABASE_URL"
    export BEHAVIORAL_COHORTS_DATABASE_URL="$pg_url/test_behavioral_cohorts"
    export CYCLOTRON_NODE_DATABASE_URL="$pg_url/test_cyclotron_node"
    # The Redis clients reach the instance's REDIS_URL and REDIS_PORT through their defaults
    # (patches/0004): tests build them from getDefault*Config(), not the env.
    export CLICKHOUSE_DATABASE=posthog_test
    # The CDP's Valkey cluster (CI's valkey-cluster on :6390), the instance's. Without one its
    # shadow client's reconnects end in killGracefully(): a SIGTERM to the jest process.
    export CDP_VALKEY_HOST=127.0.0.1 CDP_VALKEY_PORT="${ENVE_SERVICE_VALKEY_CLUSTER_PORT:?the instance valkey-cluster port}"
    # Session replay's (and the AI blob store's) S3, CI's seaweedfs on :8333: the instance's.
    export SESSION_RECORDING_V2_S3_ENDPOINT="http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_OPEN_PORT:?the instance open seaweedfs port}"
    # CI's dynamodb on :18010 (the recording API's and the crawl history's integration tests,
    # patches/0001) and maildev on :1025 (SMTP) and :1080 (its /email API; the CDP's email
    # tests, which read these names themselves): the instance's.
    export DYNAMODB_ENDPOINT="http://127.0.0.1:${ENVE_SERVICE_DYNAMODB_PORT:?the instance dynamodb port}"
    export MAILDEV_PORT="${ENVE_SERVICE_MAILDEV_PORT_SMTP:?the instance maildev SMTP port}"
    export MAILDEV_WEB_PORT="${ENVE_SERVICE_MAILDEV_PORT:?the instance maildev web port}"
    # CI's runner resolves `kafka` to its broker on 9092 (/etc/hosts), the default of every
    # Kafka client the suite configures no broker for: the producers' and consumers' broker
    # lists, read from env by name (KAFKA_<target>_METADATA_BROKER_LIST, the
    # *_METADATA_BROKER_LIST settings). Here every one of them is the instance's broker
    # (patches/0004 keeps them out of the env-parsing tests' snapshots).
    for setting in $(kafka_broker_settings); do export "$setting=$KAFKA_HOSTS"; done
    : "${CLICKHOUSE_TCP_PORT:?the instance ClickHouse native port}"

    # The rust services' databases, as `pnpm run setup:test:rust` makes them (but
    # flags_read_store, which the suite doesn't use).
    for kind in persons cyclotron-node behavioral-cohorts; do
        rust/bin/migrate-entry "$kind" --fresh
    done
    TEST=1 uv run --no-sync python manage.py setup_test_environment --only-clickhouse
    uv run --no-sync python showcase/scripts/create_test_kafka_topics.py
    # The ingestion e2e suites probe ClickHouse's Kafka engine for 30s, producing at the latest
    # offset. Its ~35 freshly created consumers take ~40s to get their partitions here; on CI
    # the kafka-init and the workspace build before the tests outlast that. Wait for every
    # assignment.
    tables="SELECT count() FROM system.tables WHERE database = 'posthog_test' AND engine = 'Kafka'"
    assigned="SELECT countIf(length(assignments.topic) > 0) FROM system.kafka_consumers WHERE database = 'posthog_test'"
    deadline=$((SECONDS + ${ENACT_KAFKA_ASSIGNMENT_TIMEOUT:-180}))
    until [ "$(clickhouse-client --port "$CLICKHOUSE_TCP_PORT" -q "$assigned")" -ge "$(clickhouse-client --port "$CLICKHOUSE_TCP_PORT" -q "$tables")" ]; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "ClickHouse's Kafka consumers have no partitions after ${ENACT_KAFKA_ASSIGNMENT_TIMEOUT:-180}s" >&2
            exit 1
        fi
        sleep 1
    done

    cd nodejs
    if [ "$suite" = rust-ingestion-e2e ]; then
        # ci-nodejs.yml's step env.
        export LOG_LEVEL="${LOG_LEVEL:-error}"
        if [ -z "${ENACT_FOOTPRINT_DIR:-}" ] || [ "$(uname -s)" != Linux ] ||
            { [ -n "${ENACT_FOOTPRINT_TARGETS:-}" ] && ! rg -qxF "$rust_e2e_test" "$ENACT_FOOTPRINT_TARGETS"; }; then
            exec pnpm run test:rust-ingestion-e2e
        fi
        # Recording: the e2e traced, the consumer's `cargo run` and the workers included, then
        # what the consumer was built from (its build's artifacts, a no-op rebuild).
        traces="$(mktemp -d)"
        trap 'rm -rf "$traces"' EXIT
        echo "🎙️  tracing $rust_e2e_test for enact's reach map"
        status=0
        "${ENACT_EXE:-enact}" trace run --outcomes --shared-tmpdir --no-fingerprint \
            --reach-file "$traces/rust_e2e.json" -t "$rust_e2e_test" -- pnpm run test:rust-ingestion-e2e || status=1
        if (cd ../rust && cargo build -p ingestion-consumer --message-format json >"$traces/artifacts.jsonl" &&
            cargo metadata --format-version 1 >"$traces/metadata.json"); then
            python3 ../showcase/scripts/rust_footprint.py --repo "$(cd .. && pwd -P)" --artifacts "$traces/artifacts.jsonl" \
                --metadata "$traces/metadata.json" --recorder "rust_footprint.py/2" --out "$ENACT_FOOTPRINT_DIR" \
                --built-from rust/ingestion-consumer/src/main.rs "$traces/rust_e2e.json" || status=1
        else
            status=1
        fi
        exit "$status"
    fi
    # Resolve broad selections on their original jest shard before recording individual
    # files. Reset sharding only after discovery: otherwise a directory runs on every shard,
    # or the discovered files are sharded twice. Explicit file lists avoid this extra probe.
    if [ "$suite" = jest ] && [ "$explicit_files" = false ] &&
        [ -n "${ENACT_FOOTPRINT_DIR:-}" ] && [ "$(uname -s)" = Linux ]; then
        selected=()
        for lane in parallel serial; do
            listed=$(pnpm --silent run "test:$lane" --ci --listTests "$@") || {
                echo "✗ run_nodejs_tests.sh: jest couldn't list the $lane lane's tests for: $*" >&2
                exit 1
            }
            while IFS= read -r target; do
                [[ "$target" != *.test.ts ]] || selected+=("$target")
            done <<< "$listed"
        done
        if [ "${#selected[@]}" -eq 0 ]; then
            echo "✗ run_nodejs_tests.sh: no test of either lane matches this shard: $*" >&2
            exit 1
        fi
        set -- "${selected[@]}"
        export SHARD_INDEX=1 SHARD_COUNT=1
    fi
    # Record only the files enact requests (all selected files when no list is supplied).
    # Each traced file gets its own jest and map; the remaining files run together below.
    # Service setup is shared by the whole shard rather than repeated per recorded file.
    if [ "$suite" = jest ] && [ "$#" -gt 0 ] && [ -n "${ENACT_FOOTPRINT_DIR:-}" ] &&
        [ "$(uname -s)" = Linux ]; then
        status=0 n=0 rest=()
        # jest's reporter saying, in enact's attribution record ($ENACT_SKIPS_FILE: `enact handbook
        # scoping`, "Recorder contract"), whether the run skipped tests of its file (a
        # `test.skip`/`test.todo`/`describe.skip`; the trace sees only what decided the skip):
        # the footprint lands marked as skipped here. Written here, not shipped beside this
        # script: a new file in showcase/ ages the footprints of the tests listing it.
        reporter="$(mktemp -d)/jest_attribution.cjs"
        trap 'rm -rf "$(dirname "$reporter")"' EXIT
        cat >"$reporter" <<'JEST_REPORTER'
const fs = require('node:fs');
// A test result's statuses that ran nothing: skipped, todo, or left out (`.only` elsewhere).
const SKIPPED = new Set(['pending', 'todo', 'skipped', 'disabled']);
module.exports = class EnactAttribution {
  onTestResult(_test, result) {
    const out = process.env.ENACT_SKIPS_FILE;
    if (!out) return;
    const statuses = (result.testResults ?? []).map((test) => test.status);
    const someSkipped = result.skipped === true || statuses.some((status) => SKIPPED.has(status));
    const allSkipped = result.skipped === true || (statuses.length > 0 && statuses.every((status) => SKIPPED.has(status)));
    const failed = result.testExecError != null || result.numFailingTests > 0 || statuses.includes('failed');
    const outcome = failed ? 'failed' : allSkipped ? 'skipped' : 'passed';
    fs.appendFileSync(out, `${JSON.stringify({ target: result.testFilePath, outcome, skipped: someSkipped, reads: [] })}\n`);
  }
};
JEST_REPORTER
        for target in "$@"; do
            test=$(realpath -ms --relative-to=.. "$target")
            if [ -n "${ENACT_FOOTPRINT_TARGETS:-}" ] && ! rg -qxF -- "$test" "$ENACT_FOOTPRINT_TARGETS"; then
                rest+=("$target")
                continue
            fi
            n=$((n + 1))
            lane=parallel
            [[ "$target" != *.serial.test.ts ]] || lane=serial
            # The footprint uses the repository path; jest receives its normalized absolute path.
            echo "🎙️  tracing $test (the $lane lane) for enact's reach map"
            # The lane's script ends in an array option (--testPathIgnorePatterns): --reporters
            # is one too, and --ci ends it.
            "${ENACT_EXE:-enact}" trace run --node-functions --outcomes --shared-tmpdir --no-fingerprint \
                --reach-file "$ENACT_FOOTPRINT_DIR/nodejs-traced-$n.json" -t "$test" -- \
                pnpm run "test:$lane" --reporters=default "--reporters=$reporter" --ci "$target" || status=1
        done
        [ "${#rest[@]}" -gt 0 ] || exit "$status"
        set -- "${rest[@]}"
        NODEJS_LANES=""
        for target in "$@"; do
            lane=parallel
            [[ "$target" != *.serial.test.ts ]] || lane=serial
            [[ " $NODEJS_LANES " == *" $lane "* ]] || NODEJS_LANES="$NODEJS_LANES $lane"
        done
    else
        status=0
    fi
    # The scripts end in --testPathIgnorePatterns, an array option: paths given right after it
    # are more patterns to ignore, and the lane runs every other file. A flag first ends the
    # array (--ci, as on CI's runners: missing snapshots fail rather than being written).
    if [[ " $NODEJS_LANES " == *" parallel "* ]]; then
        pnpm run test:parallel --ci "$@" || { rc=$?; [ "$status" -ne 0 ] || status=$rc; }
    fi
    # Both lanes run; the first failure is the status. No --passWithNoTests: a lane that runs
    # has files (every shard of the suite draws some, and a targeted run lists them).
    if [[ " $NODEJS_LANES " == *" serial "* ]]; then
        pnpm run test:serial --ci "$@" || { rc=$?; [ "$status" -ne 0 ] || status=$rc; }
    fi
    exit "$status"
fi

# shellcheck source=test_databases.sh
source showcase/scripts/test_databases.sh

shard="shard${shard_index}"
[ "$suite" = jest ] || shard="rust_e2e"

# The Django schema: ci-nodejs.yml restores a schema dump into test_posthog. This clones the
# backend's migrated template instead, under the service slot's name: the tests write and truncate it,
# and test_posthog is the template itself.
django_db="test_posthog_nodejs_slot${ENACT_SERVICE_SLOT:-$shard_index}"
[ "$suite" = jest ] || django_db="test_posthog_nodejs_rust_e2e"
with_templates fresh_django_clone "$django_db"
export NODEJS_DJANGO_DATABASE_URL="postgres://${PGUSER}:${PGPASSWORD:-posthog}@${PGHOST}:${PGPORT}/$django_db"
export NODE_OPTIONS="${NODE_OPTIONS:---max_old_space_size=4096}"
unset PYTEST_XDIST_WORKER TOX_PARALLEL_ENV

# The shards install into one node_modules and build one dist: one at a time (exclusive.sh).
# turbo.json's build keys its cache on SHARD_INDEX and SHARD_COUNT (CI's shards are machines of
# their own): with them each shard missed it and rebuilt @posthog/hogvm (`rm -rf dist` first)
# under the jest of a shard already running ("Cannot find module '@posthog/hogvm'"). Without
# them the first shard builds and the others restore its cached outputs.
showcase/scripts/exclusive.sh node-modules pnpm --filter=@posthog/nodejs... install --frozen-lockfile
showcase/scripts/build_hogvm.sh
showcase/scripts/exclusive.sh nodejs-build env -u SHARD_INDEX -u SHARD_COUNT bin/turbo --filter=@posthog/nodejs prepare

# The lanes that run. Without arguments both, each its shard of the suite: every shard of the
# three draws files of both. Arguments may match one lane's files only, so a lane runs when
# jest lists a file of it (--listTests, after --shard), and arguments that match none in
# either lane fail the run: a run given tests that ran none is no pass.
# The job passes its selected test files (paths from the checkout's root) as arguments; a run
# by hand gives arguments, or test files through enact (`enact run --shard
# nodejs_servers:test:1/1=<file>,...`), listed one per line in $ENACT_TARGETS_FILE when no argument does.
lanes="parallel serial"
if [ "$suite" = rust-ingestion-e2e ]; then
    # ci-nodejs.yml's pre-build (ingestion-worker-proto's build script runs protoc): the test's
    # `cargo run` then starts the consumer at once, within its readiness wait.
    lanes=""
    (cd rust && cargo build -p ingestion-consumer)
elif [ "$#" -gt 0 ]; then
    lanes=""
    for lane in parallel serial; do
        listed=$(cd nodejs && pnpm --silent run "test:$lane" --ci --listTests "$@") || {
            echo "✗ run_nodejs_tests.sh: jest couldn't list the $lane lane's tests for: $*" >&2
            exit 1
        }
        [[ "$listed" == *.test.ts* ]] && lanes="$lanes $lane"
    done
    if [ -z "$lanes" ]; then
        echo "✗ run_nodejs_tests.sh: no test of either lane matches: $*" >&2
        exit 1
    fi
fi

# The shard's instance: the run's (enact's enact-<n>, else enve's default) and the shard's
# service slot, which no other running shard of the run holds.
# Fresh, as a CI runner's services (enve starts from empty data unless --keep-data): a
# previous run's topics, groups and tables once hid missing ones (the Kafka engine's
# unsuffixed topics).
instance="${ENVE_INSTANCE:-default}-nodejs${ENACT_SERVICE_SLOT:-$shard_index}"
[ "$suite" = jest ] || instance="${ENVE_INSTANCE:-default}-rust-e2e${ENACT_SERVICE_SLOT:-1}"
log="$PWD/.enact/state/nodejs/$instance.services.log"
mkdir -p "$(dirname "$log")"
echo "[$shard] jest in service instance $instance (its services' log: $log)" >&2
status=0
NODEJS_SHARD_INSTANCE="$instance" NODEJS_LANES="$lanes" NODEJS_SUITE="$suite" \
    enve run --locked --instance "$instance" --wait=10m --no-deps --with-services=postgres,redis,clickhouse,kafka,seaweedfs,seaweedfs-open,valkey-cluster,dynamodb,maildev \
    -- bash showcase/scripts/run_nodejs_tests.sh "$@" 3>&1 4>&2 >"$log" 2>&1 || status=$?
if [ "$status" -ne 0 ]; then
    echo "[$shard] failed ($status); the end of instance $instance's log ($log):" >&2
    tail -n 40 "$log" >&2
fi
exit "$status"
