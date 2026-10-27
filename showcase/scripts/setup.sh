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
        # The environment's interpreter, by path: uv's own discovery prefers a uv-managed
        # Python (~/.local/share/uv/python) and downloads one when none fits requires-python.
        # Bytecode compiled once here: the test runs set PYTHONDONTWRITEBYTECODE (as may a
        # developer's shell), so each process would compile every package it imports again,
        # which also put chardet and pydantic over test_startup_import_budget's 100 ms.
        uv sync --frozen --dev --no-install-package pytest-split --compile-bytecode --python "$(command -v python3)"
        uv run --no-sync python -c 'import grpc; from grpc._cython import cygrpc'
        python3 showcase/scripts/backend_runtime.py record
        ;;
    e2e|playwright)
        pnpm --filter=@posthog/playwright... install --frozen-lockfile
        pnpm --filter=@posthog/playwright exec playwright install chromium
        # e2e:test's builds (build_e2e.sh), each when what it reads changed: built only when
        # frontend/dist/index.html was missing, a build of older sources was tested.
        pnpm --filter=@posthog/frontend... install --frozen-lockfile
        bash showcase/scripts/build_e2e.sh
        STATIC_PRECOMPRESS=0 python3 manage.py collectstatic --noinput
        ;;
    all)
        bash showcase/scripts/setup.sh frontend
        bash showcase/scripts/setup.sh backend
        bash showcase/scripts/setup.sh e2e
        ;;
    *) echo 'usage: just setup [frontend|backend|e2e|all]' >&2; exit 64 ;;
esac
