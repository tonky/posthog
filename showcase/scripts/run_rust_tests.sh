#!/usr/bin/env bash
# The rust workspace's tests, as ci-rust.yml's test job runs them: the databases first (the
# Django schema the services read, the persons and behavioral-cohorts sqlx migrations), then
# each package's tests on its own (`cargo nextest run --profile ci -p <package>`: one retry,
# in the package's own feature resolution) and its doctests. Arguments: the test binaries to
# run, each by its root file, relative to the caller's directory (from the checkout:
# rust/<package>/src/lib.rs for the library's unit tests, src/main.rs, src/bin/<x>.rs,
# tests/<x>.rs); none: every package's.
# --ignored: instead, the `--run-ignored only` steps ci-rust.yml runs after a package's tests
# (cymbal's and usage-ingestion's: ignored_tests below), each test by the file declaring it
# (rust_services:test_ignored's targets); none: all of them.
#
# In a recording run on Linux ($ENACT_FOOTPRINT_DIR), each target $ENACT_FOOTPRINT_TARGETS
# names (all it runs without it) runs alone under `enact trace run`, and rust_footprint.py adds
# what its test binary was built from to its footprint.
set -euo pipefail
ignored=0
if [ "${1:-}" = "--ignored" ]; then ignored=1; shift; fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# enact gives the targets relative to the task's directory (rust/, as `../rust/<x>`): from
# here on they are repository-relative.
if [ "$#" -gt 0 ]; then
    given=()
    for target in "$@"; do
        dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || dir="$(dirname "$target")"
        given+=("${dir#"$root"/}/$(basename "$target")")
    done
    set -- "${given[@]}"
fi

# ci-rust.yml's `--run-ignored only` steps: each package's filter, the step's own, and the
# tests they run, by the file declaring them (test_ignored's target_scope.tests), with their
# nextest binary. tests/overlay.rs holds these to ci-rust.yml's steps and the suite.
ignored_filter() {
    case "$1" in
        # The rate limiter's Redis tests: cymbal's other ignored ones (the notifications'
        # token bucket) don't match it, and ci-rust.yml runs none of them.
        cymbal) echo 'test(rate_limiting)' ;;
        usage-ingestion) echo '' ;;
        *) return 1 ;;
    esac
}
ignored_tests=(
    "rust/cymbal/src/modes/processing/stages/rate_limiting/limiter.rs cymbal"
    "rust/usage-ingestion/tests/e2e.rs usage-ingestion::e2e"
    "rust/usage-ingestion/tests/load.rs usage-ingestion::load"
    "rust/usage-ingestion/tests/counters.rs usage-ingestion::counters"
)
if [ "$ignored" -eq 1 ] && [ "$#" -eq 0 ]; then
    for row in "${ignored_tests[@]}"; do set -- "$@" "${row%% *}"; done
fi
cd "$root"
# shellcheck source=test_databases.sh
source showcase/scripts/test_databases.sh

pg_url="postgres://${PGUSER}:${PGPASSWORD:-posthog}@${PGHOST}:${PGPORT}"
persons="$pg_url/posthog_persons"
if [ "$ignored" -eq 0 ]; then
# ci-rust.yml's setup_test_environment migrates test_posthog, which feature-flags reads
# (TEST_DATABASE_URL) and the behavioral cohorts migrate into. Here test_posthog is the
# backend's template, so the tests get a clone of it.
    with_templates fresh_django_clone test_posthog_rust
    export TEST_DATABASE_URL="$pg_url/test_posthog_rust"
    DATABASE_URL="$TEST_DATABASE_URL" sqlx migrate run --source rust/behavioral_cohorts_migrations
    sqlx database reset -y -D "$persons" --source rust/persons_migrations
    # As ci-rust.yml: the persons database feature-flags reads and writes.
    export PERSONS_READ_DATABASE_URL="$persons" PERSONS_WRITE_DATABASE_URL="$persons"
    # As ci-rust.yml: the GeoIP database the feature-flags handler tests resolve (share/ is ignored).
    showcase/scripts/exclusive.sh geoip bin/download-mmdb
