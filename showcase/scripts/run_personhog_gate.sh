#!/usr/bin/env bash
# ci-rust.yml's "PersonHog e2e gate": a real personhog stack (replica, writer, leaders,
# leader-mode routers, identity), spawned by personhog-test-harness against this run's
# Postgres, Kafka and etcd, then the gate's scenarios, each asserting that every acked write
# is visible afterwards (strong reads, Postgres at the acked version), through chaos.
#
#   run_personhog_gate.sh [rust/personhog-test-harness/src/scenarios/gate.rs] [scenario number...]
#
# Without numbers, as upstream: the harness's own tests with --include-ignored (its etcd
# test), then every scenario in upstream's order. With numbers (1-based, as listed below),
# only those scenarios, for iterating on one.
#
# The job's one test is the whole gate, named by its scenarios' module ($gate_test, which
# enact may give, as the test it selected): the scenarios are no files, and they share one
# stack build. In a recording run on Linux
# ($ENACT_FOOTPRINT_DIR, unless $ENACT_FOOTPRINT_TARGETS leaves it out), the gate runs under
# `enact trace run` after the build (the persons database's reset, the harness's prebuilt test
# binary, the scenarios: no cargo, whose freshness check reads every manifest), and
# rust_footprint.py adds what the harness and the services it spawns were built from.
#
# `--run [scenario number...]`: the second phase, the gate itself, in the first's
# environment (GATE_*).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
script="$PWD/showcase/scripts/run_personhog_gate.sh"
gate_test=rust/personhog-test-harness/src/scenarios/gate.rs

# ci-rust.yml's gate steps, in order: one line of `gate` arguments each.
scenarios=(
    "--leaders 2 --partitions 4 --persons 100 --concurrency 10 --duration 10s"
    "--create-via-identity --pg-target-table posthog_person --leaders 3 --partitions 8 --persons 100 --concurrency 10 --duration 15s --kill-after 5s --scale-up-after 8s"
    "--pg-target-table posthog_person --leaders 3 --partitions 8 --persons 200 --concurrency 10 --duration 15s --merge-concurrency 4 --merge-rate 5 --merge-sources 2 --merge-wide-persons 3 --merge-wide-distinct-ids 1000 --merge-wide-role source --kill-after 5s --scale-up-after 8s"
    "--leaders 3 --partitions 8 --persons 50 --concurrency 10 --duration 15s --cache-capacity 4096 --writer-pause-after 3s --writer-pause-duration 8s"
    "--leaders 3 --partitions 8 --persons 100 --concurrency 10 --duration 15s --kill-after 5s --scale-up-after 8s"
    "--leaders 3 --partitions 8 --persons 100 --concurrency 10 --duration 18s --shutdown-after 3s --zombie-after 8s --zombie-duration 6s --writer-pause-after 4s --writer-pause-duration 6s"
    "--leaders 3 --partitions 8 --persons 100 --concurrency 10 --duration 45s --leader-lease-ttl 27 --zombie-after 5s --zombie-duration 32s --writer-pause-after 4s --writer-pause-duration 6s"
    "--leaders 3 --partitions 8 --persons 100 --concurrency 10 --duration 45s --leader-lease-ttl 27 --kill-after 4s --kill-fast false --writer-crash-after 9s --restart-after 12s"
    "--routers 3 --leaders 3 --partitions 8 --persons 100 --concurrency 10 --duration 18s --router-kill-after 4s --shutdown-after 8s --kill-handoff-target"
    "--routers 3 --leaders 3 --partitions 8 --persons 100 --concurrency 10 --duration 15s --router-shutdown-after 4s --shutdown-after 8s"
    "--routers 3 --leaders 3 --partitions 8 --persons 100 --concurrency 10 --duration 18s --router-kill-after 4s --router-kill-fast false --shutdown-after 8s"
)

if [ "${1:-}" = --run ]; then
    shift
    # Upstream's persons database (posthog_persons), the job's own here.
    sqlx database reset -y -D "$GATE_PERSONS" --source rust/persons_migrations
    # Upstream's compose services on this run's instance ports (no /etc/hosts entries
    # needed: every address is given).
    endpoints=(--persons-db-url "$GATE_PERSONS" --kafka-hosts "$GATE_KAFKA" --etcd-endpoints "$GATE_ETCD")
    selected=("$@")
    if [ "${#selected[@]}" -eq 0 ]; then
        # The harness's verification logic (cargo test's, its binary run as cargo runs it);
        # its ignored test needs the etcd.
        (cd rust/personhog-test-harness &&
            CARGO_MANIFEST_DIR="$PWD" CARGO_PKG_NAME=personhog-test-harness ETCD_ENDPOINTS="$GATE_ETCD" \
                "$GATE_HARNESS_TESTS" --include-ignored)
        for i in "${!scenarios[@]}"; do selected+=("$((i + 1))"); done
    fi
    # The stack listens at fixed offsets from one base (upstream's 24051-24170): a block of
    # 120 ports reserved host-wide for this gate (free_ports.sh), moved there by
    # PERSONHOG_HARNESS_PORT_BASE (patches/0019), so gates of other checkouts and machines
    # run side by side.
    ports=120
    port_base="$(PORTS_OWNER=$$ showcase/scripts/free_ports.sh "$ports")"
    trap 'PORTS_OWNER=$$ showcase/scripts/free_ports.sh --release "$port_base" "$ports"' EXIT
    for n in "${selected[@]}"; do
        echo "=== PersonHog e2e gate, scenario $n: ${scenarios[$((n - 1))]} (ports from $port_base)"
        # shellcheck disable=SC2086 # the scenario's arguments
        PERSONHOG_HARNESS_PORT_BASE="$port_base" "$GATE_BIN_DIR/personhog-test-harness" gate \
            --bin-dir "$GATE_BIN_DIR" "${endpoints[@]}" ${scenarios[$((n - 1))]}
    done
    exit 0
