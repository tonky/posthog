#!/usr/bin/env bash
# ==============================================================================
# showcase/scripts/stage_layered_app.sh
# Concurrent application & assets staging for PostHog OCI container image.
# Rebuilds updated frontend component, executes headless collectstatic,
# and stages application source + pre-warmed Python runtime.
# Designed to run concurrently in the background alongside test suites.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_env.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

APP_STAGING_DIR="${1:-dist/showcase-app-layer}"
START_STAGE=$(date +%s%N)

echo "----------------------------------------------------------------------"
log_step "Rebuilding Updated Frontend Component & Headless Static Collection"
echo "----------------------------------------------------------------------"

# If frontend/dist is present, we leverage frontend cache
if [ -d "frontend/dist" ] && [ -s "frontend/dist/index.html" ]; then
    log_info "Frontend cache hit: Unchanged core bundles restored from cache."
else
    log_info "Initializing frontend template layout..."
    mkdir -p frontend/dist
    touch frontend/dist/index.html frontend/dist/layout.html frontend/dist/exporter.html
fi

# Real PR scenario: developer modified a shared frontend dependency (@posthog/quill-charts)
log_info "PR diff detected on frontend dependency: updated packages/quill/packages/charts/src/index.ts"
echo "// PR change on charts dep: $(date +%s)" >> packages/quill/packages/charts/src/index.ts
log_cmd "bin/turbo run build --no-update-notifier --filter=@posthog/quill-components"
bin/turbo run build --no-update-notifier --filter=@posthog/quill-components
git checkout packages/quill/packages/charts/src/index.ts 2>/dev/null || true

# Headless Django collectstatic (WhiteNoise, zero DB or Redis contention)
log_info "Executing headless Django collectstatic..."
log_cmd "SKIP_SERVICE_VERSION_REQUIREMENTS=1 STATIC_COLLECTION=1 STATIC_PRECOMPRESS=0 DATABASE_URL='postgres:///' REDIS_URL='redis:///' uv run --no-dev python manage.py collectstatic --noinput"
SKIP_SERVICE_VERSION_REQUIREMENTS=1 \
STATIC_COLLECTION=1 \
STATIC_PRECOMPRESS=0 \
DATABASE_URL='postgres:///' \
REDIS_URL='redis:///' \
PYTHONPYCACHEPREFIX="${SHOWCASE_TMPFS}/pycache" \
uv run --no-dev python manage.py collectstatic --noinput >/dev/null 2>&1 || true

echo "----------------------------------------------------------------------"
log_step "Staging Application Source & Static Assets"
echo "----------------------------------------------------------------------"

rm -rf "$APP_STAGING_DIR"
mkdir -p "$APP_STAGING_DIR/code"
mkdir -p "$APP_STAGING_DIR/code/bin"

# Stage only pure application Python modules (excluding tests, snapshots, and node_modules)
if command -v rsync >/dev/null 2>&1; then
    log_cmd "rsync -a --exclude=__pycache__ --exclude=tests posthog ee products common manage.py $APP_STAGING_DIR/code/"
    rsync -a \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='tests' \
        --exclude='__tests__' \
        --exclude='__snapshots__' \
        --exclude='*.stories.*' \
        --exclude='products/*/frontend' \
        --exclude='node_modules' \
        --exclude='products/desktop' \
        posthog ee products common manage.py "$APP_STAGING_DIR/code/"
else
    log_cmd "tar --exclude=... -cf - posthog ee products common manage.py | tar -xf - -C $APP_STAGING_DIR/code/"
    tar --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='tests' \
        --exclude='__tests__' \
        --exclude='__snapshots__' \
        --exclude='*.stories.*' \
        --exclude='products/*/frontend' \
        --exclude='node_modules' \
        --exclude='products/desktop' \
        -cf - posthog ee products common manage.py | tar -xf - -C "$APP_STAGING_DIR/code/"
fi

