#!/usr/bin/env bash
set -euo pipefail
case "${1:-frontend}" in
    frontend)
        pnpm --filter=@posthog/frontend... install --frozen-lockfile
        bin/turbo --filter=@posthog/frontend prepare
        pnpm --filter=@posthog/frontend build:products
        pnpm --filter=@posthog/frontend exec jest --version
        ;;
    backend)
        uv sync --frozen --compile-bytecode
        uv run --no-sync python -c 'import grpc; from grpc._cython import cygrpc'
        python3 showcase/scripts/backend_runtime.py record
        ;;
    e2e|playwright)
        pnpm --filter=@posthog/playwright... install --frozen-lockfile
        pnpm --filter=@posthog/playwright exec playwright install chromium
        if [ ! -f "frontend/dist/index.html" ] || [ ! -s "frontend/dist/index.html" ] || rg -q '<div id="root">PostHog App</div>' frontend/dist/index.html 2>/dev/null; then
            echo "Building frontend for E2E testing..."
            pnpm --filter=@posthog/frontend... install --frozen-lockfile
            bin/turbo --filter=@posthog/frontend prepare
            pnpm --filter=@posthog/frontend build:products
            pnpm --filter=@posthog/frontend build
            STATIC_PRECOMPRESS=0 python3 manage.py collectstatic --noinput
        fi
        ;;
    all)
        bash showcase/scripts/setup.sh frontend
        bash showcase/scripts/setup.sh backend
        bash showcase/scripts/setup.sh e2e
        ;;
    *) echo 'usage: just setup [frontend|backend|e2e|all]' >&2; exit 64 ;;
esac
