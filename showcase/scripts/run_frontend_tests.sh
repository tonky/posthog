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
    marker="${ENACT_RECORDERS_DIR:?ENACT_RECORDERS_DIR must be set}/js/jest-marker.cjs"
    if [ "${ENACT_JEST_BATCHED_MARKER:-0}" = "1" ]; then
        batched=()
        rest=()
        for target in "$@"; do
            test=$(realpath -ms --relative-to="$repo" "$target")
            if [ -n "${ENACT_FOOTPRINT_TARGETS:-}" ] && ! rg -qxF -- "$test" "$ENACT_FOOTPRINT_TARGETS"; then
                rest+=("$target")
                continue
            fi
            batched+=("$repo/$test")
        done
        if [ "${#batched[@]}" -gt 0 ]; then
            attr_file="$ENACT_FOOTPRINT_DIR/frontend-batched-attribution.jsonl"
            frontend_dir="$repo/frontend"
            base_cfg=""
            for candidate in jest.config.ts jest.config.js jest.config.cjs; do
                if [ -f "$frontend_dir/$candidate" ]; then
                    base_cfg="$frontend_dir/$candidate"
                    break
                fi
            done
            if [ -z "$base_cfg" ]; then
                echo "✗ run_frontend_tests.sh: no jest.config.{ts,js,cjs} found in $frontend_dir" >&2
                exit 1
            fi
            wrapper_cfg="$ENACT_FOOTPRINT_DIR/jest-batched-config.cjs"
            cat > "$wrapper_cfg" <<'EOF'
'use strict';
const { loadAndExtendJestConfig } = require(process.env.ENACT_JEST_MARKER);
module.exports = () => loadAndExtendJestConfig(
  process.env.ENACT_JEST_BASE_CONFIG,
  process.env.ENACT_JEST_MARKER,
  process.env.ENACT_JEST_ROOT_DIR,
);
EOF
            echo "🎙️  tracing ${#batched[@]} frontend test(s) in batched marker mode"
            CI=true ENACT_JEST_MARKER="$marker" ENACT_JEST_BASE_CONFIG="$base_cfg" ENACT_JEST_ROOT_DIR="$frontend_dir" \
                "${ENACT_EXE:-enact}" trace run --node-functions --outcomes --shared-tmpdir --no-fingerprint \
                --attribution "$attr_file" \
                --reach-file "$ENACT_FOOTPRINT_DIR/frontend-batched.json" -- \
                pnpm --filter=@posthog/frontend exec jest "${jest_ignore[@]}" --no-cache --maxWorkers=3 \
                --workerIdleMemoryLimit=768MB --forceExit \
                "--config=$wrapper_cfg" \
                --reporters=default "--reporters=$reporter" \
                --testNamePattern="$pattern" \
                ${ENACT_TEST_VERBOSE:+--verbose} "${batched[@]}" || status=1
        fi
        if [ "${#rest[@]}" -eq 0 ]; then
            exit "$status"
        fi
        set -- "${rest[@]}"
    else
        max_auto="${ENACT_MAX_AUTO_TRACE_FILES:-40}"
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
fi

# Recycle Jest/jsdom workers at 768MB idle so 3 workers stay <= ~3.9 GiB inside c3m6g containers.
CI=true pnpm --filter=@posthog/frontend exec jest "${jest_ignore[@]}" --maxWorkers=3 --workerIdleMemoryLimit=768MB --forceExit \
    --testNamePattern="$pattern" \
    ${ENACT_TEST_VERBOSE:+--verbose} "$@" || { rc=$?; [ "$status" -ne 0 ] || status=$rc; }
exit "$status"
