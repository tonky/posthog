#!/usr/bin/env bash
# Resolve the PostHog database snapshot root outside test_databases.sh so
# test_databases.sh stays byte-identical and existing pg-template keys (v3) do
# not invalidate.
#
# Precedence:
#   1. Explicit ENACT_TEMPLATE_SNAPSHOT_DIR (caller / operator / test override)
#   2. Managed self-hosted runner with writable $ENACT_HOST_CACHE/repo:
#        $ENACT_HOST_CACHE/repo/pg-templates
#   3. Hosted GitHub Actions runners and local dev fallback:
#        $HOME/.cache/enact/snapshots
#
# All three snapshot namespaces live under this root:
#   - v3/      (test_databases.sh — Django + persons templates)
#   - live-v1/ (live_posthog.sh — routed live Postgres migrations)
#   - ch-v1/   (live_posthog.sh — ClickHouse DDL/ORM migrations)
#
# Hosted jobs keep ~/.cache/enact/snapshots/{v3,live-v1,ch-v1} aligned with
# actions/cache restore/verify/save in .enact/ci.cue. Managed self-hosted jobs
# persist directly under $ENACT_HOST_CACHE/repo/pg-templates/{v3,live-v1,ch-v1}
# using atomic pointer renames and flock, avoiding actions/cache upload overhead
# and host-cache's checkout-relative 64 MiB per-file cap.

resolve_snapshot_root() {
    if [ -n "${ENACT_TEMPLATE_SNAPSHOT_DIR:-}" ]; then
        printf '%s\n' "$ENACT_TEMPLATE_SNAPSHOT_DIR"
        return 0
    fi
    local host="${ENACT_HOST_CACHE:-}"
    host="${host%/}"
    if [ -n "$host" ] && [ -d "$host/repo" ] && [ -w "$host/repo" ]; then
        printf '%s\n' "$host/repo/pg-templates"
    else
        printf '%s\n' "${HOME%/}/.cache/enact/snapshots"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    resolve_snapshot_root
else
    ENACT_TEMPLATE_SNAPSHOT_DIR="$(resolve_snapshot_root)"
    export ENACT_TEMPLATE_SNAPSHOT_DIR
fi
