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
        PY_BIN="$(command -v python3)"
        VENV_CACHE=""
        if [ -n "${UV_CACHE_DIR:-}" ]; then
            VENV_KEY="$({ printf '%s\n%s\n' "$PY_BIN" "$PWD"; sha256sum uv.lock pyproject.toml 2>/dev/null || shasum -a 256 uv.lock pyproject.toml; } | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)"
            VENV_CACHE="${UV_CACHE_DIR}/venv-v2-${VENV_KEY}"
            mkdir -p "$UV_CACHE_DIR/work"
            rm -rf "$UV_CACHE_DIR"/venv-[0-9a-f]* 2>/dev/null || true
            find "$UV_CACHE_DIR/work" -mindepth 1 -maxdepth 1 -mmin +120 -exec rm -rf {} + 2>/dev/null || true
        fi
        clone_tree() {
            rm -rf "$2"
            cp -al "$1" "$2" 2>/dev/null || { rm -rf "$2"; cp -a "$1" "$2"; }
        }
        RESTORED=0
        if [ -n "$VENV_CACHE" ] && [ -d "$VENV_CACHE" ] && [ ! -e .venv ]; then
            WORK_VENV="$(mktemp -d "$UV_CACHE_DIR/work/venv.XXXXXX")"
            if clone_tree "$VENV_CACHE" "$WORK_VENV"; then
                touch "$WORK_VENV"
                ln -sfn "$WORK_VENV" .venv
                if uv sync --frozen --dev --no-install-package pytest-split --python "$PY_BIN" && uv run --no-sync python -c 'import grpc; from grpc._cython import cygrpc'; then
                    RESTORED=1
                else
                    rm -rf "$VENV_CACHE" "$WORK_VENV" .venv
                fi
            else
                rm -rf "$WORK_VENV"
            fi
        fi
        if [ "$RESTORED" -eq 0 ]; then
            if [ -n "$VENV_CACHE" ] && [ ! -e .venv ]; then
                WORK_VENV="$(mktemp -d "$UV_CACHE_DIR/work/venv.XXXXXX")"
                ln -sfn "$WORK_VENV" .venv
            fi
            uv sync --frozen --dev --no-install-package pytest-split --compile-bytecode --python "$PY_BIN"
            uv run --no-sync python -c 'import grpc; from grpc._cython import cygrpc'
            if [ -n "$VENV_CACHE" ] && [ ! -d "$VENV_CACHE" ]; then
                TMP_CACHE="$(mktemp -d "$UV_CACHE_DIR/venv-tmp.XXXXXX")"
                SRC_VENV="$(realpath .venv)"
                if clone_tree "$SRC_VENV" "$TMP_CACHE"; then
                    mv -T "$TMP_CACHE" "$VENV_CACHE" 2>/dev/null || { [ ! -d "$VENV_CACHE" ] && mv "$TMP_CACHE" "$VENV_CACHE" 2>/dev/null; } || rm -rf "$TMP_CACHE"
                else
                    rm -rf "$TMP_CACHE"
                fi
            fi
        fi
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
