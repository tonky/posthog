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
        if command -v pnpm >/dev/null 2>&1; then
            echo "• Compiling @posthog/plugin-transpiler on host..."
            pnpm --filter=@posthog/plugin-transpiler... install --frozen-lockfile || true
            bin/turbo --filter=@posthog/plugin-transpiler build || true
        elif command -v corepack >/dev/null 2>&1; then
            echo "• Enabling corepack and compiling @posthog/plugin-transpiler on host..."
            corepack enable || true
            corepack pnpm --filter=@posthog/plugin-transpiler... install --frozen-lockfile || true
            bin/turbo --filter=@posthog/plugin-transpiler build || true
        else
            echo "• pnpm/corepack not available on host, skipping host compilation..."
        fi
    fi

    # Build canvas_builder on host if node_modules missing
    if [ ! -d "products/canvas/packages/canvas_builder/node_modules" ]; then
        if command -v npm >/dev/null 2>&1; then
            echo "• Installing dependencies for canvas_builder..."
            npm ci --ignore-scripts --omit=dev --no-audit --no-fund --prefix products/canvas/packages/canvas_builder || true
        fi
    fi

    # Set up standalone babel for transpiler
    if command -v node >/dev/null 2>&1; then
        echo "• Linking standalone Babel for plugin transpiler..."
        node -e "
            const fs = require('fs');
            const path = require('path');
            try {
                const babelDir = path.dirname(require.resolve('@babel/standalone/package.json'));
                const targetDir = path.join('common/plugin_transpiler/node_modules/@babel/standalone');
                fs.mkdirSync(path.dirname(targetDir), { recursive: true });
                fs.cpSync(babelDir, targetDir, { recursive: true });
            } catch (e) {}
        " 2>/dev/null || true
    fi

    # Stage to dist/prebuilt-node-scripts
    rm -rf "$TARGET_DIR/common/plugin_transpiler" "$TARGET_DIR/products/canvas/packages/canvas_builder"
    mkdir -p "$TARGET_DIR/common/plugin_transpiler/dist"
    mkdir -p "$TARGET_DIR/common/plugin_transpiler/node_modules"
    mkdir -p "$TARGET_DIR/products/canvas/packages/canvas_builder"

    if [ -d "common/plugin_transpiler/dist" ]; then
        cp -r common/plugin_transpiler/dist "$TARGET_DIR/common/plugin_transpiler/"
    else
        touch "$TARGET_DIR/common/plugin_transpiler/dist/.keep"
    fi

    if [ -d "common/plugin_transpiler/node_modules" ]; then
        cp -r common/plugin_transpiler/node_modules "$TARGET_DIR/common/plugin_transpiler/"
    else
        touch "$TARGET_DIR/common/plugin_transpiler/node_modules/.keep"
    fi

    if [ -f "common/plugin_transpiler/package.json" ]; then
        cp common/plugin_transpiler/package.json "$TARGET_DIR/common/plugin_transpiler/"
    else
        touch "$TARGET_DIR/common/plugin_transpiler/package.json"
    fi

    if [ -d "products/canvas/packages/canvas_builder" ]; then
        cp -r products/canvas/packages/canvas_builder "$TARGET_DIR/products/canvas/packages/"
    else
        touch "$TARGET_DIR/products/canvas/packages/canvas_builder/.keep"
    fi

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
        if command -v curl >/dev/null 2>&1; then
            echo "• Fetching GeoLite2-City.mmdb..."
            if command -v brotli >/dev/null 2>&1; then
                ( curl -s -L "https://mmdbcdn.posthog.net/" --http1.1 | brotli --decompress --output=dist/geoip/code/share/GeoLite2-City.mmdb ) || touch dist/geoip/code/share/GeoLite2-City.mmdb
            elif command -v enve >/dev/null 2>&1; then
                ( curl -s -L "https://mmdbcdn.posthog.net/" --http1.1 | enve run -- brotli --decompress --output=dist/geoip/code/share/GeoLite2-City.mmdb ) || touch dist/geoip/code/share/GeoLite2-City.mmdb
            else
                touch dist/geoip/code/share/GeoLite2-City.mmdb
            fi
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

prepare_wheels() {
    echo "======================================================================="
    echo "  📦 Staging Python Wheels Named Context (dist/wheel-cache)..."
    echo "======================================================================="
    mkdir -p dist/wheel-cache
    if [ ! -f "dist/wheel-cache/.keep" ]; then
        touch dist/wheel-cache/.keep
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 scripts/fetch_wheels.py dist/wheel-cache uv.lock || true
    fi
    echo "✓ Python wheels context staged in dist/wheel-cache"
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
    wheels)
        prepare_wheels
        ;;
    all)
        prepare_frontend
        prepare_node_scripts
        prepare_geoip
        prepare_unit_provider
        prepare_wheels
        ;;
    *)
        echo "Usage: $0 [frontend|node-scripts|geoip|unit-provider|wheels|all]"
        exit 1
        ;;
esac

echo "✅ Context preparation for '$TARGET' complete!"
