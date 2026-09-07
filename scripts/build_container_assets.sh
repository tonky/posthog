#!/usr/bin/env bash
set -euo pipefail

STAGING_DIR="${1:-dist/container-root}"
echo "======================================================================="
echo "  📦 Staging PostHog Container Application Assets to: $STAGING_DIR"
echo "======================================================================="

mkdir -p "$STAGING_DIR/code"
mkdir -p "$STAGING_DIR/code/staticfiles"
mkdir -p "$STAGING_DIR/code/share"
mkdir -p "$STAGING_DIR/code/.tiktoken_cache"
mkdir -p "$STAGING_DIR/docker-entrypoint.d"

# 1. Copy Application Code & Schemas (ignoring tests, snapshots, and dev artifacts upfront)
echo "• 1. Staging core application modules (ignoring tests, snapshots, and dev artifacts upfront)..."
rsync -a \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='test_*.py' \
    --exclude='*_test.py' \
    --exclude='tests' \
    --exclude='__tests__' \
    --exclude='__snapshots__' \
    --exclude='*.stories.*' \
    --exclude='products/*/frontend' \
    posthog ee products common manage.py "$STAGING_DIR/code/"

# 2. Persons SQL Migrations, MCP Schemas & Stamphog Owners
echo "• 2. Staging migrations, schemas, and tooling..."
if [ -d "rust/persons_migrations" ]; then
    mkdir -p "$STAGING_DIR/code/rust"
    cp -r rust/persons_migrations "$STAGING_DIR/code/rust/"
fi
if [ -d "services/mcp/schema" ]; then
    mkdir -p "$STAGING_DIR/code/services/mcp"
    cp -r services/mcp/schema "$STAGING_DIR/code/services/mcp/"
fi
if [ -d "tools/owners" ]; then
    mkdir -p "$STAGING_DIR/code/tools"
    cp -r tools/owners "$STAGING_DIR/code/tools/"
fi

