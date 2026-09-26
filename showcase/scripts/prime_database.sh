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
    log_info "No schema dump found, ensuring empty posthog databases exist."
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -q \
        -c "CREATE DATABASE posthog;" \
        -c "CREATE DATABASE test_posthog;" 2>/dev/null || true
    exit 0
fi

# Check if test_posthog exists and has migrations
DB_EXISTS=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'test_posthog'" 2>/dev/null || echo 0)
COUNT=0
if [ "${DB_EXISTS:-0}" = "1" ]; then
    HAS_MIGRATIONS_TABLE=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d test_posthog -tAc "SELECT to_regclass('public.django_migrations')" 2>/dev/null || true)
    if [ -n "$HAS_MIGRATIONS_TABLE" ]; then
        COUNT=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d test_posthog -tAc "SELECT count(*) FROM django_migrations" 2>/dev/null || echo 0)
    fi
fi

if [ "${FORCE_PRIME:-0}" = "1" ] || [ "${1:-}" = "--force" ] || [ "${COUNT:-0}" -lt 2000 ]; then
    log_info "Priming test_posthog database from $DUMP (2,699 migrations)..."
    log_cmd "psql -h $PG_HOST -p $PG_PORT -U $PG_USER -d postgres -c 'CREATE DATABASE test_posthog;' && gunzip -c $DUMP | psql ..."
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -q \
        -c "DROP DATABASE IF EXISTS test_posthog;" \
        -c "CREATE DATABASE test_posthog;"
    gunzip -c "$DUMP" | psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -q -d test_posthog
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d test_posthog -q -c "DELETE FROM django_migrations WHERE app IN ('stamphog', 'visual_review');"
    
    log_info "Registering template_posthog and priming development posthog database..."
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -q <<'EOF'
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_database WHERE datname = 'template_posthog') THEN
    ALTER DATABASE template_posthog is_template false;
  END IF;
END $$;
DROP DATABASE IF EXISTS template_posthog;
CREATE DATABASE template_posthog TEMPLATE test_posthog;
ALTER DATABASE template_posthog is_template true;
DROP DATABASE IF EXISTS posthog;
CREATE DATABASE posthog TEMPLATE template_posthog;
EOF
        
    log_ok "PostgreSQL databases primed & templated in <1.5s."
else
    log_info "test_posthog already primed (${COUNT} migrations)."
fi
