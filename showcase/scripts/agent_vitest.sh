#!/usr/bin/env bash
# packages/agent's unit tests, as its `pnpm test` runs them (turbo: each package's
# `vitest run`, from the package's directory, after its dependencies' builds, which the job
# runs in a task of its own). Arguments are test files relative to packages/agent
# (packages/<p>/src/…): each package's vitest (vitest.sh) gets its own, and a package given
# none doesn't run. No arguments: every package's whole suite. A file in no package fails
# the run: a run told to run tests that runs none is no pass.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${here}/../../packages/agent"

for file in "$@"; do
    case "${file}" in
    packages/*/*) [ -f "packages/$(cut -d/ -f2 <<<"${file}")/package.json" ] && continue ;;
    esac
    echo "✗ agent_vitest.sh: ${file} is in no package of packages/agent" >&2
    exit 64
done

status=0
for dir in packages/*/; do
    dir=${dir%/}
    [ -f "${dir}/package.json" ] || continue
    files=()
    for file in "$@"; do
        case "${file}" in "${dir}"/*) files+=("${file#"${dir}"/}") ;; esac
    done
    [ "$#" -eq 0 ] || [ "${#files[@]}" -gt 0 ] || continue
    echo "▶ ${dir}: vitest run ${files[*]-}"
    (cd "${dir}" && "${here}/../../.enact/vitest/vitest.sh" run ${files[@]+"${files[@]}"}) || status=1
done
exit "${status}"
