#!/usr/bin/env bash
# ci-scripts.yml's tests of the CI helpers, from the repository root: pytest without the
# root's pytest.ini (its addopts need pytest-django) and conftest.py (it imports Django),
# then node:test.
#
#   run_ci_scripts_tests.sh [test file...]
#
# Test files, relative to the caller's directory or the repository: Python ones go to
# pytest, .js/.mjs ones to node --test. None: the workflow's, the tools/ ones by name (a
# glob would take tests other jobs run, and test_selection_verdict.py, which is no test).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
py=() js=()
if [ "$#" -eq 0 ]; then
    cd "$root"
    py=(.github/scripts/test_*.py tools/test_snob_backend_test_selection_shadow.py tools/test_test_selection_verdict.py)
    js=(.github/scripts/*.test.js .github/scripts/*.test.mjs)
fi
for file in "$@"; do
    # Repository-relative.
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
cd "$root"
status=0
# The helpers read the Actions run they serve (GITHUB_REPOSITORY, GITHUB_REF_NAME, ...): this
# job's own run (the fork's repository and branch) is not one their tests fake, and the
# fixtures assume upstream's. The tests run without it, as on a developer's machine.
for var in GITHUB_REPOSITORY GITHUB_REF_NAME GITHUB_REF GITHUB_HEAD_REF GITHUB_BASE_REF \
    GITHUB_SHA GITHUB_RUN_ID GITHUB_WORKFLOW_REF GITHUB_SERVER_URL GITHUB_STEP_SUMMARY GITHUB_EVENT_NAME; do
    unset "$var"
done
py_plugins=(-p no:cacheprovider)
if [ -n "${ENACT_FOOTPRINT_DIR:-}" ]; then
    export PYTHONPATH="$root/showcase/pytest_plugins${PYTHONPATH:+:$PYTHONPATH}"
    py_plugins+=(-p pytest_footprint)
    export NODE_OPTIONS="--import $root/showcase/scripts/node_reads.mjs${NODE_OPTIONS:+ $NODE_OPTIONS}"
fi
[ "${#py[@]}" -eq 0 ] || uv run --no-sync pytest -v -c /dev/null "${py_plugins[@]}" --noconftest "${py[@]}" || status=1
[ "${#js[@]}" -eq 0 ] || node --test "${js[@]}" || status=1
exit "$status"
