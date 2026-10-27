#!/usr/bin/env bash
# ci-mcp.yml's "Integration Tests": the whole PostHog backend booted prod-like (TEST unset)
# against the run's services, then `pnpm run test:integration` of services/mcp, whose tools
# drive its API over HTTP with a personal API key. As upstream: the database migrated
# (Django, then ClickHouse), the Rust flags service and personhog's replica and router, demo
# data, an API key, a Celery worker and granian; the targets (integration test files)
# narrow vitest's run, none runs them all.
#
# The job's databases are its own, so it runs beside the run's other jobs: a clone of the
# migrated Django template (upstream restores ci-backend's schema dump; both lack the routed
# product apps' tables, whose migration records it drops so `migrate` creates them on the
# default database, as upstream's prime step), the persons template's clone, a ClickHouse
# database and Kafka topics under its own prefix, and Redis database 4. Every listener takes
# a free port (upstream's 3001, 50051, 50052 and 8000 are fixed).
#
# Recording footprints for enact (ENACT_FOOTPRINT_DIR set): each test file runs alone, against
# Django and Celery started afresh for it (live_each_spec, live_footprint.py).
set -euo pipefail
# enact gives the targets relative to the task's directory; they go on from the checkout's
# root (vitest takes them relative to services/mcp, where the suite runs: mcp_run).
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
targets=()
for target in "$@"; do
    target="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
    targets+=("${target#"$root"/}")
done
cd "$root"
# shellcheck source=test_databases.sh
source showcase/scripts/test_databases.sh
# shellcheck source=live_posthog.sh
source showcase/scripts/live_posthog.sh

live_setup "${ENACT_COMPONENT:-mcp_integration}" "${ENACT_JOB:-test}" 4 "${ENACT_MCP_LOG_DIR:-.enact/state/mcp-integration}"
flags_port=$(live_free_port)
# ci-mcp.yml's own environment.
live_run+=(OPT_OUT_CAPTURE=1 FEATURE_FLAGS_SERVICE_URL="http://127.0.0.1:$flags_port"
    POSTHOG_FEATURE_FLAGS_FORCE_ENABLED=logs-alerting,dashboard-widgets,product-business-knowledge,billing-alerts
    INTERNAL_REQUEST_TOKEN=mcp-ci-internal-request-token)

live_record
if [ -n "$live_recording" ] && [ ${#targets[@]} -eq 0 ]; then
    mapfile -t targets < <(git ls-files ':(glob)services/mcp/tests/**/*.integration.test.ts' | rg -v '^services/mcp/tests/hono/')
fi

live_topics
live_migrate
live_build_rust feature-flags personhog-replica personhog-router

# "Start Rust flags service": it listens on ADDRESS (config.rs).
LIVE_CWD=rust live_start rust-flags "$flags_port" "http://127.0.0.1:$flags_port/_readiness" \
    "${live_run[@]}" ADDRESS="127.0.0.1:$flags_port" \
    READ_DATABASE_URL="$live_database" WRITE_DATABASE_URL="$live_database" \
    PERSONS_READ_DATABASE_URL="$live_persons" PERSONS_WRITE_DATABASE_URL="$live_persons" \
    COOKIELESS_REDIS_HOST=127.0.0.1 COOKIELESS_REDIS_PORT="$ENVE_SERVICE_REDIS_PORT" \
    CACHE_TTL_SECONDS=0 RUST_BACKTRACE=1 "$live_bin/feature-flags"
live_start_personhog

# "Seed test data" and "Create API key and extract test IDs".
live_py manage.py generate_demo_data --n-clusters 10 --days-past 7 --days-future 0 \
    --skip-materialization --skip-flag-sync --skip-user-product-list
ids="$(live_py - <<'PY'
import os

import django

os.environ["DJANGO_SETTINGS_MODULE"] = "posthog.settings"
django.setup()
from posthog.models import EventDefinition, Organization, PropertyDefinition, Team, User
from posthog.models.personal_api_key import PersonalAPIKey
from posthog.models.utils import hash_key_value

org = Organization.objects.first()
team = Team.objects.first()
user = User.objects.first()
PersonalAPIKey.objects.create(
    user=user, label="mcp_ci_api_key", secure_value=hash_key_value("phx_e2e_demo_api_key"), scopes=["*"]
)
for event_name in ["$pageview", "$pageleave", "$autocapture", "$screen"]:
    EventDefinition.objects.get_or_create(name=event_name, team=team)
PropertyDefinition.objects.get_or_create(
    name="$browser", team=team, type=PropertyDefinition.Type.EVENT, defaults={"property_type": "String"}
)
print(f"TEST_ORG_ID={org.id}")
print(f"TEST_PROJECT_ID={team.id}")
PY
)"
org_id="$(sed -n 's/^TEST_ORG_ID=//p' <<<"$ids")" project_id="$(sed -n 's/^TEST_PROJECT_ID=//p' <<<"$ids")"
[ -n "$org_id" ] && [ -n "$project_id" ] || { echo "No organization or project after seeding: $ids" >&2; exit 1; }

mcp_app() {
    live_start_celery
    live_start_web 1
}

# "Run integration tests".
mcp_run() { # [test file...]
    local files=() file
    for file in "$@"; do files+=("${file#services/mcp/}"); done
    (cd services/mcp && TEST_POSTHOG_API_BASE_URL="http://127.0.0.1:$live_web_port" \
        TEST_POSTHOG_PERSONAL_API_KEY=phx_e2e_demo_api_key TEST_ORG_ID="$org_id" TEST_PROJECT_ID="$project_id" \
        pnpm run test:integration ${files[@]+"${files[@]}"})
}
live_each_spec mcp_app mcp_run ${targets[@]+"${targets[@]}"}
