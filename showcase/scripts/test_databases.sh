#!/usr/bin/env bash
# Per-worker test databases on the shared enve Postgres and ClickHouse.
#
# Every pytest worker (a test shard or the repo-invariants audit) gets its
# own clone of the migrated templates, so workers never share a database and
# never touch the templates while they run:
#   test_posthog          -> test_posthog_<worker>          (Django)
#   test_posthog_persons  -> test_posthog_<worker>_persons  (sqlx persons)
#   test_posthog_<worker>_<product>                          (fresh: products/db_routing.yaml)
#   test_dagster_<worker>                                    (fresh)
#   ClickHouse posthog_test_<worker>                         (fresh)
# The worker's database is posthog_<worker> (DATABASE_URL, and PGDATABASE, which the
# product databases' names start with), so Django's test databases are the clones' names;
# PostHog's settings derive the ClickHouse name from PYTEST_XDIST_WORKER.
#
# The templates are built once, by the first worker to arrive, under a file
# lock; later workers wait for the lock and then for the templates to be free.
# Source this file and call prepare_worker_databases <worker>.

TEST_DB_LOCK="${ENACT_TEST_DB_LOCK:-.enact/state/test-databases.lock}"
TEMPLATE_DB="test_posthog"
TEMPLATE_PERSONS_DB="test_posthog_persons"
# A cheap database-backed test whose session setup creates and migrates the
# templates (Django, persons via sqlx, ClickHouse schema).
TEMPLATE_BOOTSTRAP_TEST="${ENACT_TEMPLATE_BOOTSTRAP_TEST:-posthog/hogql/test/test_mapping.py::TestMappings::test_unknown_type_mapping}"

pg() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -v ON_ERROR_STOP=1 -qtA "$@"; }

