#!/usr/bin/env bash
# ci-mcp-ui-apps.yml's "Build and validate UI Apps", from services/mcp: the UI apps built,
# then every directory under public/ui-apps (but one named `generated`) holding its
# main.js and styles.css. Upstream lists them with find(1); bash's globstar here.
set -euo pipefail
shopt -s globstar nullglob

# As `pnpm run build:ui-apps`, once per source state for every mcp job (build_mcp_ui_apps.sh).
"$(dirname "${BASH_SOURCE[0]}")/build_mcp_ui_apps.sh"

missing=0 apps=0
for app_dir in public/ui-apps/**/; do
    app_dir="${app_dir%/}"
    [ "$app_dir" != public/ui-apps ] || continue
    app="$(basename "$app_dir")"
    [ "$app" != generated ] || continue
    apps=$((apps + 1))
    if [ ! -f "$app_dir/main.js" ]; then
        echo "✗ Missing main.js for $app" >&2
        missing=1
    fi
    if [ ! -f "$app_dir/styles.css" ]; then
        echo "✗ Missing styles.css for $app" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 1
echo "All $apps UI Apps built successfully."