fi

# The gate's one test, given as enact's target: the whole gate.
case "${1:-}" in "$gate_test" | */"$gate_test") shift ;; esac

# shellcheck source=test_databases.sh
source showcase/scripts/test_databases.sh
# shellcheck source=rust_ci_env.sh
source showcase/scripts/rust_ci_env.sh

# The persons database, the job's own: the run's other jobs share its Postgres
# (rust_services:test resets posthog_persons).
worker="$(test_worker_name "${ENACT_COMPONENT:-personhog_gate}" "${ENACT_JOB:-test}" 1)"
export GATE_PERSONS="postgres://${PGUSER}:${PGPASSWORD:-posthog}@${PGHOST}:${PGPORT}/${worker}_persons"
export GATE_KAFKA="127.0.0.1:${ENVE_SERVICE_KAFKA_PORT:?kafka is not running}"
export GATE_ETCD="http://127.0.0.1:${ENVE_SERVICE_ETCD_PORT:?etcd is not running}"

# The stack's binaries and the harness's test binary, before the gate.
build=(cargo build -p personhog-replica -p personhog-router -p personhog-leader -p personhog-writer
    -p personhog-identity -p personhog-test-harness)
harness_tests=(cargo test -p personhog-test-harness --no-run --message-format json)
(cd rust && env "${unset_args[@]}" "${build[@]}")
if ! artifacts="$(cd rust && env "${unset_args[@]}" "${harness_tests[@]}")"; then
    jq -r 'select(.reason == "compiler-message") | .message.rendered' <<<"$artifacts" >&2
    exit 1
fi
GATE_HARNESS_TESTS="$(jq -r 'select(.reason == "compiler-artifact" and .profile.test and .executable != null)
    | .executable' <<<"$artifacts" | head -n 1)"
[ -n "$GATE_HARNESS_TESTS" ] || { echo "✗ run_personhog_gate.sh: cargo built no test binary of the harness" >&2; exit 1; }
# The binaries the gate spawns: the target dir's (CARGO_TARGET_DIR's when set), not the
# harness's default, rust/target.
GATE_BIN_DIR="$(cd rust && cargo metadata --no-deps --format-version 1 | jq -r .target_directory)/debug"
export GATE_HARNESS_TESTS GATE_BIN_DIR
gate=(env "${unset_args[@]}" "$script" --run "$@")

if [ -z "${ENACT_FOOTPRINT_DIR:-}" ] || [ "$(uname -s)" != Linux ] ||
    { [ -n "${ENACT_FOOTPRINT_TARGETS:-}" ] && ! rg -qxF "$gate_test" "$ENACT_FOOTPRINT_TARGETS"; }; then
    exec "${gate[@]}"
fi

# Recording: the gate traced, with the services it ran against, then what the harness and the
# stack were built from (the builds' artifacts, no-op rebuilds) and the workspace's graph.
traces="$(mktemp -d)"
trap 'rm -rf "$traces"' EXIT
echo "🎙️  tracing the PersonHog e2e gate ($gate_test) for enact's reach map"
status=0
"${ENACT_EXE:-enact}" trace run --target "$gate_test" --outcomes --no-fingerprint \
    --service-dep postgres --service-dep kafka --service-dep etcd \
    --reach-file "$traces/gate.json" -- "${gate[@]}" || status=1
if (cd rust && env "${unset_args[@]}" "${build[@]}" --message-format json >"$traces/artifacts.jsonl" &&
    cargo metadata --format-version 1 >"$traces/metadata.json"); then
    python3 showcase/scripts/rust_footprint.py --repo "$PWD" --artifacts "$traces/artifacts.jsonl" \
        --metadata "$traces/metadata.json" --recorder "rust_footprint.py/3" --out "$ENACT_FOOTPRINT_DIR" \
        --built-from rust/personhog-test-harness/src/main.rs --built-from rust/personhog-replica/src/main.rs \
        --built-from rust/personhog-router/src/main.rs --built-from rust/personhog-leader/src/main.rs \
        --built-from rust/personhog-writer/src/main.rs --built-from rust/personhog-identity/src/main.rs \
        "$traces/gate.json" || status=1
else
    status=1
fi
exit "$status"
