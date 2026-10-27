#!/usr/bin/env bash
# A Go module's tests by target:
#
#   run_go_tests.sh [--module <dir>] [--bench] [--all <package pattern>] [target...]
#
# enact's Go targets are top-level tests, `<package dir>::<TestName>` (a subtest, `/<name>`
# after it, runs its top-level test whole), or test files, which stand for their package's
# tests. Package directories are relative to the caller's directory or the repository; the
# tests run in `--module` (default the caller's directory), one `go test` per package. None:
# `--all`'s packages (default `./...`), the workflow's command. `--bench` then smoke-runs the
# same packages' benchmarks once (`-run '^$' -bench=. -benchtime=1x`), as
# ci-clickhouse-util-udfs.yml does.
#
# Always `-count=1`: CI's runners start without Go's test cache, and a cached result reads
# none of the test's files, so a traced run (`recorder: "trace"`) would hold none of them.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
bench=0 all=./... module=.
while [ "$#" -gt 0 ]; do
    case "$1" in
        --module) module="$2"; shift 2 ;;
        --bench) bench=1; shift ;;
        --all) all="$2"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
# Each package directory (absolute), with the `|`-joined tests to run, or `*` for all of them.
packages=() tests=()
for target in "$@"; do
    case "$target" in
        *::*) dir="${target%%::*}" name="${target#*::}" name="${name%%/*}" ;;
        *) dir="$(dirname "$target")" name='*' ;;
    esac
    abs="$(cd "$dir" 2>/dev/null && pwd -P)" || abs="$(cd "$root/$dir" && pwd -P)" || {
        echo "✗ run_go_tests.sh: no package directory for $target" >&2
        exit 64
    }
    for i in "${!packages[@]}"; do
        if [ "${packages[$i]}" = "$abs" ]; then
            if [ "$name" = '*' ]; then
                tests[i]='*'
            elif [ "${tests[$i]}" != '*' ]; then
                tests[i]="${tests[$i]}|$name"
            fi
            continue 2
        fi
    done
    packages+=("$abs") tests+=("$name")
done
cd "$module"
if [ "${#packages[@]}" -eq 0 ]; then
    go test -count=1 -v "$all"
    [ "$bench" -eq 0 ] || go test -count=1 -run '^$' -bench=. -benchtime=1x "$all"
    exit 0
fi
status=0
for i in "${!packages[@]}"; do
    run=()
    [ "${tests[$i]}" = '*' ] || run=(-run "^(${tests[$i]})\$")
    go test -count=1 -v ${run[@]+"${run[@]}"} "${packages[$i]}" || status=1
done
if [ "$bench" -eq 1 ]; then
    go test -count=1 -run '^$' -bench=. -benchtime=1x "${packages[@]}" || status=1
fi
exit "$status"
