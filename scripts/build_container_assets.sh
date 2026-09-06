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

# 1. Copy Application Code & Schemas (1:1 with Upstream)
echo "• 1. Staging core application modules..."
cp -r posthog ee products common "$STAGING_DIR/code/"
cp manage.py "$STAGING_DIR/code/"

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
echo "• 5. Staging compiled frontend assets & catalog schema..."
mkdir -p "$STAGING_DIR/code/frontend"
# Check standard location or prebuilt staging location
if [ -d "frontend/dist" ]; then
    cp -r frontend/dist "$STAGING_DIR/code/frontend/"
elif [ -d "dist/prebuilt-frontend/code/frontend/dist" ]; then
    cp -r dist/prebuilt-frontend/code/frontend/dist "$STAGING_DIR/code/frontend/"
else
    echo "⚠️ frontend/dist not found — creating structural layout"
    mkdir -p "$STAGING_DIR/code/frontend/dist"
    touch "$STAGING_DIR/code/frontend/dist/index.html"
    touch "$STAGING_DIR/code/frontend/dist/layout.html"
    touch "$STAGING_DIR/code/frontend/dist/exporter.html"
fi

mkdir -p "$STAGING_DIR/code/frontend/src"
if [ -f "frontend/src/products.json" ]; then
    cp frontend/src/products.json "$STAGING_DIR/code/frontend/src/"
elif [ -f "dist/prebuilt-frontend/code/frontend/src/products.json" ]; then
    cp dist/prebuilt-frontend/code/frontend/src/products.json "$STAGING_DIR/code/frontend/src/"
else
    echo "⚠️ products.json not found — writing empty schema"
    echo '{"products": []}' > "$STAGING_DIR/code/frontend/src/products.json"
fi

# 6. Django Static Assets (staticfiles)
echo "• 6. Staging collected staticfiles..."
if [ -d "staticfiles" ] && [ "$(ls -A staticfiles 2>/dev/null)" ]; then
    cp -r staticfiles/* "$STAGING_DIR/code/staticfiles/"
elif [ -d "dist/staticfiles" ]; then
    cp -r dist/staticfiles/* "$STAGING_DIR/code/staticfiles/"
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

# Stage in-tree workspace packages (tools/owners/posthog_owners) into site-packages
if [ -d "tools/owners/posthog_owners" ] && [ -d "$STAGING_DIR/python-runtime/lib/python3.13/site-packages" ]; then
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

# 11. Prune Host Python Bytecode & Pycache (mirrors .dockerignore, keeps layers lean)
echo "• 11. Pruning bytecode caches (__pycache__ / .pyc)..."
find "$STAGING_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$STAGING_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true

TOTAL_FILES=$(find "$STAGING_DIR" -type f | wc -l)
TOTAL_SIZE=$(du -sh "$STAGING_DIR" | awk '{print $1}')
echo "======================================================================="
echo "✅ Complete application & runtime staging finished!"
echo "   Files staged: $TOTAL_FILES"
echo "   Total size:   $TOTAL_SIZE"
echo "======================================================================="
