#!/usr/bin/env bash
# The frontend's build:products under one lock for every job of a checkout: the frontend's
# test shards, its typecheck, e2e's and storybook's builds ran it side by side, each writing
# then renaming the same frontend/tmp/products.tsx ("ENOENT: no such file or directory,
# rename '.../frontend/tmp/products.tsx'"). Its own digest (frontend/.cache/products.hash)
# makes each run after the first a no-op. Runs from anywhere.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
exec showcase/scripts/exclusive.sh frontend-products pnpm --filter=@posthog/frontend build:products
