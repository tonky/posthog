#!/usr/bin/env bash
# services/mcp's `pnpm build` (build:quill, generate:ui-apps, build-ui-apps), once per source
# state for every mcp job of a run: its test, typecheck and UI-apps check each started with it,
# side by side in one checkout, regenerating src/ui-apps/apps/generated and public/ui-apps
# while the others read them. quill through build_quill.sh, as every job's. Runs from anywhere.
set -euo pipefail
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$scripts/build_quill.sh"
cd "$scripts/../.."
exec showcase/scripts/build_once.sh mcp-ui-apps services/mcp/public/ui-apps/.enact-build-key \
    services/mcp products packages/quill frontend/src package.json pnpm-lock.yaml pnpm-workspace.yaml patches -- \
    bash -c 'cd services/mcp && pnpm run generate:ui-apps && pnpm exec tsx scripts/build-ui-apps.ts'
