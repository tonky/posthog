#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# scripts/build_frontend_and_static_cached.sh
# Builds the PostHog frontend bundle via Turbo and executes headless Django
# collectstatic into dist/prebuilt-frontend and dist/staticfiles staging directories.
# ==============================================================================

echo "======================================================================"
echo "⚡ Building PostHog Frontend & Collecting Static Assets"
echo "======================================================================"

# 1. Check if already restored from Tier-1 cache
if [ -s "dist/prebuilt-frontend/code/frontend/dist/index.html" ] && [ -d "dist/staticfiles" ] && [ "$(ls -A dist/staticfiles 2>/dev/null)" ]; then
    echo "✓ Prebuilt frontend assets and staticfiles already restored from Tier-1 cache (< 2s)"
    exit 0
fi

# 2. Compile frontend via Turbo (multi-core parallel esbuild)
echo "🔨 Compiling frontend via bin/turbo --filter=@posthog/frontend build..."
START_FE=$(date +%s%N)

PARALLEL_HEAVY=1 bin/turbo --filter=@posthog/frontend build

END_FE=$(date +%s%N)
FE_MS=$(( (END_FE - START_FE) / 1000000 ))
FE_SEC=$(awk "BEGIN {printf \"%.2f\", $FE_MS / 1000}")
echo "✓ Frontend compiled successfully in ${FE_SEC}s"

# 3. Stage compiled frontend bundle & product catalog schema
mkdir -p dist/prebuilt-frontend/code/frontend/src
cp -r frontend/dist dist/prebuilt-frontend/code/frontend/
if [ -f "frontend/src/products.json" ]; then
    cp frontend/src/products.json dist/prebuilt-frontend/code/frontend/src/products.json
fi

# 4. Headless Django collectstatic (uses WhiteNoise, requires zero live DB/Redis)
echo "📦 Executing headless Django collectstatic..."
START_STATIC=$(date +%s%N)

SKIP_SERVICE_VERSION_REQUIREMENTS=1 \
STATIC_COLLECTION=1 \
STATIC_PRECOMPRESS=0 \
DATABASE_URL='postgres:///' \
REDIS_URL='redis:///' \
uv run python manage.py collectstatic --noinput

END_STATIC=$(date +%s%N)
STATIC_MS=$(( (END_STATIC - START_STATIC) / 1000000 ))
STATIC_SEC=$(awk "BEGIN {printf \"%.2f\", $STATIC_MS / 1000}")
echo "✓ Staticfiles collected successfully in ${STATIC_SEC}s"

# 5. Stage staticfiles to dist/staticfiles
mkdir -p dist/staticfiles
cp -r staticfiles/* dist/staticfiles/

echo "======================================================================"
echo "✅ Frontend compilation & static staging completed successfully!"
echo "   frontend/dist size: $(du -sh dist/prebuilt-frontend/code/frontend/dist | awk '{print $1}')"
echo "   staticfiles size:   $(du -sh dist/staticfiles | awk '{print $1}')"
echo "======================================================================"
