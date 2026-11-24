#!/usr/bin/env bash
# Per-key publish.lock / flock -s shared-read lock split for PostHog v3
# database templates, wired outside test_databases.sh so test_databases.sh
# stays byte-identical and existing pg-template keys (v3) do not invalidate.
#
# Source this file immediately AFTER test_databases.sh. It overrides
# with_templates() to replace the coarse global exclusive lock
# ($SNAPSHOT_ROOT/templates.lock) with:
#   1. Per-Postgres exclusive lock ($TEST_DB_LOCK, fd 9) protecting this
#      service instance's template databases.
#   2. Per-key lock ($SNAPSHOT_ROOT/locks/v3/$TEMPLATE_KEY/publish.lock, fd 8),
#      kept outside $SNAPSHOT_ROOT/v3/ so `enact helper pg-template verify`
#      and hosted actions/cache archives only see clean <key>/{current-v3,v3.*}
#      entries:
#        - Warm consumers acquire a shared lock (`flock -s 8`) so multiple
#          concurrent warm restores for the same key run in parallel without
#          serialization.
#        - Cold producers release the shared lock, acquire an exclusive lock
#          (`flock -x 8`) on that key's `publish.lock`, and double-check
#          `$SNAPSHOT_DIR/current-v3` before building. If a racing producer
#          published the key while waiting, we downgrade to `flock -s 8` and
#          restore instead of duplicating the cold build.
#        - Readers/writers on different keys lock different `publish.lock`
#          files and never block each other.
#        - fd 8 is closed immediately after snapshot restore/publish, before
#          sync_sqlx_migrations, wait_templates_free, and the caller's clone.

template_key_lock_path() {
    printf '%s/locks/v3/%s/publish.lock\n' "${SNAPSHOT_ROOT%/}" "$TEMPLATE_KEY"
}

with_templates() { # <command...>
    mkdir -p "$(dirname "$TEST_DB_LOCK")" || return 1
    (
        flock 9 || exit 1
        configure_template_cache || exit 1
        if ! template_ready; then
            local key_lock
            key_lock=$(template_key_lock_path) || exit 1
            mkdir -p "$(dirname "$key_lock")" || exit 1
            exec 8>>"$key_lock"
            flock -s 8 || exit 1
            if [ -f "$SNAPSHOT_DIR/current-v3" ]; then
                restore_from_snapshots || exit 1
            else
                # Release shared lock before taking exclusive publish lock to avoid
                # upgrade deadlock when two cold producers miss simultaneously.
                flock -u 8 || exit 1
                flock -x 8 || exit 1
                if [ -f "$SNAPSHOT_DIR/current-v3" ]; then
                    # A racing producer published this key while we waited: downgrade
                    # to shared so concurrent warm readers proceed in parallel.
                    flock -s 8 || exit 1
                    restore_from_snapshots || exit 1
                else
                    bootstrap_templates || exit 1
                fi
            fi
            exec 8>&-
        fi
        sync_sqlx_migrations || exit 1
        wait_templates_free || exit 1
        "$@"
    ) 9>"$TEST_DB_LOCK"
}