database_exists() { [ "$(pg -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$1'")" = "1" ]; }

SNAPSHOT_ROOT="${ENACT_TEMPLATE_SNAPSHOT_DIR:-${HOME}/.cache/enact/snapshots}"
TEMPLATE_INPUTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/template_inputs.py"

current_template_key() {
    local server_version
    server_version=$(pg -d postgres -c 'SHOW server_version_num') || return 1
    python3 "$TEMPLATE_INPUTS" key "$server_version" "$TEMPLATE_BOOTSTRAP_TEST"
}

configure_template_cache() {
    TEMPLATE_KEY=$(current_template_key) || return 1
    [[ "$TEMPLATE_KEY" =~ ^[a-f0-9]{64}$ ]] || return 1
    TEMPLATE_FORMAT="enact-test-template-v3:$TEMPLATE_KEY"
    SNAPSHOT_DIR="$SNAPSHOT_ROOT/v3/$TEMPLATE_KEY"
}

validate_template_inputs() {
    [ "$(current_template_key)" = "$TEMPLATE_KEY" ] || {
        echo "Template inputs changed during setup. Rerun the backend command." >&2
        return 1
    }
}

template_schema_ready() {
    [ "$(pg -d "$TEMPLATE_DB" -c "SELECT to_regclass('public.posthog_organization') IS NOT NULL")" = t ] \
        && [ "$(pg -d "$TEMPLATE_PERSONS_DB" -c "SELECT to_regclass('public.posthog_person') IS NOT NULL")" = t ]
}

template_ready() {
    [ "$(pg -d postgres -c "SELECT count(*) FROM pg_database WHERE datname IN ('$TEMPLATE_DB', '$TEMPLATE_PERSONS_DB') AND shobj_description(oid, 'pg_database') = '$TEMPLATE_FORMAT'")" = 2 ] \
        && template_schema_ready
}

mark_templates_ready() {
    template_schema_ready || return 1
    pg -d postgres -c "COMMENT ON DATABASE $TEMPLATE_DB IS '$TEMPLATE_FORMAT';" >/dev/null || return 1
    pg -d postgres -c "COMMENT ON DATABASE $TEMPLATE_PERSONS_DB IS '$TEMPLATE_FORMAT';" >/dev/null
}

reset_templates() {
    local db
    wait_templates_free || return 1
    for db in "$TEMPLATE_DB" "$TEMPLATE_PERSONS_DB"; do
        pg -d postgres -c "DROP DATABASE IF EXISTS $db;" >/dev/null || return 1
        pg -d postgres -c "CREATE DATABASE $db;" >/dev/null || return 1
    done
}

sync_sqlx_migrations() {
    local target_db="${1:-$TEMPLATE_PERSONS_DB}"
    # PG* variables preserve credentials without interpolating them into a URL.
    DATABASE_URL="postgresql:///$target_db" sqlx migrate run --source rust/persons_migrations
}

snapshot_manifest() { # [format]: the dump's own key's, by default this key's
    local server_version
    server_version=$(pg -d postgres -c 'SHOW server_version_num') || return 1
    printf '%s pg%s\n' "${1:-$TEMPLATE_FORMAT}" "$((server_version / 10000))"
    sha256sum postgres.dump persons.dump migrations.json
}

# Restores a saved dump pair (<key dir>/<generation>) into fresh templates, once its
# manifest shows it intact and made on this Postgres major.
restore_generation() { # <directory> <format>
    local expected actual
    expected=$(cat "$1/manifest") || return 1
    actual=$(cd "$1" && snapshot_manifest "$2") || return 1
    if [ "$expected" != "$actual" ]; then
        echo "Test database snapshot $1 is incompatible or corrupt. Remove its key directory's current-v3 and rerun to rebuild it." >&2
        return 1
    fi
    reset_templates || return 1
    pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$TEMPLATE_DB" --no-owner --no-acl --exit-on-error "$1/postgres.dump" || return 1
    pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$TEMPLATE_PERSONS_DB" --no-owner --no-acl --exit-on-error "$1/persons.dump"
}

restore_from_snapshots() {
    local generation
    [ -f "$SNAPSHOT_DIR/current-v3" ] || return 1
    generation=$(cat "$SNAPSHOT_DIR/current-v3") || return 1
    [[ "$generation" =~ ^v3\.[a-zA-Z0-9]{8}$ ]] || return 1
    restore_generation "$SNAPSHOT_DIR/$generation" "$TEMPLATE_FORMAT" || return 1
    sync_sqlx_migrations || return 1
    mark_templates_ready || return 1
    echo "Test database cache hit: $TEMPLATE_KEY" >&2
}

dump_snapshots() (
    local directory pointer previous
    validate_template_inputs || return 1
    template_ready || { echo "Test database templates are unverified. Run backend setup before taking a snapshot." >&2; return 1; }
    sync_sqlx_migrations || return 1
    mkdir -p "$SNAPSHOT_DIR" || return 1
    previous=$(cat "$SNAPSHOT_DIR/current-v3" 2>/dev/null || true)
    directory=$(mktemp -d "$SNAPSHOT_DIR/v3.XXXXXXXX") || return 1
    pointer="$directory.pointer"
    trap 'rm -f "$pointer"; rm -rf "$directory"' EXIT
    pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -Fc -d "$TEMPLATE_DB" -f "$directory/postgres.dump" || return 1
    pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -Fc -d "$TEMPLATE_PERSONS_DB" -f "$directory/persons.dump" || return 1
    # What a later key's miss checks before topping this dump up (template_inputs.py base).
    python3 "$TEMPLATE_INPUTS" migrations > "$directory/migrations.json" || return 1
    (cd "$directory" && snapshot_manifest > manifest) || return 1
    printf '%s\n' "${directory##*/}" > "$pointer" || return 1
    # Readers see either complete pair; failed writes leave the previous pair intact.
    mv "$pointer" "$SNAPSHOT_DIR/current-v3" || return 1
    trap - EXIT
    if [[ "$previous" =~ ^v3\.[a-zA-Z0-9]{8}$ ]]; then rm -rf "${SNAPSHOT_DIR:?}/$previous"; fi
    echo "Test database cache saved: $TEMPLATE_KEY" >&2
)

# Runs the bootstrap test, whose session setup migrates the templates: from nothing with
# --create-db, else (keepdb) only the migrations they lack.
# The server ends a session idle in a transaction for 5 minutes (enve.cue, as upstream's
# docker-compose.dev.yml CI runs). Building from nothing (~3060 migrations, 10-45 min) left a
# connection that long on a loaded VM: postgres ended it and the bootstrap failed creating
# posthog_externaldatadestination. Upstream's CI restores a schema dump instead. The
# bootstrap's own sessions run without the limit (PGOPTIONS, libpq's); the tests keep it.
run_bootstrap_test() { # [--create-db]
    PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c idle_in_transaction_session_timeout=0" \
        env -u PYTEST_XDIST_WORKER -u TOX_PARALLEL_ENV -u CLICKHOUSE_DATABASE \
        python3 showcase/scripts/backend_runtime.py exec uv run --no-sync python -m pytest \
        "$@" --reuse-db -p no:cacheprovider -o pythonhashseed=0 --import-mode=importlib -q \
        "$TEMPLATE_BOOTSTRAP_TEST" >&2
}

# A cold build runs minutes without output: say before it starts how long it took last time
# on this machine (the snapshot root is the machine's), else the usual.
COLD_BUILD_SECONDS_FILE="$SNAPSHOT_ROOT/v3/cold-build-seconds"
cold_build_estimate() {
    local last
    last=$(cat "$COLD_BUILD_SECONDS_FILE" 2>/dev/null) || last=
    if [[ "$last" =~ ^[0-9]+$ ]]; then
        echo "the last one here took $((last / 60)) min $((last % 60)) s"
    else
        echo "about 8 min on an M-series Mac, 10-45 min on a loaded VM"
    fi
}

# Builds the templates from no dump: every migration, timed for cold_build_estimate.
cold_build() {
    local started=$SECONDS
    echo "Building the test database templates from all $(python3 "$TEMPLATE_INPUTS" migrations | rg -c '^ *"') migrations: $(cold_build_estimate)." >&2
    reset_templates || return 1
    sync_sqlx_migrations || return 1
    run_bootstrap_test --create-db || return 1
    mkdir -p "${COLD_BUILD_SECONDS_FILE%/*}" && echo "$((SECONDS - started))" > "$COLD_BUILD_SECONDS_FILE"
}

bootstrap_templates() {
    local base
    if [ -e "$SNAPSHOT_DIR/current-v3" ]; then
        restore_from_snapshots
        return $?
    fi
    # A miss tops up the newest dump the checkout's migrations extend, as upstream's CI
    # tops up its newest schema dump: minutes for a new migration, not a full rebuild.
    if base=$(python3 "$TEMPLATE_INPUTS" base "$SNAPSHOT_ROOT/v3") \
        && restore_generation "$base" "$(head -n1 "$base/manifest" | cut -d' ' -f1)"; then
        echo "Test database cache miss: $TEMPLATE_KEY; migrating $base forward." >&2
        sync_sqlx_migrations || return 1
        if ! run_bootstrap_test; then
            # The dump's setup already ran (persons tables moved out of test_posthog): a
            # migration it can't take forward still builds, from nothing.
            echo "Migrating $base forward failed." >&2
            cold_build || return 1
        fi
    else
        echo "Test database cache miss: $TEMPLATE_KEY; no dump to migrate forward." >&2
        # Service startup can restore legacy dumps, so table existence is not provenance.
        cold_build || return 1
    fi
    sync_sqlx_migrations || return 1
    validate_template_inputs || return 1
    mark_templates_ready || return 1
    dump_snapshots
}

# Wait until nothing is connected to the templates; CREATE DATABASE ... TEMPLATE
# refuses a template that has sessions.
wait_templates_free() {
    local deadline=$((SECONDS + ${ENACT_TEMPLATE_FREE_TIMEOUT:-120}))
    while :; do
        local sessions
        sessions=$(pg -d postgres -c "SELECT count(*) FROM pg_stat_activity WHERE datname IN ('$TEMPLATE_DB', '$TEMPLATE_PERSONS_DB')") || return 1
        [ "${sessions:-0}" = "0" ] && return 0
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "Test database templates still have $sessions sessions after ${ENACT_TEMPLATE_FREE_TIMEOUT:-120}s" >&2
            return 1
        fi
        sleep 1
    done
}

clone_database() { # <name> <template>
    database_exists "$1" || pg -d postgres -c "CREATE DATABASE $1 TEMPLATE $2;" >/dev/null
}

# Runs <command...> once the migrated templates are ready, holding the locks that keep other
# workers from building, restoring or cloning them meanwhile.
with_templates() { # <command...>
    mkdir -p "$(dirname "$TEST_DB_LOCK")" || return 1
    (
        flock 9 || exit 1
        mkdir -p "$SNAPSHOT_ROOT" || exit 1
        exec 8>"$SNAPSHOT_ROOT/templates.lock"
        flock 8 || exit 1
        configure_template_cache || exit 1
        if ! template_ready; then bootstrap_templates || exit 1; fi
        sync_sqlx_migrations || exit 1
        wait_templates_free || exit 1
        "$@"
    ) 9>"$TEST_DB_LOCK"
}

# A fresh clone of the migrated Django template (call through with_templates).
fresh_django_clone() { # <name>
    [[ "$1" =~ ^test_[a-z0-9_]{1,50}$ ]] || { echo "Invalid test database name: $1" >&2; return 1; }
    pg -d postgres -c "DROP DATABASE IF EXISTS $1 WITH (FORCE);" >/dev/null || return 1
    clone_database "$1" "$TEMPLATE_DB"
}

# The product databases (products/db_routing.yaml). Django creates their test databases
# from the models (no migrations: data_stores.py), under the worker's name.
product_databases() {
    sed -n 's/^ *database: *\([a-z0-9_]*\) *$/\1/p' products/db_routing.yaml 2>/dev/null | sort -u
}

clone_worker_databases() { # <worker>
    local posthog_db="test_posthog_$1" db
    # Every run starts from fresh clones and an empty ClickHouse database,
    # as upstream jobs start from fresh containers.
    for db in "posthog_$1" "${posthog_db}_persons" "test_dagster_$1" $(product_databases | sed "s/^/${posthog_db}_/"); do
        pg -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE);" >/dev/null || return 1
    done
    clickhouse-client --port "${CLICKHOUSE_TCP_PORT:?the env ClickHouse native port}" -q "DROP DATABASE IF EXISTS posthog_test_$1 SYNC;" >/dev/null || return 1
    fresh_django_clone "$posthog_db" || return 1
    clone_database "${posthog_db}_persons" "$TEMPLATE_PERSONS_DB" || return 1
    # The worker's own database (export_worker_database), empty as upstream's posthog is:
    # tests that write outside Django's test database connect to it (batch_exports'
    # postgres destination).
    pg -d postgres -c "CREATE DATABASE posthog_$1;" >/dev/null || return 1
    pg -d postgres -c "CREATE DATABASE test_dagster_$1;" >/dev/null || return 1
    clickhouse-client --port "${CLICKHOUSE_TCP_PORT:?the env ClickHouse native port}" -q "CREATE DATABASE IF NOT EXISTS posthog_test_$1;" >/dev/null
}

