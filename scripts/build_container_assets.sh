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
fi
if [ -d "products/canvas/packages/canvas_builder" ]; then
    mkdir -p "$STAGING_DIR/code/products/canvas/packages"
    cp -r products/canvas/packages/canvas_builder "$STAGING_DIR/code/products/canvas/packages/"
fi

# 8. GeoIP Database Setup
echo "• 8. Staging GeoIP database..."
if [ -f share/GeoLite2-City.mmdb ]; then
    cp share/GeoLite2-City.mmdb "$STAGING_DIR/code/share/"
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

# 10. Prune Host Python Bytecode & Pycache (mirrors .dockerignore, keeps layers lean)
echo "• 10. Pruning host bytecode caches (__pycache__ / .pyc)..."
find "$STAGING_DIR/code" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$STAGING_DIR/code" -type f -name "*.pyc" -delete 2>/dev/null || true

TOTAL_FILES=$(find "$STAGING_DIR/code" -type f | wc -l)
TOTAL_SIZE=$(du -sh "$STAGING_DIR/code" | awk '{print $1}')
echo "======================================================================="
echo "✅ Complete application staging finished!"
echo "   Files staged: $TOTAL_FILES"
echo "   Total size:   $TOTAL_SIZE"
echo "======================================================================="
