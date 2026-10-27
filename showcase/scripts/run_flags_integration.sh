#!/usr/bin/env bash
# ci-rust-flags-integration.yml's "Rust /flags Integration Tests": the Rust flags service,
# personhog's replica and router (Django reads persons, groups and cohorts through them) and
# Django's API server, side by side against Postgres and Redis, then
# `pytest posthog/api/test/rust_integration/`, which drives both APIs.
#
# The job's databases are its own clones (the run's other jobs share its Postgres) of the
# migrated templates (test_databases.sh): Django's (upstream migrates test_posthog) and the
# persons database's (upstream runs its sqlx migrations). Every listener takes a free port
# (upstream's 3001, 50051, 50052 and 8000, and the services' metrics ports, are fixed),
# which the tests read from the URLs below.
#
# Arguments: the test files to run, relative to the caller's directory (enact gives them
# from the tests' own, `test_flags.py`); none: the directory's.
#
# In a recording run on Linux ($ENACT_FOOTPRINT_DIR), each test file $ENACT_FOOTPRINT_TARGETS
# names (every one that runs without it) runs alone under `enact trace run`, with the servers
# it drives started inside the trace: its footprint holds what pytest, Django and the
# services read, and rust_footprint.py adds what the services' binaries were built from.
#
# `--serve <test file>...`: the second phase, in the first's environment (FLAGS_*): the
# servers, pytest of the files against them, the servers stopped.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
script="$root/showcase/scripts/run_flags_integration.sh"
serve=0
if [ "${1:-}" = --serve ]; then
    serve=1
    shift
elif [ "$#" -gt 0 ]; then
    # Repository-relative from here on.
    given=()
    for target in "$@"; do
        dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || dir="$(dirname "$target")"
        given+=("${dir#"$root"/}/$(basename "$target")")
    done
    set -- "${given[@]}"
fi
cd "$root"
# shellcheck source=rust_ci_env.sh
source showcase/scripts/rust_ci_env.sh
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