elif [[ " $* " == *" rust/usage-ingestion/"* ]]; then
    # (cymbal's ignored tests need their Redis alone.) usage-ingestion's e2e and load tests read ClickHouse's billing usage records, which its
    # Kafka engine table consumes from the topic the service produces to. ci-rust.yml's
    # setup_test_environment creates them in posthog_test, beside the suffixed topics. The jobs
    # of a run share its ClickHouse and Kafka (the nodejs suite resets posthog_test), so this
    # job's are a backend shard's: Django suffixes the database and every topic with
    # PYTEST_XDIST_WORKER (posthog_test_<worker>, <topic>_test_<worker>).
    worker="$(test_worker_name "${ENACT_COMPONENT:-rust_services}" "${ENACT_JOB:-test_ignored}" 1)"
    PYTEST_XDIST_WORKER="$worker" TEST=1 uv run --no-sync python manage.py setup_test_environment --only-clickhouse
    uv run --no-sync python showcase/scripts/create_test_kafka_topics.py --worker "$worker"
fi
# ci-rust.yml's environment: none of the profile's settings (rust_ci_env.sh).
# shellcheck source=rust_ci_env.sh
source showcase/scripts/rust_ci_env.sh

# Where the tests reach the services: this run's instance ports (enve E7), which the tests read
# from these variables (patches/0002) instead of the ports upstream's compose stack publishes.
# Passed after the unsets: DATABASE_URL and KAFKA_HOSTS are profile names too. DATABASE_URL is
# what sqlx::test connects to, else rust/.env's. Object storage by address: an S3 client
# addresses a bucket on a host name as `<bucket>.<host>` (common-s3's), which glibc doesn't
# resolve for localhost; on an IP it uses the path.
endpoints=(
    DATABASE_URL="$pg_url/posthog"
    TEST_PERSONS_DATABASE_URL="$persons"
    TEST_REDIS_URL="redis://127.0.0.1:${ENVE_SERVICE_REDIS_PORT:?redis is not running}/"
    KAFKA_HOSTS="127.0.0.1:${ENVE_SERVICE_KAFKA_PORT:?kafka is not running}"
    OBJECT_STORAGE_ENDPOINT="http://127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT:?seaweedfs is not running}"
    ETCD_ENDPOINT="http://127.0.0.1:${ENVE_SERVICE_ETCD_PORT:?etcd is not running}"
    # No container runtime: the testcontainers tests (the k3s_integration binaries and
    # common-redis's) boot theirs in Docker, which the services here never run in. A host
    # with Docker (OrbStack's socket on the Mac) would otherwise start them. cymbal's read
    # TEST_REDIS_URL instead (patches/0003).
    DOCKER_HOST="unix:///nonexistent/docker.sock"
)

# The tests the job's target_scope.not_run leaves out (components.cue says why): the
# k3s_integration binaries, each test booting Kubernetes in Docker. Left out by binary, as
# `<package>::<binary>`; tests/overlay.rs holds this list to the not_run files.
not_run=(
    k8s-awareness::k3s_integration
    kafka-assigner::k3s_integration
    personhog-coordination::k3s_integration
)

cd rust
# The overlay's scheduling over upstream's nextest config (rust_nextest.toml says why).
tool_config="posthog-overlay:$(cd ../showcase/scripts && pwd)/rust_nextest.toml"

