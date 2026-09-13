#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOWCASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SHOWCASE_DIR}/.." && pwd)"

BASE_REF="${1:-origin/master}"
EXTRA_PYTEST_ARGS="${2:-}"

cd "${REPO_ROOT}"

echo "======================================================================="
echo "  🎯 Snob Backend Impacted Test Selection (Base: ${BASE_REF})"
echo "======================================================================="

# Verify enve services are up
if ! curl -s "http://127.0.0.1:15432" >/dev/null 2>&1 && ! pg_isready -h 127.0.0.1 -p 15432 -U posthog >/dev/null 2>&1; then
    echo "• Booting rootless enve microservices..."
    enve up postgres redis clickhouse kafka seaweedfs temporal >/dev/null 2>&1 || true
fi

# Run selection script
SELECTION_RAW=$(uv run tools/snob_backend_test_selection_shadow.py --base-ref "${BASE_REF}")

CHANGED_COUNT=$(echo "${SELECTION_RAW}" | jq -r '.changed_file_count // 0')
FULL_REASONS=$(echo "${SELECTION_RAW}" | jq -r '.ast.full_run_reasons[]?' 2>/dev/null || true)
TEST_FILES=$(echo "${SELECTION_RAW}" | jq -r '.combined.tests[]?' 2>/dev/null || true)
TEST_COUNT=$(echo "${SELECTION_RAW}" | jq -r '.combined.count // 0')

echo "• Changed files detected : ${CHANGED_COUNT}"
if [ -n "${FULL_REASONS}" ]; then
    echo "⚠️ Full test suite triggered by pattern:"
    echo "${FULL_REASONS}" | sed 's/^/  - /'
fi

if [ -z "${TEST_FILES}" ] || [ "${TEST_COUNT}" -eq 0 ]; then
    echo "✅ No backend tests affected by diff against ${BASE_REF}."
    exit 0
fi

echo "• Impacted test files    : ${TEST_COUNT}"
echo "-----------------------------------------------------------------------"

# Format list of tests
TEST_ARGS=()
while IFS= read -r test_file; do
    if [ -n "${test_file}" ]; then
        TEST_ARGS+=("${test_file}")
    fi
done <<< "${TEST_FILES}"

echo "🚀 Executing ${#TEST_ARGS[@]} impacted test files via enve..."
START_TIME=$(date +%s%N)

# Set database and service envs
export DATABASE_URL="postgres://posthog:posthog@127.0.0.1:15432/posthog"
export CLICKHOUSE_HTTP_URL="http://127.0.0.1:8123"
export REDIS_URL="redis://127.0.0.1:16379/"
export KAFKA_HOSTS="127.0.0.1:19092"
export TEMPORAL_HOST="127.0.0.1"
export TEMPORAL_PORT="7233"
export OBJECT_STORAGE_ENDPOINT="http://127.0.0.1:19000"
export OBJECT_STORAGE_ACCESS_KEY_ID="posthog"
export OBJECT_STORAGE_SECRET_ACCESS_KEY="posthog"

enve run -- uv run pytest "${TEST_ARGS[@]}" ${EXTRA_PYTEST_ARGS}

END_TIME=$(date +%s%N)
DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))
DURATION_SEC=$(awk "BEGIN {printf \"%.2f\", $DURATION_MS / 1000}")

echo "======================================================================="
echo "✅ Impacted backend tests passed cleanly in ${DURATION_SEC}s!"
echo "======================================================================="
