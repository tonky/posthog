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

# 1. Copy Application Code & Schemas
echo "• Copying application modules..."
cp -r posthog ee products common "$STAGING_DIR/code/"
cp manage.py "$STAGING_DIR/code/"

# 2. Copy Executables & Startup Scripts
echo "• Copying server entrypoint scripts..."
mkdir -p "$STAGING_DIR/code/bin"
cp bin/docker-server-unit "$STAGING_DIR/code/bin/"
[ -f bin/migrate-check ] && cp bin/migrate-check "$STAGING_DIR/code/bin/"
[ -f bin/unit_metrics.py ] && cp bin/unit_metrics.py "$STAGING_DIR/code/bin/"
chmod +x "$STAGING_DIR/code/bin/"*

# 3. Unit Configuration Template
echo "• Staging NGINX Unit configuration template..."
cp unit.json.tpl "$STAGING_DIR/docker-entrypoint.d/unit.json.tpl"
cp unit.json.tpl "$STAGING_DIR/code/unit.json.tpl"

# 4. GeoIP Database Setup (if available or empty placeholder)
if [ -f share/GeoLite2-City.mmdb ]; then
    cp share/GeoLite2-City.mmdb "$STAGING_DIR/code/share/"
else
    touch "$STAGING_DIR/code/share/GeoLite2-City.mmdb"
fi

# 5. Pre-warm tiktoken BPE cache placeholder
touch "$STAGING_DIR/code/.tiktoken_cache/.warmed"

echo "✅ Staging completed successfully at $(date)!"