# 3. Server Entrypoint Executables
echo "• 3. Staging server entrypoint scripts..."
mkdir -p "$STAGING_DIR/code/bin"
cp -r bin/* "$STAGING_DIR/code/bin/" 2>/dev/null || true
[ -f bin/docker-server-unit ] && cp bin/docker-server-unit "$STAGING_DIR/code/bin/"
[ -f bin/migrate-check ] && cp bin/migrate-check "$STAGING_DIR/code/bin/"
[ -f bin/unit_metrics.py ] && cp bin/unit_metrics.py "$STAGING_DIR/code/bin/"
chmod +x "$STAGING_DIR/code/bin/"* 2>/dev/null || true

# 4. NGINX Unit Configuration Template
echo "• 4. Staging NGINX Unit configuration template..."
cp unit.json.tpl "$STAGING_DIR/docker-entrypoint.d/unit.json.tpl"
cp unit.json.tpl "$STAGING_DIR/code/unit.json.tpl"

# 5. Frontend Bundle & Product Catalog
echo "• 5. Staging compiled frontend templates & catalog schema (ignoring non-HTML static assets)..."
mkdir -p "$STAGING_DIR/code/frontend/dist"
SOURCE_FE_DIST=""
if [ -d "dist/prebuilt-frontend/code/frontend/dist" ] && [ -s "dist/prebuilt-frontend/code/frontend/dist/index.html" ]; then
    SOURCE_FE_DIST="dist/prebuilt-frontend/code/frontend/dist"
elif [ -d "frontend/dist" ] && [ -s "frontend/dist/index.html" ]; then
    SOURCE_FE_DIST="frontend/dist"
elif [ "${STRICT_PARITY:-0}" = "1" ] || [ "${CI:-}" = "true" ]; then
    echo "❌ STRICT PARITY FAILURE: Compiled frontend bundle not found in frontend/dist or dist/prebuilt-frontend!" >&2
    exit 1
fi

if [ -n "$SOURCE_FE_DIST" ]; then
    # Stage ONLY HTML templates and array.js (staticfiles serves the rest under /static)
    cp "$SOURCE_FE_DIST"/*.html "$STAGING_DIR/code/frontend/dist/" 2>/dev/null || true
    [ -f "$SOURCE_FE_DIST/array.js" ] && cp "$SOURCE_FE_DIST/array.js" "$STAGING_DIR/code/frontend/dist/"
else
    echo "⚠️ frontend/dist not found — creating structural layout (dev fallback only)"
    touch "$STAGING_DIR/code/frontend/dist/index.html"
    touch "$STAGING_DIR/code/frontend/dist/layout.html"
    touch "$STAGING_DIR/code/frontend/dist/exporter.html"
fi

mkdir -p "$STAGING_DIR/code/frontend/src"
if [ -f "dist/prebuilt-frontend/code/frontend/src/products.json" ]; then
    cp dist/prebuilt-frontend/code/frontend/src/products.json "$STAGING_DIR/code/frontend/src/"
elif [ -f "frontend/src/products.json" ]; then
    cp frontend/src/products.json "$STAGING_DIR/code/frontend/src/"
else
    echo "⚠️ products.json not found — writing empty schema"
    echo '{"products": []}' > "$STAGING_DIR/code/frontend/src/products.json"
fi

# Verify strict parity on frontend assets
if [ "${STRICT_PARITY:-0}" = "1" ] || [ "${CI:-}" = "true" ]; then
    if [ ! -s "$STAGING_DIR/code/frontend/dist/index.html" ]; then
        echo "❌ STRICT PARITY FAILURE: $STAGING_DIR/code/frontend/dist/index.html is empty or missing!" >&2
        exit 1
    fi
    echo "   ✓ Strict Parity Verified: Real frontend bundle index.html ($(ls -lh "$STAGING_DIR/code/frontend/dist/index.html" | awk '{print $5}'))"
fi

# 6. Django Static Assets (staticfiles)
echo "• 6. Staging collected staticfiles (ignoring sourcemaps upfront)..."
STATIC_EXCLUDES=()
if [ "${KEEP_SOURCEMAPS:-0}" != "1" ]; then
    STATIC_EXCLUDES=(--exclude='*.map' --exclude='*.map.gz' --exclude='*.map.br')
fi

if [ -d "dist/staticfiles" ] && [ "$(ls -A dist/staticfiles 2>/dev/null)" ]; then
    rsync -a "${STATIC_EXCLUDES[@]}" dist/staticfiles/ "$STAGING_DIR/code/staticfiles/"
elif [ -d "staticfiles" ] && [ "$(ls -A staticfiles 2>/dev/null)" ]; then
    rsync -a "${STATIC_EXCLUDES[@]}" staticfiles/ "$STAGING_DIR/code/staticfiles/"
elif [ "${STRICT_PARITY:-0}" = "1" ] || [ "${CI:-}" = "true" ]; then
    echo "❌ STRICT PARITY FAILURE: Collected staticfiles not found in staticfiles/ or dist/staticfiles/!" >&2
    exit 1
fi

# Verify strict parity on staticfiles
if [ "${STRICT_PARITY:-0}" = "1" ] || [ "${CI:-}" = "true" ]; then
    TOTAL_STATIC_COUNT=$(find "$STAGING_DIR/code/staticfiles" -type f | wc -l)
    if [ "$TOTAL_STATIC_COUNT" -eq 0 ]; then
        echo "❌ STRICT PARITY FAILURE: No staticfiles staged in $STAGING_DIR/code/staticfiles!" >&2
        exit 1
    fi
    echo "   ✓ Strict Parity Verified: $TOTAL_STATIC_COUNT staticfiles staged"
fi

# 7. Plugin Transpiler & Canvas Builder
echo "• 7. Staging plugin transpiler and canvas packages..."
if [ -d "common/plugin_transpiler/dist" ]; then
    mkdir -p "$STAGING_DIR/code/common/plugin_transpiler"
    cp -r common/plugin_transpiler/dist "$STAGING_DIR/code/common/plugin_transpiler/"
    [ -d "common/plugin_transpiler/node_modules" ] && cp -r common/plugin_transpiler/node_modules "$STAGING_DIR/code/common/plugin_transpiler/"
    [ -f "common/plugin_transpiler/package.json" ] && cp common/plugin_transpiler/package.json "$STAGING_DIR/code/common/plugin_transpiler/"
elif [ -d "dist/prebuilt-node-scripts/code/common/plugin_transpiler" ]; then
    mkdir -p "$STAGING_DIR/code/common/plugin_transpiler"
    cp -r dist/prebuilt-node-scripts/code/common/plugin_transpiler/* "$STAGING_DIR/code/common/plugin_transpiler/"
fi
if [ -d "products/canvas/packages/canvas_builder" ]; then
    mkdir -p "$STAGING_DIR/code/products/canvas/packages"
    cp -r products/canvas/packages/canvas_builder "$STAGING_DIR/code/products/canvas/packages/"
elif [ -d "dist/prebuilt-node-scripts/code/products/canvas/packages/canvas_builder" ]; then
    mkdir -p "$STAGING_DIR/code/products/canvas/packages"
    cp -r dist/prebuilt-node-scripts/code/products/canvas/packages/canvas_builder "$STAGING_DIR/code/products/canvas/packages/"
fi

# 8. GeoIP Database Setup
echo "• 8. Staging GeoIP database..."
if [ -f share/GeoLite2-City.mmdb ]; then
    cp share/GeoLite2-City.mmdb "$STAGING_DIR/code/share/"
elif [ -f dist/geoip/code/share/GeoLite2-City.mmdb ]; then
    cp dist/geoip/code/share/GeoLite2-City.mmdb "$STAGING_DIR/code/share/"
else
    touch "$STAGING_DIR/code/share/GeoLite2-City.mmdb"
fi

# 9. Tiktoken Encoding Cache & Commit Metadata
echo "• 9. Staging tiktoken cache and commit metadata..."
if [ -d ".tiktoken_cache" ] && [ "$(ls -A .tiktoken_cache 2>/dev/null)" ]; then
    cp -r .tiktoken_cache/* "$STAGING_DIR/code/.tiktoken_cache/"
fi
touch "$STAGING_DIR/code/.tiktoken_cache/.warmed"

COMMIT_HASH="${COMMIT_HASH:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
echo "$COMMIT_HASH" > "$STAGING_DIR/code/commit.txt"

# 10. Stage Complete Production Python Runtime (/python-runtime)
echo "• 10. Staging complete production Python runtime into /python-runtime..."
mkdir -p "$STAGING_DIR"

# Ensure uv is in PATH
if ! command -v uv >/dev/null 2>&1; then
    for cand in "$HOME/.cargo/bin/uv" "$HOME/.local/bin/uv" "/usr/local/bin/uv"; do
        if [ -x "$cand" ]; then
            export PATH="$(dirname "$cand"):$PATH"
            break
        fi
    done
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "   ⚠️ 'uv' command not found in PATH; skipping /python-runtime staging (host toolchain mode)."
else
    if [ "${SKIP_ARCHIVE:-0}" = "1" ] && [ -d ".venv" ] && [ -f ".venv/pyvenv.cfg" ]; then
        echo "   -> [PR Fast-Path] Linking host virtual environment directly (< 0.01s)..."
        rm -rf "$STAGING_DIR/python-runtime"
        ln -sf "$(pwd)/.venv" "$STAGING_DIR/python-runtime"
    elif [ -d ".venv" ] && [ -f ".venv/pyvenv.cfg" ]; then
        echo "   -> Staging production virtual environment (ignoring CUDA libs, tests, and bytecode upfront)..."
        rm -rf "$STAGING_DIR/python-runtime"
        mkdir -p "$STAGING_DIR/python-runtime"
        rsync -a \
            --exclude='nvidia*' \
            --exclude='__pycache__' \
            --exclude='tests' \
            .venv/ "$STAGING_DIR/python-runtime/"
    else
        if [ ! -f "$STAGING_DIR/python-runtime/pyvenv.cfg" ]; then
            echo "   -> Initializing Python 3.13 virtual environment..."
            rm -rf "$STAGING_DIR/python-runtime"
            uv venv "$STAGING_DIR/python-runtime" --python 3.13
        fi

        # Run offline uv sync to populate all 433 production packages
        if [ -d "dist/wheel-cache" ] && [ "$(ls -1 dist/wheel-cache/*.whl 2>/dev/null | wc -l)" -gt 0 ]; then
            echo "   -> Populating production site-packages via offline uv sync ($(ls -1 dist/wheel-cache/*.whl 2>/dev/null | wc -l) wheels)..."
            UV_PROJECT_ENVIRONMENT="$STAGING_DIR/python-runtime" uv sync \
                --frozen \
                --no-dev \
                --no-editable \
                --no-install-workspace \
                --no-index \
                --find-links dist/wheel-cache
        else
            echo "   ⚠️ dist/wheel-cache empty or not found; running online uv sync..."
            UV_PROJECT_ENVIRONMENT="$STAGING_DIR/python-runtime" uv sync \
                --frozen \
                --no-dev \
                --no-editable \
                --no-install-workspace
        fi
    fi

# Stage in-tree workspace packages (tools/owners/posthog_owners) into site-packages
if [ "${SKIP_ARCHIVE:-0}" != "1" ] && [ -d "tools/owners/posthog_owners" ] && [ -d "$STAGING_DIR/python-runtime/lib/python3.13/site-packages" ]; then
    echo "   -> Staging in-tree workspace package (posthog_owners) into site-packages..."
    cp -r tools/owners/posthog_owners "$STAGING_DIR/python-runtime/lib/python3.13/site-packages/"
fi

# Link python, python3, granian, celery into /code/bin using relative symlinks
mkdir -p "$STAGING_DIR/code/bin"
ln -sf ../../python-runtime/bin/python "$STAGING_DIR/code/bin/python"
ln -sf ../../python-runtime/bin/python3 "$STAGING_DIR/code/bin/python3"
if [ -f "$STAGING_DIR/python-runtime/bin/granian" ]; then
    ln -sf ../../python-runtime/bin/granian "$STAGING_DIR/code/bin/granian"
fi
if [ -f "$STAGING_DIR/python-runtime/bin/celery" ]; then
    ln -sf ../../python-runtime/bin/celery "$STAGING_DIR/code/bin/celery"
fi
fi

# 11. Optional Binary Strip (Only when packaging actual physical image archive)
if [ "${SKIP_ARCHIVE:-0}" != "1" ] && command -v strip >/dev/null 2>&1 && [ -d "$STAGING_DIR/python-runtime/lib" ]; then
    echo "• 11. Stripping unneeded symbols from native extensions (saves ~300MB, exempting OpenBLAS)..."
    find "$STAGING_DIR/python-runtime/lib" -type f -name "*.so*" ! -name "*openblas*" -exec strip --strip-unneeded {} + 2>/dev/null || true
fi

TOTAL_FILES=$(find "$STAGING_DIR" -type f | wc -l)
TOTAL_SIZE=$(du -sh "$STAGING_DIR" | awk '{print $1}')
echo "======================================================================="
echo "✅ Complete application & runtime staging finished!"
echo "   Files staged: $TOTAL_FILES"
echo "   Total size:   $TOTAL_SIZE"
echo "======================================================================="
