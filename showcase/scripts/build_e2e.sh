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

if [ ! -f common/hogvm/typescript/dist/.enact-build-key ] && [ -f .enact/state/live-bin/e2e/hogvm-ts-dist/.enact-build-key ]; then
    mkdir -p common/hogvm/typescript/dist
    cp -a .enact/state/live-bin/e2e/hogvm-ts-dist/. common/hogvm/typescript/dist/
fi
showcase/scripts/build_hogvm.sh

# Fail closed if the restored stamp is present without its required built outputs.
if [ -f nodejs/dist/.enact-build-key ]; then
    for out in \
        nodejs/dist/index.js \
        common/replay-headless/dist/player.html \
        common/replay-headless/dist/protocol.js \
        rust/replay-anonymizer-node/dist/index.js \
        rust/replay-anonymizer-node/index.node \
        rust/common/hogvm/node/index.node; do
        if [ ! -e "$out" ]; then
            rm -f nodejs/dist/.enact-build-key
            break
        fi
    done
fi

# Inputs match `_liveIngestionNode` + `_buildOnceKey` in `.enact/components.cue` so
# `e2e:test` shards reuse `e2e:build` outputs without rebuilding on `nodejs/tests/**` edits.
showcase/scripts/build_once.sh e2e-nodejs-build nodejs/dist/.enact-build-key \
    nodejs/src nodejs/assets nodejs/package.json nodejs/tsconfig.json \
    common/hogvm/typescript/src common/hogvm/typescript/package.json \
    common/hogvm/typescript/tsconfig.json common/hogvm/typescript/tsconfig.build.json \
    common/hogvm/typescript/.parcelrc \
    common/replay-headless/src common/replay-headless/package.json \
    common/replay-headless/tsconfig.json common/replay-headless/build.mjs \
    common/replay-shared/src common/replay-shared/package.json \
    rust/common/hogvm rust/replay-anonymizer rust/replay-anonymizer-node \
    package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json tsconfig.json patches -- \
    showcase/scripts/exclusive.sh nodejs-build bin/turbo --filter=@posthog/nodejs build

if [ "${ENACT_JOB:-}" = "build" ]; then
    rm -rf .enact/state/live-bin/e2e/hogvm-ts-dist
    mkdir -p .enact/state/live-bin/e2e/hogvm-ts-dist
    cp -a common/hogvm/typescript/dist/. .enact/state/live-bin/e2e/hogvm-ts-dist/
fi