# The worker's database: Django's default (DATABASE_URL), and PGDATABASE, from which
# data_stores.py names the product databases. Their test databases are then
# test_posthog_<worker>[_<product>], the names conftest.py's setup points the product
# aliases at. (pytest-django's TOX_PARALLEL_ENV suffix named them
# test_posthog_<product>_<worker>: the tests reached a database nobody created.)
export_worker_database() { # <worker>
    export PGDATABASE="posthog_$1"
    export DATABASE_URL="postgres://${PGUSER}:${PGPASSWORD:-$PGUSER}@${PGHOST}:${PGPORT}/posthog_$1"
}

# The worker name of a job's shard: <component>_<job>_shard<N>. The jobs of one run share
# its services (one instance per run or slot, not per job), so base:test's shard 1 and
# products:test's shard 1 running at once must not both be "shard1". Lower-case, [a-z0-9_]
# only, and at most WORKER_NAME_MAX: Postgres cuts identifiers at 63 bytes, and the longest
# is test_posthog_<worker>_<product> (13 + 1 + 23 for warehouse_sources_queue). A longer
# component and job keep a prefix and a hash of the whole, so names stay distinct.
WORKER_NAME_MAX=26
test_worker_name() { # <component> <job> <shard>
    local scope="${1}_${2}" suffix="shard${3}" hash
    [ -n "$1$2" ] || { echo "$suffix"; return; }
    scope=$(printf '%s' "$scope" | tr 'A-Z' 'a-z')
    scope="${scope//[^a-z0-9_]/_}"
    if [ $(( ${#scope} + 1 + ${#suffix} )) -gt "$WORKER_NAME_MAX" ]; then
        hash=$(printf '%s' "$scope" | sha256sum) || return 1
        scope="${scope:0:$(( WORKER_NAME_MAX - ${#suffix} - 8 ))}_${hash:0:6}"
    fi
    echo "${scope}_${suffix}"
}

# Exports the worker's environment and creates its databases. Fails loudly.
prepare_worker_databases() { # <worker>
    local worker="$1"
    local persons_db="test_posthog_${worker}_persons"
    local dagster_db="test_dagster_${worker}"
    local ch_db="posthog_test_${worker}"

    [[ "$worker" =~ ^[a-z0-9_]+$ ]] && [ "${#worker}" -le "$WORKER_NAME_MAX" ] || {
        echo "Invalid test worker name: $worker" >&2
        return 1
    }
    with_templates clone_worker_databases "$worker" || return 1

    # Redis numbers its databases (enve.cue starts it with 48). The shard's number n, 1-15:
    # under enact its service slot (ENACT_SERVICE_SLOT), since two jobs' shard N run at once
    # on the run's Redis and their shard numbers would share one; outside enact the worker's
    # trailing number (digits in the component's or job's name are no part of it). Its tests
    # take database 16+n and its AI-gateway tests, which flush theirs, 32+n: 0 and 1 are the
    # Node and Rust suites' (TEST_REDIS_URL and the "/1" feature-flags adds to it).
    local redis_n="${ENACT_SERVICE_SLOT:-}"
    if [ -z "$redis_n" ] && [[ "$worker" =~ ([0-9]+)$ ]]; then redis_n="${BASH_REMATCH[1]}"; fi
    if [ -n "$redis_n" ]; then
        [ "$redis_n" -ge 1 ] && [ "$redis_n" -le 15 ] || {
            echo "Redis has databases for shards 1-15, not $redis_n ($worker)" >&2
            return 1
        }
        export REDIS_URL="redis://${REDIS_HOST:-127.0.0.1}:${REDIS_PORT:?the env redis port}/$(( 16 + redis_n ))"
        export AI_GATEWAY_TEST_REDIS_DB=$(( 32 + redis_n ))
    fi

    [ -f "showcase/scripts/create_test_kafka_topics.py" ] && [ -x ".venv/bin/python" ] || {
        echo "Kafka preparation requires showcase/scripts/create_test_kafka_topics.py and .venv/bin/python. Provision the backend environment and rerun." >&2
        return 1
    }
    .venv/bin/python showcase/scripts/create_test_kafka_topics.py --worker "$worker" || return 1

    export_worker_database "$worker"
    export PYTEST_XDIST_WORKER="$worker"
    export DAGSTER_TEST_POSTGRES_URL="postgresql://${PGUSER}:${PGUSER}@${PGHOST}:${PGPORT}/${dagster_db}"
    export PERSONS_DB_WRITER_URL="postgres://${PGUSER}:${PGUSER}@${PGHOST}:${PGPORT}/${persons_db}"
    export PERSONS_DATABASE_URL="postgres://${PGUSER}:${PGUSER}@${PGHOST}:${PGPORT}/${persons_db}"
    export CLICKHOUSE_DATABASE="$ch_db"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    mkdir -p "$(dirname "$TEST_DB_LOCK")" || exit 1
    exec 9>"$TEST_DB_LOCK"
    flock 9 || exit 1
    mkdir -p "$SNAPSHOT_ROOT" || exit 1
    exec 8>"$SNAPSHOT_ROOT/templates.lock"
    flock 8 || exit 1
    configure_template_cache || exit 1
    case "${1:-}" in
        snapshot)
            dump_snapshots
            ;;
        restore)
            restore_from_snapshots
            ;;
        *)
            echo "Usage: $0 [snapshot|restore]" >&2
            exit 1
            ;;
    esac
fi
