#!/usr/bin/env bash
# @posthog/hogvm's dist (common/hogvm/typescript), built once per source state (build_once.sh)
# for every job of a run.
#
# Its build empties dist first (`pnpm clean`), and jobs of one checkout built it side by side:
# the frontend's `pnpm --filter=@posthog/frontend... build`, the turbo prepares of the
# frontend's typecheck, storybook, e2e and nodejs. One emptied the dist under another's tsc
# (nodejs:build: "Cannot find module '@posthog/hogvm'"). Here the first job builds under the
# lock, through turbo (without SHARD_INDEX and SHARD_COUNT, which turbo.json's build keys on,
# as every caller's), so the turbo prepares after it restore the task from turbo's cache; the
# others find it built. Runs from anywhere.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
exec showcase/scripts/build_once.sh hogvm-dist common/hogvm/typescript/dist/.enact-build-key \
    common/hogvm/typescript package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json tsconfig.json patches -- \
    env -u SHARD_INDEX -u SHARD_COUNT bin/turbo run build --filter=@posthog/hogvm
