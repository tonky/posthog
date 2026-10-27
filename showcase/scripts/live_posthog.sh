#!/usr/bin/env bash
# A live PostHog on the run's services, for the jobs that drive one over HTTP
# (run_mcp_integration.sh, run_e2e_tests.sh): upstream's workflows boot it on fixed ports
# with docker compose's services; here every database is the job's own and every listener
# takes a free port, so the job runs beside the run's other jobs.
#
# Source from the checkout root, after test_databases.sh. Then:
#   live_setup <component> <job> <redis db> <log dir>
#       the job's databases (a clone of the migrated Django template, upstream's schema-cache
#       prime; the persons template's clone; an empty ClickHouse database; its Redis
#       database flushed), and `live_run`, the env command every process runs under. Add
#       the job's own variables with `live_run+=(NAME=value ...)`.
#   live_topics, live_migrate        the Kafka topics under the job's prefix; the migrations
#   live_build_rust <package...>     debug builds as upstream's images (`live_bin`); recording
#                                    (after live_record), what their binaries were built from
#   live_start <name> <port> <url|-> <command...>   a process in the background, waited on
#   live_start_personhog, live_start_celery, live_start_web <workers>
#   live_record                      when enact records footprints: from here on, the Python
#                                    processes record what they run for every spec (setup)
#   live_each_spec <start> <run> <spec...>
#       <start> (a function starting the app's processes) then <run> <spec...> (the tests);
#       recording, once per spec: the app started afresh for it, its caches cleared, and the
#       map written (live_footprint.py), every spec holding the inputs of each Rust binary the
#       stack ran (rust_footprint.py --built-from)
# Every process started stops when the job's shell exits; on failure their logs' tails print.

live_free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

