#!/usr/bin/env bash
# The site apps' transpiler (common/plugin_transpiler/dist), which products/cdp's transpile()
# runs as `node common/plugin_transpiler/dist/index.js` (core's test_plugin, the site
# functions): base's tests' task reads it, so base's job builds it in a task before (a
# derived output missing or rewritten while the tests run records them incomplete),
# as ci-e2e-playwright.yml's "Install plugin_transpiler" does. Once per source state of
# what it reads (build_once.sh), its install under the checkout's node-modules lock. Runs from
# anywhere.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
exec showcase/scripts/build_once.sh plugin-transpiler common/plugin_transpiler/dist/.enact-build-key \
    common/plugin_transpiler common/esbuilder package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json -- \
    showcase/scripts/exclusive.sh node-modules bash -c \
    'pnpm --filter=@posthog/plugin-transpiler... install --frozen-lockfile && bin/turbo --filter=@posthog/plugin-transpiler build'