if [ "$serve" -eq 1 ]; then
    # The workflow's environment, besides each step's.
    run=(env "${unset_args[@]}" TEST=1 SECRET_KEY=6b01eee4f945ca25045b5aab440b953461b81b72
        INTERNAL_REQUEST_TOKEN=rust-integration-internal-token
        DATABASE_URL="$FLAGS_DATABASE" REDIS_URL="$FLAGS_REDIS")
    persons="$FLAGS_PERSONS" bin="$FLAGS_BIN"
    flags_port=$(free_port) replica_port=$(free_port) router_port=$(free_port) django_port=$(free_port)

    logs="${ENACT_FLAGS_LOG_DIR:-.enact/state/flags-integration}"
    mkdir -p "$logs"
    pids=()
    stop() {
        local status=$? pid
        for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
        wait 2>/dev/null || true
        if [ "$status" -ne 0 ]; then
            for log in "$logs"/*.log; do echo "=== $log"; tail -n 100 "$log"; done
        fi
    }
    trap stop EXIT

    # Waits until <url> answers (curl) or <port> accepts, failing when <pid> exits first.
    wait_ready() { # <name> <pid> <port> [url]
        local _
        for _ in $(seq 1 60); do
            kill -0 "$2" 2>/dev/null || { echo "$1 exited unexpectedly" >&2; return 1; }
            if [ -n "${4:-}" ]; then
                curl -sf -o /dev/null "$4" && return 0
            elif (exec 3<>"/dev/tcp/127.0.0.1/$3") 2>/dev/null; then
                return 0
            fi
            sleep 2
        done
        echo "$1 is not ready after 120 s" >&2
        return 1
    }

    # Its listen address is ADDRESS (config.rs); upstream's BIND_HOST and BIND_PORT set nothing,
    # and its default, 127.0.0.1:3001, is the port upstream probes.
    (cd rust && exec "${run[@]}" ADDRESS="127.0.0.1:$flags_port" \
        READ_DATABASE_URL="$FLAGS_DATABASE" WRITE_DATABASE_URL="$FLAGS_DATABASE" \
        PERSONS_READ_DATABASE_URL="$persons" PERSONS_WRITE_DATABASE_URL="$persons" \
        COOKIELESS_REDIS_HOST=127.0.0.1 COOKIELESS_REDIS_PORT="$ENVE_SERVICE_REDIS_PORT" \
        CACHE_TTL_SECONDS=0 "$bin/feature-flags") >"$logs/rust-flags.log" 2>&1 &
    pids+=($!)
    wait_ready "Rust flags service" "$!" "$flags_port" "http://127.0.0.1:$flags_port/_readiness"

    "${run[@]}" PRIMARY_DATABASE_URL="$persons" GRPC_ADDRESS="127.0.0.1:$replica_port" METRICS_PORT="$(free_port)" \
        "$bin/personhog-replica" >"$logs/personhog-replica.log" 2>&1 &
    pids+=($!)
    wait_ready personhog-replica "$!" "$replica_port"
    "${run[@]}" REPLICA_URL="http://127.0.0.1:$replica_port" GRPC_ADDRESS="127.0.0.1:$router_port" \
        METRICS_PORT="$(free_port)" "$bin/personhog-router" >"$logs/personhog-router.log" 2>&1 &
    pids+=($!)
    wait_ready personhog-router "$!" "$router_port"

    "${run[@]}" DEBUG=1 TEST=0 PERSONS_DB_WRITER_URL="$persons" PERSONHOG_ADDR="127.0.0.1:$router_port" \
        uv run --no-sync python manage.py runserver "127.0.0.1:$django_port" --noreload >"$logs/django.log" 2>&1 &
    pids+=($!)
    wait_ready "Django server" "$!" "$django_port" "http://127.0.0.1:$django_port/_health"

    "${run[@]}" SKIP_RUST_INTEGRATION_TESTS=0 FEATURE_FLAGS_SERVICE_URL="http://127.0.0.1:$flags_port" \
        DJANGO_API_URL="http://127.0.0.1:$django_port" PERSONS_DATABASE_URL="$persons" PERSONS_DB_WRITER_URL="$persons" \
        uv run --no-sync pytest "$@" -v --tb=short
    exit
fi

# shellcheck source=test_databases.sh
source showcase/scripts/test_databases.sh
worker="$(test_worker_name "${ENACT_COMPONENT:-flags_integration}" "${ENACT_JOB:-test}" 1)"
db="test_posthog_${worker}"
# The name comes as an argument: the templates' bootstrap, in with_templates' subshell, sets
# variables of its own (a `db`) before this runs.
clone_flags_databases() { # <database>
    fresh_django_clone "$1" || return 1
    pg -d postgres -c "DROP DATABASE IF EXISTS ${1}_persons WITH (FORCE);" >/dev/null || return 1
    clone_database "${1}_persons" "$TEMPLATE_PERSONS_DB"
}
pg_url="postgres://${PGUSER}:${PGPASSWORD:-posthog}@${PGHOST}:${PGPORT}"
export FLAGS_DATABASE="$pg_url/$db" FLAGS_PERSONS="$pg_url/${db}_persons"
# Redis database 3 (enve.cue's redis lists each suite's): the flags service reads the flag
# definitions Django writes there.
export FLAGS_REDIS="redis://127.0.0.1:${ENVE_SERVICE_REDIS_PORT:?redis is not running}/3"
# Before each pytest session: its conftest bootstraps its organization, team and user once,
# into databases it takes as new.
fresh_state() {
    with_templates clone_flags_databases "$db"
    redis-cli -u "$FLAGS_REDIS" flushdb >/dev/null
}
# The GeoIP database the flags service resolves (share/ is ignored).
showcase/scripts/exclusive.sh geoip bin/download-mmdb

# Debug builds, without debug assertions in the workspace's crates: the code's debug_assert!
# checks panic on data invariants the tests break on purpose (rust_ci_env.sh's
# rust_no_assertions keeps .cargo/config.toml's rustflags and the shared dependencies).
profile="$(cd rust && rust_no_assertions)"
build=(env "${unset_args[@]}" cargo build -p feature-flags -p personhog-replica -p personhog-router
    --config "$profile")
(cd rust && "${build[@]}")
FLAGS_BIN="$(cd rust && cargo metadata --no-deps --format-version 1 | jq -r .target_directory)/debug"
export FLAGS_BIN

tests=("$@")
[ "${#tests[@]}" -gt 0 ] || tests=(posthog/api/test/rust_integration/)
if [ -z "${ENACT_FOOTPRINT_DIR:-}" ] || [ "$(uname -s)" != Linux ]; then
    fresh_state
    exec "$script" --serve "${tests[@]}"
fi

# Recording: each test file (the directory's, without arguments) $ENACT_FOOTPRINT_TARGETS
# lists, else every one, alone and traced; the others together, untraced.
[ "$#" -gt 0 ] || tests=(posthog/api/test/rust_integration/test_*.py)
wanted_list=""
if [ -n "${ENACT_FOOTPRINT_TARGETS:-}" ]; then
    wanted_list="$(cat "$ENACT_FOOTPRINT_TARGETS")"
else
    for test in "${tests[@]}"; do wanted_list+="$test"$'\n'; done
fi
traces="$(mktemp -d)"
trap 'rm -rf "$traces"' EXIT
status=0 plain=() n=0
for test in "${tests[@]}"; do
    case $'\n'"$wanted_list"$'\n' in
        *$'\n'"$test"$'\n'*)
            n=$((n + 1))
            echo "🎙️  tracing $test, with the servers it drives, for enact's reach map"
            fresh_state
            "${ENACT_EXE:-enact}" trace run --target "$test" --outcomes --no-fingerprint \
                --reach-file "$traces/flags_$n.json" -- "$script" --serve "$test" || status=1
            ;;
        *) plain+=("$test") ;;
    esac
done
[ "${#plain[@]}" -eq 0 ] || { fresh_state && "$script" --serve "${plain[@]}"; } || status=1
if [ "$n" -gt 0 ]; then
    # What the servers were built from: their build's artifacts (a no-op rebuild) and the
    # workspace's dependency graph.
    if (cd rust && "${build[@]}" --message-format json >"$traces/artifacts.jsonl" &&
        cargo metadata --format-version 1 >"$traces/metadata.json"); then
        python3 showcase/scripts/rust_footprint.py --repo "$root" --artifacts "$traces/artifacts.jsonl" \
            --metadata "$traces/metadata.json" --recorder "rust_footprint.py/2" --out "$ENACT_FOOTPRINT_DIR" \
            --built-from rust/feature-flags/src/main.rs --built-from rust/personhog-replica/src/main.rs \
            --built-from rust/personhog-router/src/main.rs "$traces"/flags_*.json || status=1
    else
        status=1
    fi
fi
exit "$status"
