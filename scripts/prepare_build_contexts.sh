#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-all}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

prepare_frontend() {
    echo "======================================================================="
    echo "  📦 Staging Frontend Named Context (dist/prebuilt-frontend)..."
    echo "======================================================================="
    mkdir -p dist/prebuilt-frontend/code/frontend/src
    if [ -d "frontend/dist" ] && [ "$(ls -A frontend/dist 2>/dev/null)" ]; then
        rm -rf dist/prebuilt-frontend/code/frontend/dist
        cp -r frontend/dist dist/prebuilt-frontend/code/frontend/
    else
        mkdir -p dist/prebuilt-frontend/code/frontend/dist
        touch dist/prebuilt-frontend/code/frontend/dist/index.html
        touch dist/prebuilt-frontend/code/frontend/dist/layout.html
        touch dist/prebuilt-frontend/code/frontend/dist/exporter.html
    fi

    if [ -f "frontend/src/products.json" ]; then
        cp frontend/src/products.json dist/prebuilt-frontend/code/frontend/src/products.json
    else
        echo '{"products": []}' > dist/prebuilt-frontend/code/frontend/src/products.json
    fi
    echo "✓ Frontend context staged in dist/prebuilt-frontend"
}

prepare_node_scripts() {
    echo "======================================================================="
    echo "  📦 Building and Staging Node Scripts (dist/prebuilt-node-scripts)..."
    echo "======================================================================="
    local TARGET_DIR="dist/prebuilt-node-scripts/code"
    mkdir -p "$TARGET_DIR/common/plugin_transpiler"
    mkdir -p "$TARGET_DIR/products/canvas/packages"

    # Build plugin-transpiler on host ext4 if dist missing
    if [ ! -d "common/plugin_transpiler/dist" ] || [ ! -d "common/plugin_transpiler/node_modules" ]; then
        echo "• Compiling @posthog/plugin-transpiler on host..."
        pnpm --filter=@posthog/plugin-transpiler... install --frozen-lockfile
        bin/turbo --filter=@posthog/plugin-transpiler build
    fi

    # Build canvas_builder on host if node_modules missing
    if [ ! -d "products/canvas/packages/canvas_builder/node_modules" ]; then
        echo "• Installing dependencies for canvas_builder..."
        npm ci --ignore-scripts --omit=dev --no-audit --no-fund --prefix products/canvas/packages/canvas_builder
    fi

    # Set up standalone babel for transpiler
    echo "• Linking standalone Babel for plugin transpiler..."
    node -e "
        const fs = require('fs');
        const path = require('path');
        const babelDir = path.dirname(require.resolve('@babel/standalone/package.json'));
        const targetDir = path.join('common/plugin_transpiler/node_modules/@babel/standalone');
        fs.mkdirSync(path.dirname(targetDir), { recursive: true });
        fs.cpSync(babelDir, targetDir, { recursive: true });
    " 2>/dev/null || true

    # Stage to dist/prebuilt-node-scripts
    rm -rf "$TARGET_DIR/common/plugin_transpiler" "$TARGET_DIR/products/canvas/packages/canvas_builder"
    mkdir -p "$TARGET_DIR/common/plugin_transpiler"
    mkdir -p "$TARGET_DIR/products/canvas/packages"

    cp -r common/plugin_transpiler/dist "$TARGET_DIR/common/plugin_transpiler/"
    cp -r common/plugin_transpiler/node_modules "$TARGET_DIR/common/plugin_transpiler/"
    cp common/plugin_transpiler/package.json "$TARGET_DIR/common/plugin_transpiler/"
    cp -r products/canvas/packages/canvas_builder "$TARGET_DIR/products/canvas/packages/"

    echo "✓ Node scripts context staged in dist/prebuilt-node-scripts"
}

prepare_geoip() {
    echo "======================================================================="
    echo "  📦 Staging GeoIP Named Context (dist/geoip)..."
    echo "======================================================================="
    mkdir -p dist/geoip/code/share
    if [ -f "share/GeoLite2-City.mmdb" ]; then
        cp share/GeoLite2-City.mmdb dist/geoip/code/share/GeoLite2-City.mmdb
    else
        # Pre-fetch if missing, or create empty stub
        if command -v curl >/dev/null 2>&1 && command -v brotli >/dev/null 2>&1; then
            echo "• Fetching GeoLite2-City.mmdb..."
            ( curl -s -L "https://mmdbcdn.posthog.net/" --http1.1 | brotli --decompress --output=dist/geoip/code/share/GeoLite2-City.mmdb ) || touch dist/geoip/code/share/GeoLite2-City.mmdb
        else
            touch dist/geoip/code/share/GeoLite2-City.mmdb
        fi
    fi
    echo "✓ GeoIP context staged in dist/geoip"
}

prepare_unit_provider() {
    echo "======================================================================="
    echo "  📦 Staging NGINX Unit Provider Named Context (dist/unit-provider)..."
    echo "======================================================================="
    mkdir -p dist/unit-provider/opt/unit/sbin
    # If a pre-compiled unit binary is available locally, stage it; otherwise base image fallback is used
    if [ -f "opt/unit/sbin/unitd" ]; then
        cp -r opt/unit dist/unit-provider/opt/
    else
        touch dist/unit-provider/opt/unit/sbin/.keep
    fi
    echo "✓ Unit provider context staged in dist/unit-provider"
}

case "$TARGET" in
    frontend)
        prepare_frontend
        ;;
    node-scripts)
        prepare_node_scripts
        ;;
    geoip)
        prepare_geoip
        ;;
    unit-provider)
        prepare_unit_provider
        ;;
    all)
        prepare_frontend
        prepare_node_scripts
        prepare_geoip
        prepare_unit_provider
        ;;
    *)
        echo "Usage: $0 [frontend|node-scripts|geoip|unit-provider|all]"
        exit 1
        ;;
esac

echo "✅ Context preparation for '$TARGET' complete!"
