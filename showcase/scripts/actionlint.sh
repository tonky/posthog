#!/usr/bin/env bash
# ci-actionlint.yml's "Run actionlint", as upstream runs it: every workflow with its
# `parallel:` step groups flattened by upstream's awk script (actionlint 1.7.12 can't parse
# them, and checks their steps once flattened), linted with upstream's config, shellcheck
# reporting errors only (upstream's SHELLCHECK_OPTS).
set -euo pipefail

flat="$(mktemp -d)"
cfg="$(mktemp "${TMPDIR:-/tmp}/actionlint.XXXXXX.yaml")"
trap 'rm -rf "$flat" "$cfg"' EXIT
for workflow in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -e "$workflow" ] || continue
    awk -f .github/scripts/flatten-parallel-steps-for-actionlint.awk "$workflow" \
        > "$flat/$(basename "$workflow")"
done
extra_labels="$(
    {
        printf 'tonky-ci\nmac1\n'
        grep -hoE 'tonky-ci-[a-z0-9-]+' "$flat"/* 2>/dev/null || true
    } | sort -u | tr '\n' ' '
)"
awk -v extra="$extra_labels" '
    { print }
    /^    labels:[[:space:]]*$/ {
        n = split(extra, items, " ")
        for (i = 1; i <= n; i++) {
            if (items[i] != "") print "        - " items[i]
        }
    }
' .github/actionlint.yaml > "$cfg"
SHELLCHECK_OPTS=--severity=error actionlint -config-file "$cfg" "$flat"/*
