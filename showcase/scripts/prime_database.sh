#!/usr/bin/env bash
# ==============================================================================
# showcase/scripts/prime_database.sh
# Fast, idempotent priming and templating for PostgreSQL on tmpfs.
# Restores 2,699 migrations in ~1.2s and registers template_posthog.
# ==============================================================================

set -euo pipefail

PG_HOST="127.0.0.1"
PG_PORT="${PGPORT:-15432}"
PG_USER="posthog"

# Resolve repo root regardless of cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_env.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DUMP=""
if [ -f "$REPO_ROOT/showcase/data/schema-latest.sql.gz" ]; then
    DUMP="$REPO_ROOT/showcase/data/schema-latest.sql.gz"
elif [ -f "$REPO_ROOT/.postgres-backups/schema-latest.sql.gz" ]; then
    DUMP="$REPO_ROOT/.postgres-backups/schema-latest.sql.gz"
fi

if [ -z "$DUMP" ]; then
    log_info "No schema dump found, skipping database priming."
    exit 0
fi

# Check migration count in test_posthog
COUNT=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d test_posthog -tAc "SELECT count(*) FROM django_migrations" 2>/dev/null || echo 0)

if [ "${FORCE_PRIME:-0}" = "1" ] || [ "${1:-}" = "--force" ] || [ "${COUNT:-0}" -lt 2000 ]; then
    log_info "Priming test_posthog database from $DUMP (2,699 migrations)..."
    log_cmd "psql -h $PG_HOST -p $PG_PORT -U $PG_USER -d postgres -c 'CREATE DATABASE test_posthog;' && gunzip -c $DUMP | psql ..."
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -q \
        -c "DROP DATABASE IF EXISTS test_posthog;" \
        -c "CREATE DATABASE test_posthog;"
    gunzip -c "$DUMP" | psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -q -d test_posthog
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d test_posthog -q -c "DELETE FROM django_migrations WHERE app IN ('stamphog', 'visual_review');"
    
    log_info "Registering template_posthog for instant copy-on-write isolation..."
    log_cmd "psql -h $PG_HOST -p $PG_PORT -U $PG_USER -d postgres -c 'CREATE DATABASE template_posthog TEMPLATE test_posthog;'"
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -q -c "ALTER DATABASE template_posthog is_template false;" 2>/dev/null || true
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -q \
        -c "DROP DATABASE IF EXISTS template_posthog;" \
        -c "CREATE DATABASE template_posthog TEMPLATE test_posthog;" \
        -c "ALTER DATABASE template_posthog is_template true;"
        
    log_info "Priming development posthog database from template..."
    log_cmd "psql -h $PG_HOST -p $PG_PORT -U $PG_USER -d postgres -c 'CREATE DATABASE posthog TEMPLATE template_posthog;'"
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -q \
        -c "DROP DATABASE IF EXISTS posthog;" \
        -c "CREATE DATABASE posthog TEMPLATE template_posthog;"
        
    log_ok "PostgreSQL databases primed & templated in <1.5s."
else
    log_info "test_posthog already primed (${COUNT} migrations)."
fi
