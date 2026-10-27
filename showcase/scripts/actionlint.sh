#!/usr/bin/env bash
# ci-actionlint.yml's "Run actionlint", as upstream runs it: every workflow with its
# `parallel:` step groups flattened by upstream's awk script (actionlint 1.7.12 can't parse
# them, and checks their steps once flattened), linted with upstream's config, shellcheck
# reporting errors only (upstream's SHELLCHECK_OPTS).
set -euo pipefail

flat="$(mktemp -d)"
trap 'rm -rf "$flat"' EXIT
for workflow in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -e "$workflow" ] || continue
    awk -f .github/scripts/flatten-parallel-steps-for-actionlint.awk "$workflow" \
        > "$flat/$(basename "$workflow")"
done
SHELLCHECK_OPTS=--severity=error actionlint -config-file .github/actionlint.yaml "$flat"/*