# Every workspace member's test binaries (`cargo metadata`'s targets cargo tests), by root
# file, with its package and nextest binary id. A target needing a feature the build doesn't
# enable builds no test binary (components.cue's not_run). Plain arrays, and empty ones
# expanded as ${a[@]+...}: the overlay's tests run this with macOS's bash 3.
repo="$(cd .. && pwd)"
metadata="$(cargo metadata --no-deps --format-version 1)"
members=() files=() packages=() binary_ids=() doctests=()
while IFS= read -r package; do members+=("$package"); done < <(jq -r '.packages[].name' <<<"$metadata" | sort)
while IFS=$'\t' read -r file package binary doc; do
    files+=("$file") packages+=("$package") binary_ids+=("$binary") doctests+=("$doc")
done < <(jq -r '(.workspace_root + "/") as $ws | .packages[] | .name as $p | .targets[]
    | select(.test and ((."required-features" // []) | length == 0))
    | ["rust/" + (.src_path | ltrimstr($ws)), $p,
       (if .kind[0] == "bin" then "\($p)::bin/\(.name)" elif .kind[0] == "test" then "\($p)::\(.name)" else $p end),
       (if (.kind | index("lib")) then "doc" else "-" end)]
    | @tsv' <<<"$metadata" | sort)

# What runs: each target (run_targets) and its binary (run_ix, an index into those). The
# given binaries, else every one but the not_run ones; with --ignored, the given ignored
# tests' files, each with the binary ignored_tests names.
run_ix=() run_targets=()
if [ "$ignored" -eq 0 ] && [ "$#" -eq 0 ]; then
    for i in "${!files[@]}"; do
        skip=0
        for binary in "${not_run[@]}"; do [ "${binary_ids[$i]}" = "$binary" ] && skip=1; done
        [ "$skip" -eq 1 ] || { run_ix+=("$i") && run_targets+=("${files[$i]}"); }
    done
fi
for file in "$@"; do
    found="" binary=""
    if [ "$ignored" -eq 1 ]; then
        for row in "${ignored_tests[@]}"; do [ "${row%% *}" = "$file" ] && binary="${row#* }"; done
        [ -n "$binary" ] || { echo "✗ run_rust_tests.sh: $file declares no ignored test ci-rust.yml runs" >&2; exit 64; }
    fi
    for i in "${!files[@]}"; do
        if [ -n "$binary" ]; then [ "${binary_ids[$i]}" = "$binary" ]; else [ "${files[$i]}" = "$file" ]; fi \
            && found="$i" && break
    done
    [ -n "$found" ] || { echo "✗ run_rust_tests.sh: $file is no test binary's root file" >&2; exit 64; }
    run_ix+=("$found") run_targets+=("$file")
done

# A package's build: `-p <package>` alone, as ci-rust.yml's. Each package resolves its own
# features: built together, the workspace's resolution would differ from a package's own
# (rustls with both crypto providers, serde_json's float_roundtrip, flate2's zlib-rs backend)
# and fail tests upstream passes. cohort-seeder's tests need ci-rust.yml's features.
own_build() {
    own=(-p "$1")
    if [ "$1" = cohort-seeder ]; then own+=(--features "pg-test-support,ch-test-support"); fi
}

# Recording: the binaries to trace, on Linux only (enact's tracer is seccomp's): those
# $ENACT_FOOTPRINT_TARGETS lists, else every one that runs.
record=0 wanted_list=""
if [ -n "${ENACT_FOOTPRINT_DIR:-}" ] && [ "$(uname -s)" = Linux ]; then
    record=1
    if [ -n "${ENACT_FOOTPRINT_TARGETS:-}" ]; then
        wanted_list="$(cat "$ENACT_FOOTPRINT_TARGETS")"
    else
        for target in ${run_targets[@]+"${run_targets[@]}"}; do wanted_list+="$target"$'\n'; done
    fi
    traces="$(mktemp -d)"
    trap 'rm -rf "$traces"' EXIT
    mkdir "$traces/build"
    cargo metadata --format-version 1 >"$traces/build/metadata.json"
fi
wanted() { case $'\n'"$wanted_list"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

status=0 passed=()
# <package> <filter> [command prefix...]: the package's run, as ci-rust.yml's. With $prebuilt
# (`nextest list`'s binaries of the package), it runs those without cargo: a traced run then
# holds what its tests read, not what cargo reads checking the build is fresh (every
# member's manifest and target directories).
prebuilt=""
# A filter of binaries, within the package's ignored step's own filter ($tests).
with_tests() { if [ -n "$tests" ]; then echo "($1) & $tests"; else echo "$1"; fi; }
nextest() {
    local package="$1" filter="$2"
    shift 2
    local own
    own_build "$package"
    local args=(--profile ci --tool-config-file "$tool_config" --no-tests=pass -E "$filter")
    # As ci-rust.yml's ignored steps: one at a time (the load test's throughput stays clean).
    [ "$ignored" -eq 0 ] || args+=(--run-ignored only --test-threads=1)
    local nextest=(cargo nextest run "${own[@]}")
    if [ -n "$prebuilt" ]; then
        nextest=(cargo-nextest nextest run --binaries-metadata "$prebuilt"
            --cargo-metadata "$traces/build/metadata.json" --workspace-remap "$PWD")
    fi
    local run=(env "${unset_args[@]}" "${endpoints[@]}")
    case "$ignored:$package" in
        # Its sqlx pool's limit.
        0:property-defs-rs) args+=(--test-threads=4) ;;
        # The Postgres and ClickHouse tests, against the Django schema's database and this
        # run's ClickHouse (the seeder's CLICKHOUSE_URL; upstream's is its default
        # localhost:8123).
        0:cohort-seeder)
            run+=(DATABASE_URL="$TEST_DATABASE_URL"
                CLICKHOUSE_URL="http://127.0.0.1:${ENVE_SERVICE_CLICKHOUSE_PORT:?clickhouse is not running}")
            ;;
        # The rate limiter's tests each empty their Redis first (patches/0003): a database of
        # their own (enve.cue's redis).
        1:cymbal) run+=(TEST_REDIS_URL="redis://127.0.0.1:${ENVE_SERVICE_REDIS_PORT}/2") ;;
        # The e2e, load and counters tests, on this job's database and topic, and the
        # cluster-enabled Valkey (the counters' default 127.0.0.1:6390, compose's).
        1:usage-ingestion)
            run+=(USAGE_INGESTION_E2E_CLICKHOUSE_DATABASE="posthog_test_${worker}"
                USAGE_INGESTION_E2E_TOPIC="clickhouse_billing_usage_records_test_${worker}"
                USAGE_INGESTION_E2E_LOAD_REQUESTS=2000
                USAGE_INGESTION_E2E_KAFKA_HOSTS="127.0.0.1:${ENVE_SERVICE_KAFKA_PORT}"
                USAGE_INGESTION_E2E_CLICKHOUSE_URL="http://127.0.0.1:${ENVE_SERVICE_CLICKHOUSE_PORT:?clickhouse is not running}"
                USAGE_INGESTION_REDIS_URL="redis://127.0.0.1:${ENVE_SERVICE_VALKEY_CLUSTER_PORT:?valkey-cluster is not running}")
            ;;
    esac
    "$@" "${run[@]}" "${nextest[@]}" "${args[@]}"
}

# As ci-rust.yml's test job: each package on its own and every one of them (a failure doesn't
# skip the packages after it); a recorded binary in a run of its own, traced.
for package in "${members[@]}"; do
    plain=() traced=()
    for k in ${run_ix[@]+"${!run_ix[@]}"}; do
        [ "${packages[${run_ix[$k]}]}" = "$package" ] || continue
        if [ "$record" -eq 1 ] && wanted "${run_targets[$k]}"; then traced+=("$k"); else plain+=("$k"); fi
    done
    [ "${#plain[@]}" -gt 0 ] || [ "${#traced[@]}" -gt 0 ] || continue
    # A package's ignored step keeps ci-rust.yml's filter.
    tests=""
    if [ "$ignored" -eq 1 ]; then tests="$(ignored_filter "$package")"; fi
    if [ "${#plain[@]}" -gt 0 ]; then
        filter=""
        for k in ${plain[@]+"${plain[@]}"}; do filter+="${filter:+ | }binary_id(=${binary_ids[${run_ix[$k]}]})"; done
        nextest "$package" "$(with_tests "$filter")" || status=1
    fi
    [ "${#traced[@]}" -gt 0 ] || continue
    # The traced binaries: built (and listed) untraced, then each run alone under the tracer.
    own_build "$package"
    prebuilt="$traces/build/$package.json"
    if ! env "${unset_args[@]}" "${endpoints[@]}" cargo nextest list "${own[@]}" --list-type binaries-only \
        --message-format json >"$prebuilt"; then
        status=1 prebuilt=""
        continue
    fi
    for k in ${traced[@]+"${traced[@]}"}; do
        target="${run_targets[$k]}" filter="binary_id(=${binary_ids[${run_ix[$k]}]})"
        if nextest "$package" "$(with_tests "$filter")" \
            "$ENACT_EXE" trace run --target "$target" --outcomes --no-fingerprint \
            --reach-file "$traces/$(printf '%s' "$target" | tr '/' '_').json" --; then
            # One that read nothing in the repository leaves no footprint: rust_footprint.py
            # gives it what it was built from.
            passed+=(--passed "$target")
        else
            status=1
        fi
    done
    prebuilt=""
done

if [ "$record" -eq 1 ] && { compgen -G "$traces/rust_*.json" >/dev/null || [ "${#passed[@]}" -gt 0 ]; }; then
    # What each traced binary was built from (rust_footprint.py): its package's build
    # artifacts, as nextest built them (a no-op rebuild), and the workspace's dependency graph.
    : >"$traces/artifacts.jsonl"
    built=1
    # A target named by the file declaring its tests (--ignored) takes its binary's.
    binaries=()
    for k in ${run_ix[@]+"${!run_ix[@]}"}; do
        [ "${run_targets[$k]}" = "${files[${run_ix[$k]}]}" ] \
            || binaries+=(--binary "${run_targets[$k]}=${files[${run_ix[$k]}]}")
    done
    for package in "${members[@]}"; do
        for k in ${run_ix[@]+"${!run_ix[@]}"}; do
            [ "${packages[${run_ix[$k]}]}" = "$package" ] && wanted "${run_targets[$k]}" || continue
            own_build "$package"
            env "${unset_args[@]}" "${endpoints[@]}" cargo test --no-run --message-format json "${own[@]}" \
                >>"$traces/artifacts.jsonl" || built=0
            break
        done
    done
    if [ "$built" -eq 1 ]; then
        maps=()
        for map in "$traces"/rust_*.json; do [ -e "$map" ] && maps+=("$map"); done
        python3 ../showcase/scripts/rust_footprint.py --repo "$repo" --artifacts "$traces/artifacts.jsonl" \
            --metadata "$traces/build/metadata.json" --recorder "rust_footprint.py/3" \
            --out "$ENACT_FOOTPRINT_DIR" ${binaries[@]+"${binaries[@]}"} ${passed[@]+"${passed[@]}"} \
            ${maps[@]+"${maps[@]}"} || status=1
    else
        status=1
    fi
fi

# As ci-rust.yml's, the doctests of each package whose library's unit tests ran: a `lib`
# target's (`cargo test --doc` fails on a package without one, a cdylib's too).
# The ignored steps run none.
for i in ${run_ix[@]+"${run_ix[@]}"}; do
    if [ "$ignored" -eq 0 ] && [ "${doctests[$i]}" = doc ]; then
        env "${unset_args[@]}" "${endpoints[@]}" cargo test --doc -p "${packages[$i]}" || status=1
    fi
done
exit "$status"
