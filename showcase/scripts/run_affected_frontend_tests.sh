#!/usr/bin/env bash
# ==============================================================================
# showcase/scripts/run_affected_frontend_tests.sh
# Smart test impact analysis for Frontend (TypeScript/React):
# 1. Calculates git diff against BASE_REF (or uncommitted local changes)
# 2. Filters to frontend source files (.ts, .tsx, .js, .jsx)
# 3. Runs Jest --findRelatedTests scoped to the changed files
# 4. Benchmarks execution time and prints scorecard
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOWCASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SHOWCASE_DIR}/.." && pwd)"

BASE_REF="${1:-origin/master}"
EXTRA_JEST_ARGS="${2:-}"

cd "${REPO_ROOT}"

# Ensure pnpm is in PATH
if ! command -v pnpm >/dev/null 2>&1; then
    if [ -x "/nix/store/z0rlx5672gdlfb3830irk026yfwz8kyp-pnpm-11.22.0/bin/pnpm" ]; then
        export PATH="/nix/store/z0rlx5672gdlfb3830irk026yfwz8kyp-pnpm-11.22.0/bin:$PATH"
    fi
fi

echo "======================================================================="
echo "  🎯 Frontend Impacted Test Selection (Base: ${BASE_REF})"
echo "======================================================================="

# Collect changed files (both committed diff against BASE_REF and unstaged/staged working tree changes)
CHANGED_FILES_RAW=$(
    {
        git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null || true
        git diff --name-only HEAD 2>/dev/null || true
        git status --porcelain 2>/dev/null | awk '{print $2}' || true
    } | sort -u
)

# Filter for frontend source files
# Handles: frontend/src/*, products/*/frontend/*, common/*, packages/*
CHANGED_SRC=()
while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
        *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs)
            # Skip test files themselves from source inputs, but preserve them in target tests
            if [[ "$file" =~ \.(test|spec)\.[jt]sx?$ ]]; then
                continue
            fi
            if [[ "$file" =~ ^(frontend/src/|products/[^/]+/frontend/|common/|packages/) ]]; then
                CHANGED_SRC+=("$file")
            fi
            ;;
    esac
done <<< "${CHANGED_FILES_RAW}"

# Also collect any directly modified test files
MODIFIED_TESTS=()
while IFS= read -r file; do
    [ -z "$file" ] && continue
    if [[ "$file" =~ \.(test|spec)\.[jt]sx?$ ]] && [ -f "$file" ]; then
        MODIFIED_TESTS+=("$file")
    fi
done <<< "${CHANGED_FILES_RAW}"

TOTAL_CHANGED_SRC=${#CHANGED_SRC[@]}
TOTAL_MODIFIED_TESTS=${#MODIFIED_TESTS[@]}

echo "• Changed frontend source files : ${TOTAL_CHANGED_SRC}"
echo "• Directly modified test files  : ${TOTAL_MODIFIED_TESTS}"

if [ "${TOTAL_CHANGED_SRC}" -eq 0 ] && [ "${TOTAL_MODIFIED_TESTS}" -eq 0 ]; then
    echo "✅ No frontend source files or tests modified against ${BASE_REF}."
    exit 0
fi

# Print preview of changed files
if [ "${TOTAL_CHANGED_SRC}" -gt 0 ]; then
    echo "─── Changed Source Files (Sample) ────────────────────────────────────"
    printf '  %s\n' "${CHANGED_SRC[@]:0:5}"
    if [ "${TOTAL_CHANGED_SRC}" -gt 5 ]; then
        echo "  ... and $((TOTAL_CHANGED_SRC - 5)) more"
    fi
fi

# Convert repo-relative paths to frontend-relative paths (cd into frontend)
# Jest in frontend/ package resolves:
#   frontend/src/foo.ts -> src/foo.ts
#   products/foo/frontend/bar.ts -> ../products/foo/frontend/bar.ts
FRONTEND_INPUTS=()
for f in "${CHANGED_SRC[@]}"; do
    if [[ "$f" =~ ^frontend/ ]]; then
        FRONTEND_INPUTS+=("${f#frontend/}")
    else
        FRONTEND_INPUTS+=("../$f")
    fi
done

for t in "${MODIFIED_TESTS[@]}"; do
    if [[ "$t" =~ ^frontend/ ]]; then
        FRONTEND_INPUTS+=("${t#frontend/}")
    else
        FRONTEND_INPUTS+=("../$t")
    fi
done

echo "-----------------------------------------------------------------------"
echo "🚀 Resolving reverse dependency graph & executing impacted Jest tests..."
START_TIME=$(date +%s%N)

# Build products manifests first if needed (needed for product routing in tests)
pnpm --filter=@posthog/frontend build:products >/dev/null 2>&1 || true

# Execute Jest --findRelatedTests from frontend/
(
    cd "${REPO_ROOT}/frontend"
    # shellcheck disable=SC2086
    pnpm exec jest \
        --passWithNoTests \
        --forceExit \
        --findRelatedTests "${FRONTEND_INPUTS[@]}" \
        ${EXTRA_JEST_ARGS}
)

END_TIME=$(date +%s%N)
DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))
DURATION_SEC=$(awk -v ms="${DURATION_MS}" 'BEGIN { printf "%.2f", ms / 1000 }')

echo "======================================================================="
echo "  📊 Frontend Impact Test Scorecard"
echo "======================================================================="
echo "• Upstream CI Full Jest Matrix : ~12-15m (720-900s across 4 shards)"
echo "• Local Affected Selection Run : ${DURATION_SEC}s"
echo "• Speedup Factor               : ~$(awk -v s="${DURATION_SEC}" 'BEGIN { printf "%.0f", 800 / (s > 0 ? s : 1) }')x faster than full CI matrix"
echo "======================================================================="
