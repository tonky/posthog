#!/usr/bin/env bash
# The quill packages' dist, built once per source state (build_once.sh) for every job of a run.
#
# Jobs of one checkout built it side by side: quill's build, mcp's `pnpm build` (build:quill),
# the frontend's build and typecheck, storybook's and e2e's turbo prepare. Each vite build
# empties the dist the others write and read (mcp: "ENOENT ... quill/packages/primitives/
# dist/chat/questionnaire.d.ts"). Here the first job builds under the lock, through turbo, so
# the turbo prepares after it restore the same tasks from turbo's cache; the others find the
# key current. The packages are the frontend's and mcp's quill dependencies (turbo's
# `@posthog/quill*` adds quill's storybook and workspace builds). Runs from anywhere.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
exec showcase/scripts/build_once.sh quill-dist packages/quill/packages/quill/dist/.enact-build-key \
    packages/quill package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json tsconfig.json patches -- \
    bin/turbo run build --filter=@posthog/quill --filter=@posthog/quill-tokens \
    --filter=@posthog/quill-primitives --filter=@posthog/quill-components \
    --filter=@posthog/quill-charts --filter=@posthog/quill-blocks
