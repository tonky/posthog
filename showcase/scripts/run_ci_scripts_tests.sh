#!/usr/bin/env bash
# ci-scripts.yml's tests of the CI helpers, from the repository root: pytest without the
# root's pytest.ini (its addopts need pytest-django) and conftest.py (it imports Django),
# then node:test.
#
#   run_ci_scripts_tests.sh [test file...]
#
# Test files, relative to the caller's directory or the repository (or via @<targets_file> /
# ENACT_TARGETS_FILE): Python ones go to a single batched pytest process, .js/.mjs ones to a
# single batched node --test process. When recording footprints on Linux, only wanted targets
# (capped by ENACT_MAX_AUTO_TRACE_FILES under ENACT_RECORD=auto) run individually under
# `enact trace run`, while all remaining targets run in the fast batched pytest / node pools.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

raw_args=("$@")
if [ "${#raw_args[@]}" -eq 1 ] && [[ "${raw_args[0]}" == @* ]]; then
    target_list="${raw_args[0]#@}"
    raw_args=()
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ [^[:space:]] ]] && raw_args+=("$line")
    done < "$target_list"
elif [ "${#raw_args[@]}" -eq 0 ] && [ -n "${ENACT_TARGETS_FILE:-}" ] && [ -f "$ENACT_TARGETS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ [^[:space:]] ]] && raw_args+=("$line")
    done < "$ENACT_TARGETS_FILE"
fi

py=() js=()
if [ "${#raw_args[@]}" -eq 0 ]; then
    cd "$root"
    py=(.github/scripts/test_*.py tools/test_snob_backend_test_selection_shadow.py tools/test_test_selection_verdict.py)
    js=(.github/scripts/*.test.js .github/scripts/*.test.mjs)
else
    for file in "${raw_args[@]}"; do
        dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)" || dir="$root/$(dirname "$file")"
        file="${dir#"$root"/}/$(basename "$file")"
        case "$file" in
            *.py) py+=("$file") ;;
            *.js | *.mjs) js+=("$file") ;;
            *)
                echo "✗ run_ci_scripts_tests.sh: $file is neither a Python nor a node:test file" >&2
                exit 64
                ;;
        esac
    done
fi
cd "$root"
status=0
# The helpers read the Actions run they serve (GITHUB_REPOSITORY, GITHUB_REF_NAME, ...): this
# job's own run (the fork's repository and branch) is not one their tests fake, and the
# fixtures assume upstream's. The tests run without it, as on a developer's machine.
for var in GITHUB_REPOSITORY GITHUB_REF_NAME GITHUB_REF GITHUB_HEAD_REF GITHUB_BASE_REF \
    GITHUB_SHA GITHUB_RUN_ID GITHUB_WORKFLOW_REF GITHUB_SERVER_URL GITHUB_STEP_SUMMARY GITHUB_EVENT_NAME; do
    unset "$var"
done

if [ -x "$root/.venv/bin/python" ]; then
    export PATH="$root/.venv/bin:$PATH"
    pytest_cmd=("$root/.venv/bin/python" -m pytest)
else
    pytest_cmd=(uv run --no-sync pytest)
fi
py_flags=(-v -c /dev/null -p no:cacheprovider --noconftest)

if [ -n "${ENACT_FOOTPRINT_DIR:-}" ] && [ "${ENACT_CI_SCRIPTS_FORCE_TRACE:-$(uname -s)}" = Linux ]; then
    max_auto="${ENACT_MAX_AUTO_TRACE_FILES:-5}"
    n=0
    py_rest=()
    for file in ${py[@]+"${py[@]}"}; do
        if [ -n "${ENACT_FOOTPRINT_TARGETS:-}" ] && ! rg -qxF -- "$file" "$ENACT_FOOTPRINT_TARGETS"; then
            py_rest+=("$file")
            continue
        fi
        if [ "${ENACT_RECORD:-}" = "auto" ] && [ "$n" -ge "$max_auto" ]; then
            py_rest+=("$file")
            continue
        fi
        n=$((n + 1))
        echo "🎙️  tracing $file for enact's reach map"
        "${ENACT_EXE:-enact}" trace run --outcomes --shared-tmpdir --no-fingerprint \
            --reach-file "$ENACT_FOOTPRINT_DIR/ci-scripts-traced-$n.json" -t "$file" -- \
            "${pytest_cmd[@]}" "${py_flags[@]}" "$file" || status=1
    done
    js_rest=()
    for file in ${js[@]+"${js[@]}"}; do
        if [ -n "${ENACT_FOOTPRINT_TARGETS:-}" ] && ! rg -qxF -- "$file" "$ENACT_FOOTPRINT_TARGETS"; then
            js_rest+=("$file")
            continue
        fi
        if [ "${ENACT_RECORD:-}" = "auto" ] && [ "$n" -ge "$max_auto" ]; then
            js_rest+=("$file")
            continue
        fi
        n=$((n + 1))
        echo "🎙️  tracing $file for enact's reach map"
        "${ENACT_EXE:-enact}" trace run --node-functions --outcomes --shared-tmpdir --no-fingerprint \
            --reach-file "$ENACT_FOOTPRINT_DIR/ci-scripts-traced-$n.json" -t "$file" -- \
            node --test "$file" || status=1
    done
    py=(${py_rest[@]+"${py_rest[@]}"})
    js=(${js_rest[@]+"${js_rest[@]}"})
fi

[ "${#py[@]}" -eq 0 ] || "${pytest_cmd[@]}" "${py_flags[@]}" "${py[@]}" || status=1
[ "${#js[@]}" -eq 0 ] || node --test "${js[@]}" || status=1
exit "$status"
