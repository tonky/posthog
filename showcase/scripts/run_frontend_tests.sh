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
ignore_dirs='/products/([^/]+/(backend|dags|eval|evals|eval_harness|mcp|skills|opensearch|scout|stats|fixtures|management|observability|plan|adr|agent|scripts)|desktop|visual_review/cli)(/|$)'
ignore_cache='/([.]turbo|__pycache__)(/|$)'
jest_ignore=(
    "--modulePathIgnorePatterns=$ignore_dirs"
    "--modulePathIgnorePatterns=$ignore_cache"
    "--watchPathIgnorePatterns=$ignore_dirs"
    "--watchPathIgnorePatterns=$ignore_cache"
)
status=0

if [ -n "${ENACT_FOOTPRINT_DIR:-}" ] && [ "${ENACT_FRONTEND_FORCE_TRACE:-$(uname -s)}" = Linux ]; then
    if [ "$#" -eq 0 ]; then
        listed=$(CI=true pnpm --filter=@posthog/frontend exec jest "${jest_ignore[@]}" --listTests) || exit 1
        while IFS= read -r target; do
            [[ "$target" != *.test.* ]] || set -- "$@" "$target"
        done <<< "$listed"
    fi
    reporter="${ENACT_RECORDERS_DIR:?ENACT_RECORDERS_DIR must be set}/js/jest-attribution.cjs"
    max_auto="${ENACT_MAX_AUTO_TRACE_FILES:-10}"
    n=0
    rest=()
    for target in "$@"; do
        test=$(realpath -ms --relative-to="$repo" "$target")
        if [ -n "${ENACT_FOOTPRINT_TARGETS:-}" ] && ! rg -qxF -- "$test" "$ENACT_FOOTPRINT_TARGETS"; then
            rest+=("$target")
            continue
        fi
        if [ "${ENACT_RECORD:-}" = "auto" ] && [ "$n" -ge "$max_auto" ]; then
            rest+=("$target")
            continue
        fi
        n=$((n + 1))
        echo "🎙️  tracing $test for enact's reach map"
        CI=true "${ENACT_EXE:-enact}" trace run --node-functions --outcomes --shared-tmpdir --no-fingerprint \
            --reach-file "$ENACT_FOOTPRINT_DIR/frontend-traced-$n.json" -t "$test" -- \
            pnpm --filter=@posthog/frontend exec jest "${jest_ignore[@]}" --runInBand --forceExit \
            --reporters=default "--reporters=$reporter" \
            --testNamePattern="$pattern" \
            ${ENACT_TEST_VERBOSE:+--verbose} "$repo/$test" || status=1
    done
    if [ "${#rest[@]}" -eq 0 ]; then
        exit "$status"
    fi
    set -- "${rest[@]}"
fi

# Recycle Jest/jsdom workers at 768MB idle so 3 workers stay <= ~3.9 GiB inside c3m6g containers.
CI=true pnpm --filter=@posthog/frontend exec jest "${jest_ignore[@]}" --maxWorkers=3 --workerIdleMemoryLimit=768MB --forceExit \
    --testNamePattern="$pattern" \
    ${ENACT_TEST_VERBOSE:+--verbose} "$@" || { rc=$?; [ "$status" -ne 0 ] || status=$rc; }
exit "$status"
