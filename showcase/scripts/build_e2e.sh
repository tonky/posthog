#!/usr/bin/env bash
# e2e:build and e2e:test builds: plugin_transpiler, hogvm, and @posthog/nodejs (including
# replay-headless and replay-anonymizer-node), each gated by build_once.sh stamps so e2e:test
# shards skip rebuilding in < 50ms when restored from e2e:build + plugin_transpiler:build outputs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export CI=true
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

showcase/scripts/build_once.sh plugin-transpiler common/plugin_transpiler/dist/.enact-build-key \
    common/plugin_transpiler common/esbuilder package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json -- \
    showcase/scripts/exclusive.sh node-modules bash -c \
    'CI=true COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm --filter=@posthog/plugin-transpiler... install --frozen-lockfile --config.confirmModulesPurge=false && bin/turbo --filter=@posthog/plugin-transpiler build'

if [ ! -f common/hogvm/typescript/dist/.enact-build-key ] && [ -f rust/.enact-live-bin/e2e/hogvm-ts-dist/.enact-build-key ]; then
    mkdir -p common/hogvm/typescript/dist
    cp -a rust/.enact-live-bin/e2e/hogvm-ts-dist/. common/hogvm/typescript/dist/
fi
showcase/scripts/build_hogvm.sh

showcase/scripts/build_once.sh e2e-nodejs-build nodejs/dist/.enact-build-key \
    nodejs common/hogvm/typescript common/replay-headless common/replay-shared \
    rust/common/hogvm rust/replay-anonymizer rust/replay-anonymizer-node \
    package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json tsconfig.json patches -- \
    showcase/scripts/exclusive.sh nodejs-build bin/turbo --filter=@posthog/nodejs build

if [ "${ENACT_JOB:-}" = "build" ]; then
    rm -rf rust/.enact-live-bin/e2e/hogvm-ts-dist
    mkdir -p rust/.enact-live-bin/e2e/hogvm-ts-dist
    cp -a common/hogvm/typescript/dist/. rust/.enact-live-bin/e2e/hogvm-ts-dist/
fi
