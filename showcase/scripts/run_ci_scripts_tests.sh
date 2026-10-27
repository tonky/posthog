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
[ "${#py[@]}" -eq 0 ] || uv run --no-sync pytest -v -c /dev/null -p no:cacheprovider --noconftest "${py[@]}" || status=1
[ "${#js[@]}" -eq 0 ] || node --test "${js[@]}" || status=1
exit "$status"
