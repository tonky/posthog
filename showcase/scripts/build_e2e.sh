#!/usr/bin/env bash
# e2e:test's builds after the frontend's dist (its Build task builds that first, as
# frontend:build does, or finds it restored and current): ci-e2e-playwright.yml's "Install
# plugin_transpiler" and the ingestion image's Node.js build, in the job's task before the
# tests' (run_e2e_tests.sh), as the frontend's build:products rewrites the tracked
# frontend/src/products.tsx, productScenes.tsx and products.json as committed, and a
# tracked file rewritten while the tests' task runs keeps every footprint reading it out of
# the map. Each build runs once per source state of what it reads, so a second job or shard
# finds it done. Runs from anywhere.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
showcase/scripts/exclusive.sh plugin-transpiler bin/turbo --filter=@posthog/plugin-transpiler build
# hogvm first, once for every job (build_hogvm.sh): the Node.js build's turbo restores it.
showcase/scripts/build_hogvm.sh
showcase/scripts/exclusive.sh nodejs-build bin/turbo --filter=@posthog/nodejs build