live_pids=()
live_stop() {
    local status=$? pid log
    for pid in "${live_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    if [ "$status" -ne 0 ] && [ -n "${live_logs:-}" ]; then
        for log in "$live_logs"/*.log; do
            [ -e "$log" ] || continue
            echo "=== $log"
            tail -n 60 "$log"
        done
    fi
}

live_clone_databases() { # <database>
    fresh_django_clone "$1" || return 1
    pg -d postgres -c "DROP DATABASE IF EXISTS ${1}_persons WITH (FORCE);" >/dev/null || return 1
    clone_database "${1}_persons" "$TEMPLATE_PERSONS_DB"
}

live_setup() { # <component> <job> <redis db> <log dir>
    live_worker="$(test_worker_name "$1" "$2" 1)"
    live_db="test_posthog_${live_worker}"
    live_ch_db="posthog_${live_worker}"
    live_logs="$4"
    rm -rf "$live_logs" && mkdir -p "$live_logs"
    trap live_stop EXIT

    with_templates live_clone_databases "$live_db"
    live_ch=(clickhouse-client --port "${CLICKHOUSE_TCP_PORT:?the env ClickHouse native port}")
    "${live_ch[@]}" -q "DROP DATABASE IF EXISTS ${live_ch_db} SYNC" >/dev/null
    # The system log tables exist once flushed (upstream's init-db.sh): migration 0159's view
    # reads system.crash_log.
    "${live_ch[@]}" -q "SYSTEM FLUSH LOGS" >/dev/null

    live_pg_url="postgres://${PGUSER}:${PGPASSWORD:-posthog}@${PGHOST}:${PGPORT}"
    live_database="$live_pg_url/$live_db"
    live_persons="$live_pg_url/${live_db}_persons"
    live_redis="redis://127.0.0.1:${ENVE_SERVICE_REDIS_PORT:?redis is not running}/$3"
    redis-cli -u "$live_redis" flushdb >/dev/null
    live_replica_port=$(live_free_port) live_router_port=$(live_free_port) live_web_port=$(live_free_port)

    # The workflows' shared environment, over the profile's test settings: TEST unset, so Django
    # boots as upstream's does (ClickHouse writes go through Kafka, no product routing).
    # OIDC_RSA_PRIVATE_KEY is upstream's fake-key variable, made here as the settings make one
    # under TEST. CELERY_WORKER_QUEUES as "Source celery queues" exports it.
    local oidc_key
    oidc_key="$(uv run --no-sync python -c 'from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric import rsa
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
print(key.private_bytes(s.Encoding.PEM, s.PrivateFormat.TraditionalOpenSSL, s.NoEncryption()).decode())')"
    # shellcheck source=/dev/null
    source bin/celery-queues.env
    live_run=(env -u TEST -u PYTEST_XDIST_WORKER
        DATABASE_URL="$live_database" PERSONS_DB_WRITER_URL="$live_persons"
        POSTHOG_PERSONS_DB_NAME="${live_db}_persons"
        PERSONHOG_ADDR="127.0.0.1:$live_router_port" REDIS_URL="$live_redis"
        CLICKHOUSE_DATABASE="$live_ch_db" CLICKHOUSE_SECURE=False CLICKHOUSE_VERIFY=False
        CLICKHOUSE_LOGS_CLUSTER_SECURE=False KAFKA_PREFIX="${live_worker}_"
        SKIP_SERVICE_VERSION_REQUIREMENTS=1 NO_RESTART_LOOP=1 DISABLE_SECURE_SSL_REDIRECT=True
        CELERY_METRICS_PORT="$(live_free_port)" INTERNAL_API_SECRET=posthog123
        OIDC_RSA_PRIVATE_KEY="$oidc_key" CELERY_WORKER_QUEUES="$CELERY_WORKER_QUEUES")
}

live_py() { "${live_run[@]}" uv run --no-sync python "$@"; }

# The topics the job's ClickHouse tables consume and its code produces, under its prefix
# (create_test_kafka_topics.py's list, unsuffixed as TEST unset names them).
live_topics() {
    live_py - <<'PY'
import os
import sys

sys.path.insert(0, "showcase/scripts")
from confluent_kafka.admin import AdminClient, NewTopic

import create_test_kafka_topics as topics

prefix = os.environ["KAFKA_PREFIX"]
admin = AdminClient({"bootstrap.servers": os.environ["KAFKA_HOSTS"]})
existing = set(admin.list_topics(timeout=30).topics)
wanted = sorted({prefix + t for t in set(topics.topic_names()) | topics.listed_topics()} - existing)
if wanted:
    for future in admin.create_topics([NewTopic(t, num_partitions=1, replication_factor=1) for t in wanted]).values():
        future.result()
print(f"created {len(wanted)} Kafka topics under {prefix}")
PY
}

# "Prime posthog from cached schema" and the migrations: the template, like upstream's schema
# dump, lacks the routed product apps' tables, whose migration records go so `migrate` creates
# them on the default database. Then ClickHouse's (it reads posthog_instancesetting).
live_migrate() {
    local apps
    apps=$(python3 -c 'import re,sys; print(",".join(sorted({"%s%s%s" % (chr(39), m, chr(39)) for m in re.findall(r"app_label:\s*(\w+)", open("products/db_routing.yaml").read())})))')
    [ -z "$apps" ] || pg -d "$live_db" -c "DELETE FROM django_migrations WHERE app IN ($apps);" >/dev/null
    live_py manage.py migrate --noinput
    live_py manage.py migrate_clickhouse
    # Django renders these for the pages a readiness check fetches (upstream's "Set up needed
    # files"); a built frontend's stay.
    mkdir -p frontend/dist
    local page
    for page in index layout exporter; do [ -e "frontend/dist/$page.html" ] || touch "frontend/dist/$page.html"; done
    showcase/scripts/exclusive.sh geoip bin/download-mmdb
}

# Debug builds without debug assertions in the workspace's crates, as upstream's images (the
# code's debug_assert! checks panic on data invariants mid-run): rust_ci_env.sh's
# rust_no_assertions, which keeps .cargo/config.toml's rustflags and the shared dependencies.
# Recording, the build's artifacts (a no-op rebuild) and the workspace's graph go to
# live_rust_footprint, with each package's binary (`$live_bin/<package>`) by its root file.
live_rust_roots=()
live_build_rust() { # <package...>
    local args=() package root profile
    for package in "$@"; do args+=(-p "$package"); done
    profile="$(source showcase/scripts/rust_ci_env.sh && cd rust && rust_no_assertions)"
    local build=(env -u REDIS_URL CARGO_INCREMENTAL=0 CARGO_PROFILE_DEV_DEBUG=0
        cargo build "${args[@]}" --config "$profile")
    (cd rust && "${build[@]}")
    live_bin="$(cd rust && cargo metadata --no-deps --format-version 1 | jq -r .target_directory)/debug"
    [ -n "$live_recording" ] || return 0
    mkdir -p "$live_recording/rust"
    (cd rust && "${build[@]}" --message-format json >>"$live_recording/rust/artifacts.jsonl" &&
        cargo metadata --format-version 1 >"$live_recording/rust/metadata.json")
    for package in "$@"; do
        root="$(jq -r --arg p "$package" '.workspace_members as $members | .packages[]
            | select(.name == $p and (.id | IN($members[]))) | .targets[]
            | select(.name == $p and (.kind | index("bin"))) | .src_path' "$live_recording/rust/metadata.json")"
        [ -n "$root" ] || { echo "live_build_rust: $package builds no binary named $package" >&2; return 1; }
        live_rust_roots+=("$root")
    done
}

# The maps live_footprint.py wrote in <dir>, into $ENACT_FOOTPRINT_DIR with what every Rust
# binary the stack ran was built from added to each spec (rust_footprint.py --built-from):
# a spec drives them all (capture, the flags service, personhog), and a change to their code
# reaches it only through their build.
live_rust_footprint() { # <dir>
    local maps=("$1"/*.json) args=() root
    [ -e "${maps[0]}" ] || return 0
    mkdir -p "$ENACT_FOOTPRINT_DIR"
    cp "$1"/*.stats "$ENACT_FOOTPRINT_DIR"/ 2>/dev/null || true
    if [ "${#live_rust_roots[@]}" -eq 0 ]; then
        cp "${maps[@]}" "$ENACT_FOOTPRINT_DIR"/
        return
    fi
    for root in "${live_rust_roots[@]}"; do args+=(--built-from "$root"); done
    python3 showcase/scripts/rust_footprint.py --repo "$PWD" --artifacts "$live_recording/rust/artifacts.jsonl" \
        --metadata "$live_recording/rust/metadata.json" --recorder "rust_footprint.py/2" --out "$ENACT_FOOTPRINT_DIR" \
        "${args[@]}" "${maps[@]}" || return 1
    echo "live_footprint: the build inputs of ${#live_rust_roots[@]} Rust binaries -> $ENACT_FOOTPRINT_DIR" >&2
}

# Waits until <url> answers (curl) or <port> accepts, failing when <pid> exits first.
live_wait_ready() { # <name> <pid> <port> <url|-> [tries]
    local _
    for _ in $(seq 1 "${5:-60}"); do
        kill -0 "$2" 2>/dev/null || { echo "$1 exited unexpectedly" >&2; return 1; }
        if [ "$4" != "-" ]; then
            curl -s -o /dev/null "$4" && return 0
        elif (exec 3<>"/dev/tcp/127.0.0.1/$3") 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    echo "$1 is not ready after $((${5:-60} * 2)) s" >&2
    return 1
}

# Starts <command...> in the background, logging to <name>.log, and waits for it on <port>
# (or <url>); a port of 0 doesn't wait. LIVE_TRIES overrides the 60 tries 2 s apart, LIVE_CWD
# the directory it runs in.
live_start() { # <name> <port> <url|-> <command...>
    local name="$1" port="$2" url="$3"
    shift 3
    (cd "${LIVE_CWD:-.}" && exec "$@") >"$live_logs/$name.log" 2>&1 &
    live_pids+=($!)
    [ "$port" = 0 ] || live_wait_ready "$name" "$!" "$port" "$url" "${LIVE_TRIES:-60}"
}

# compose's personhog-replica and personhog-router: person reads go through them (no ORM
# fallback), so they run before anything creates persons.
live_start_personhog() {
    live_start personhog-replica "$live_replica_port" - "${live_run[@]}" PRIMARY_DATABASE_URL="$live_persons" \
        GRPC_ADDRESS="127.0.0.1:$live_replica_port" METRICS_PORT="$(live_free_port)" "$live_bin/personhog-replica"
    live_start personhog-router "$live_router_port" - "${live_run[@]}" \
        REPLICA_URL="http://127.0.0.1:$live_replica_port" GRPC_ADDRESS="127.0.0.1:$live_router_port" \
        METRICS_PORT="$(live_free_port)" "$live_bin/personhog-router"
}

# "Start PostHog web & Celery worker". --no-reload: upstream's watchman thread has no
# watchman to reach either.
live_start_celery() {
    live_start celery 0 - "${live_run[@]}" uv run --no-sync python manage.py run_autoreload_celery --type=worker --no-reload
}

live_start_web() { # <workers>
    LIVE_TRIES=90 live_start server "$live_web_port" "http://127.0.0.1:$live_web_port" \
        "${live_run[@]}" uv run --no-sync python -m granian --interface asgi posthog.asgi:application \
        --host 127.0.0.1 --port "$live_web_port" --workers "$1"
}

# Footprints (ENACT_FOOTPRINT_DIR set, live_footprint.py): the Python processes started from
# here on record through enact_footprint's child mode, setup for every spec ('<shared>').
live_recording=""
live_record() {
    [ -n "${ENACT_FOOTPRINT_DIR:-}" ] || return 0
    live_recording="$(mktemp -d "${TMPDIR:-/tmp}/live-footprint.XXXXXX")"
    uv run --no-sync python showcase/scripts/live_footprint.py prepare "$live_recording"
    live_run+=(ENACT_FOOTPRINT_ROOT="$PWD" ENACT_FOOTPRINT_CHILDREN="$live_recording"
        ENACT_FOOTPRINT_CORE="$PWD/showcase/pytest_plugins/enact_footprint.py" ENACT_FOOTPRINT_TARGET='<shared>'
        PYTHONPATH="$live_recording/boot${PYTHONPATH:+:$PYTHONPATH}")
}

# Stops the processes started since live_pids held <count>, SIGTERM first (a recording process
# writes its record as it exits), and forgets them.
live_stop_from() { # <count>
    local pid _
    for pid in "${live_pids[@]:$1}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${live_pids[@]:$1}"; do
        for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    live_pids=("${live_pids[@]:0:$1}")
}

# What the app cached in Redis (Django's caches, the query cache, posthog's own keys), not
# Celery's queues: a spec mustn't be served what the code of an earlier one computed.
live_clear_caches() {
    local keep keys
    keep="^(_kombu\..*|unacked.*|${CELERY_WORKER_QUEUES//,/|})\$"
    keys="$(redis-cli -u "$live_redis" --scan | rg -v "$keep" || true)"
    [ -z "$keys" ] || printf '%s\n' "$keys" | tr '\n' '\0' | xargs -0 -n 500 redis-cli -u "$live_redis" del >/dev/null
}

# Runs <run> with the specs against the app <start> starts. Recording, each spec alone against
# an app started afresh for it, its Redis caches cleared, then the map of them all. Its locals
# are prefixed: <start> and <run> see them (bash scopes dynamically), and a job's own `results`
# went unbound under one.
live_each_spec() { # <start> <run> <spec...>
    local each_start="$1" each_run="$2" each_spec each_n=0 each_status each_mark each_result each_results=()
    shift 2
    if [ -z "$live_recording" ]; then
        "$each_start"
        "$each_run" "$@"
        return
    fi
    local each_run_base=("${live_run[@]}")
    for each_spec in "$@"; do
        each_n=$((each_n + 1))
        each_mark=${#live_pids[@]}
        live_clear_caches
        live_run=("${each_run_base[@]}" ENACT_FOOTPRINT_TARGET="$each_spec")
        "$each_start"
        each_status=0
        ENACT_NODE_READS="$live_recording/node/$each_n" ENACT_FOOTPRINT_ROOT="$PWD" \
            NODE_OPTIONS="--import $PWD/showcase/scripts/node_reads.mjs${NODE_OPTIONS:+ $NODE_OPTIONS}" \
            "$each_run" "$each_spec" || each_status=$?
        live_stop_from "$each_mark"
        each_results+=("$each_spec=$each_status")
    done
    live_run=("${each_run_base[@]}")
    ENACT_FOOTPRINT_DIR="$live_recording/maps" LIVE_JOB="${0##*/}" \
        uv run --no-sync python showcase/scripts/live_footprint.py write "$live_recording" "${each_results[@]}"
    each_status=0
    live_rust_footprint "$live_recording/maps" || each_status=1
    rm -rf "$live_recording"
    [ "$each_status" -eq 0 ] || return 1
    for each_result in "${each_results[@]}"; do [ "${each_result##*=}" = 0 ] || return 1; done
}
