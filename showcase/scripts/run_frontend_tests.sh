#!/usr/bin/env bash
# Runs @posthog/frontend Jest tests, tracing each requested target individually when
# recording (`ENACT_FOOTPRINT_DIR` on Linux) using `jest-attribution.cjs` for skip tracking.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
repo="$PWD"

if [ "$#" -eq 0 ] && [ -n "${ENACT_TARGETS_FILE:-}" ] && [ -f "$ENACT_TARGETS_FILE" ]; then
    targets=()
    while IFS= read -r target || [ -n "$target" ]; do
        if [[ "$target" =~ [^[:space:]] ]]; then targets+=("$target"); fi
    done < "$ENACT_TARGETS_FILE"
    set -- ${targets[@]+"${targets[@]}"}
fi

pattern='^(?!evaluationBackfillsLogic anchors a relative preset on the project timezone$)'
status=0

if [ -n "${ENACT_FOOTPRINT_DIR:-}" ] && [ "$(uname -s)" = Linux ]; then
    if [ "$#" -eq 0 ]; then
        listed=$(CI=true pnpm --filter=@posthog/frontend exec jest --listTests) || exit 1
        while IFS= read -r target; do
            [[ "$target" != *.test.* ]] || set -- "$@" "$target"
        done <<< "$listed"
    fi
    reporter="${ENACT_RECORDERS_DIR:?ENACT_RECORDERS_DIR must be set}/js/jest-attribution.cjs"
    n=0
    rest=()
    for target in "$@"; do
        test=$(realpath -ms --relative-to="$repo" "$target")
        if [ -n "${ENACT_FOOTPRINT_TARGETS:-}" ] && ! rg -qxF -- "$test" "$ENACT_FOOTPRINT_TARGETS"; then
            rest+=("$target")
            continue
        fi
        n=$((n + 1))
        echo "🎙️  tracing $test for enact's reach map"
        CI=true "${ENACT_EXE:-enact}" trace run --node-functions --outcomes --shared-tmpdir --no-fingerprint \
            --reach-file "$ENACT_FOOTPRINT_DIR/frontend-traced-$n.json" -t "$test" -- \
            pnpm --filter=@posthog/frontend exec jest --runInBand --forceExit \
            --reporters=default "--reporters=$reporter" \
            --testNamePattern="$pattern" \
            ${ENACT_TEST_VERBOSE:+--verbose} "$repo/$test" || status=1
    done
    if [ "${#rest[@]}" -eq 0 ]; then
        exit "$status"
    fi
    set -- "${rest[@]}"
fi

CI=true pnpm --filter=@posthog/frontend exec jest --maxWorkers=3 --forceExit \
    --testNamePattern="$pattern" \
    ${ENACT_TEST_VERBOSE:+--verbose} "$@" || { rc=$?; [ "$status" -ne 0 ] || status=$rc; }
exit "$status"