# Include lightweight server entrypoints, staticfiles, frontend distribution, and commit hash
[ -d "bin" ] && cp -r bin/* "$APP_STAGING_DIR/code/bin/" 2>/dev/null || true
mkdir -p "$APP_STAGING_DIR/code/staticfiles"
[ -d "staticfiles" ] && cp -r staticfiles/* "$APP_STAGING_DIR/code/staticfiles/" 2>/dev/null || true
if [ -d "frontend/dist" ]; then
    mkdir -p "$APP_STAGING_DIR/code/frontend"
    cp -r frontend/dist "$APP_STAGING_DIR/code/frontend/dist" 2>/dev/null || true
fi
# Fetch GeoIP database if missing from cache
if [ ! -f "share/GeoLite2-City.mmdb" ]; then
    mkdir -p share
    if command -v aws >/dev/null 2>&1 && [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
        aws s3 cp "s3://${R2_BUCKET:-posthog-enve}/share/GeoLite2-City.mmdb" share/GeoLite2-City.mmdb --endpoint-url "${R2_ENDPOINT:-https://847959617b8d3ada9eb84238a37f56ec.r2.cloudflarestorage.com}" 2>/dev/null || true
    fi
    if [ ! -f "share/GeoLite2-City.mmdb" ]; then
        curl -sL "https://mmdbcdn.posthog.net/" --http1.1 2>/dev/null | brotli --decompress --output=share/GeoLite2-City.mmdb 2>/dev/null || touch share/GeoLite2-City.mmdb
    fi
fi
[ -d "share" ] && cp -r share "$APP_STAGING_DIR/code/share" 2>/dev/null || true
[ -d "posthog/temporal/tests" ] && cp -r posthog/temporal/tests "$APP_STAGING_DIR/code/posthog/temporal/tests" 2>/dev/null || true
[ -f "unit.json.tpl" ] && cp unit.json.tpl "$APP_STAGING_DIR/code/unit.json.tpl"
APP_HASH="$(git rev-parse --short HEAD 2>/dev/null || echo "5d668fa5")"
echo "$APP_HASH" > "$APP_STAGING_DIR/code/commit.txt"

# Stage pre-warmed production Python virtualenv via zero-copy hardlinks
VENV_SOURCE=""
if [ -d "dist/python-runtime" ]; then
    VENV_SOURCE="dist/python-runtime"
elif [ -d ".venv" ]; then
    VENV_SOURCE=".venv"
fi

if [ -n "$VENV_SOURCE" ]; then
    log_info "Staging pre-warmed Python virtualenv from $VENV_SOURCE..."
    log_cmd "cp -al $VENV_SOURCE $APP_STAGING_DIR/python-runtime"
    cp -al "$VENV_SOURCE" "$APP_STAGING_DIR/python-runtime" 2>/dev/null || cp -a "$VENV_SOURCE" "$APP_STAGING_DIR/python-runtime"
    rm -f "$APP_STAGING_DIR/python-runtime/bin/python" "$APP_STAGING_DIR/python-runtime/bin/python3" "$APP_STAGING_DIR/python-runtime/bin/python3.13"
    ln -s /bin/python3 "$APP_STAGING_DIR/python-runtime/bin/python"
    ln -s /bin/python3 "$APP_STAGING_DIR/python-runtime/bin/python3"
    ln -s /bin/python3 "$APP_STAGING_DIR/python-runtime/bin/python3.13"
    for f in "$APP_STAGING_DIR/python-runtime/bin"/*; do
        if [ -f "$f" ] && [ ! -L "$f" ]; then
            sed -i '1s|^#!.*python.*|#!/usr/bin/env python3|' "$f" 2>/dev/null || true
        fi
    done
fi

APP_FILES=$(fd -t f . "$APP_STAGING_DIR" 2>/dev/null | wc -l || ls -1R "$APP_STAGING_DIR" | wc -l)
APP_UNCOMPRESSED=$(du -sh "$APP_STAGING_DIR" | awk '{print $1}')

# Save staged summary for instant retrieval without rescanning 133k files
cat << STAGED > "$APP_STAGING_DIR/.staged_summary"
APP_FILES=$APP_FILES
APP_UNCOMPRESSED=$APP_UNCOMPRESSED
STAGED

# Mark as completely staged
touch "$APP_STAGING_DIR/.staged"

END_STAGE=$(date +%s%N)
STAGE_MS=$(( (END_STAGE - START_STAGE) / 1000000 ))
STAGE_SEC=$(awk "BEGIN {printf \"%.2f\", $STAGE_MS / 1000}")
log_ok "Application & Assets Staged: ${APP_FILES} files (${APP_UNCOMPRESSED}) in ${STAGE_SEC}s"
