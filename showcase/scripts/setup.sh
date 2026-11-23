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
        CACHE_VENV_WRITE=0
        prune_venv_cache() {
            { ls -1dt "$UV_CACHE_DIR"/venv-v2-* 2>/dev/null || true; } | tail -n +3 | while IFS= read -r stale_venv; do
                rm -rf -- "$stale_venv" 2>/dev/null || true
            done
        }
        if [ -n "${UV_CACHE_DIR:-}" ] && { [ "${GITHUB_ACTIONS:-}" != "true" ] || [ -n "${ENACT_HOST_CACHE:-}" ]; }; then
            VENV_KEY="$({ printf '%s\n' "$PY_BIN"; sha256sum uv.lock pyproject.toml 2>/dev/null || shasum -a 256 uv.lock pyproject.toml; } | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)"
            VENV_CACHE="${UV_CACHE_DIR}/venv-v2-${VENV_KEY}"
            CACHE_VENV_WRITE=1
            mkdir -p "$UV_CACHE_DIR/work"
            rm -rf "$UV_CACHE_DIR"/venv-[0-9a-f]* 2>/dev/null || true
            prune_venv_cache
            # On managed workers (`ENACT_HOST_CACHE`), lease-aware `cache-gc.sh` + entrypoint
            # own `uv/work/venv.*` cleanup; never blind-sweep active leased venvs on startup.
            if [ -z "${ENACT_HOST_CACHE:-}" ]; then
                find "$UV_CACHE_DIR/work" -mindepth 1 -maxdepth 1 -mmin +120 -type d \
                    -exec sh -c 'for d do [ -f "$d/.gha-job-lease" ] || rm -rf "$d"; done' _ {} + 2>/dev/null || true
            fi
        fi
        clone_tree() {
            rm -rf "$2"
            cp -a --reflink=auto "$1" "$2" 2>/dev/null \
                || { rm -rf "$2"; cp -al "$1" "$2" 2>/dev/null; } \
                || { rm -rf "$2"; cp -a "$1" "$2"; }
        }
        write_venv_lease() {
            # Only managed CI workers (`ENACT_HOST_CACHE` + `GITHUB_ACTIONS=true`) have
            # entrypoint/cache-gc lease cleanup; unmanaged local runs rely on bounded `-mmin +120` expiry.
            if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "${ENACT_HOST_CACHE:-}" ]; then
                local lease_id="${GHA_JOB_LEASE_ID:-${HOSTNAME:-}}"
                [ -n "$lease_id" ] && printf 'container=%s\n' "$lease_id" > "$1/.gha-job-lease" 2>/dev/null || true
            fi
        }
        relink_venv_python() {
            local venv_dir="$1"
            if [ -d "$venv_dir/bin" ]; then
                ln -sfn "$PY_BIN" "$venv_dir/bin/python" 2>/dev/null || true
                ln -sfn "$PY_BIN" "$venv_dir/bin/python3" 2>/dev/null || true
            fi
            if [ -f "$venv_dir/pyvenv.cfg" ]; then
                local py_home
                py_home="$(dirname "$PY_BIN")"
                "$PY_BIN" -c '
import sys
from pathlib import Path
cfg, py_home = Path(sys.argv[1]), sys.argv[2]
lines = cfg.read_text().splitlines()
out = [f"home = {py_home}" if l.startswith("home = ") else l for l in lines]
tmp = cfg.with_suffix(".cfg.tmp")
tmp.write_text("\n".join(out) + "\n")
tmp.replace(cfg)
' "$venv_dir/pyvenv.cfg" "$py_home" 2>/dev/null || true
            fi
        }
        venv_cache_inode() {
            stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null || true
        }
        run_under_venv_lock() {
            mkdir -p "$UV_CACHE_DIR/locks" 2>/dev/null || true
            local lock_file="$UV_CACHE_DIR/locks/${VENV_CACHE##*/}.lock"
            "$PY_BIN" -c '
import fcntl, subprocess, sys
with open(sys.argv[1], "a+") as f:
    fcntl.flock(f.fileno(), fcntl.LOCK_EX)
    rc = subprocess.call(sys.argv[2:], close_fds=True)
sys.exit(rc)
' "$lock_file" "$@"
        }
        RESTORED=0
        CLONED_CACHE_INO=""
        if [ -n "$VENV_CACHE" ] && [ ! -e .venv ]; then
            WORK_VENV="$(mktemp -d "$UV_CACHE_DIR/work/venv.XXXXXX")"
            CLONE_OK=0
            if run_under_venv_lock bash -c '
                set -euo pipefail
                cache="$1"; dest="$2"; ino_file="$3"
                if [ -d "$cache" ] && [ ! -f "$cache/pyvenv.cfg" ]; then
                    rm -rf "$cache" 2>/dev/null || true
                fi
                [ -f "$cache/pyvenv.cfg" ] || exit 1
                (stat -c "%d:%i" "$cache" 2>/dev/null || stat -f "%d:%i" "$cache" 2>/dev/null || true) > "$ino_file"
                rm -rf "$dest"
                cp -a --reflink=auto "$cache" "$dest" 2>/dev/null \
                    || { rm -rf "$dest"; cp -al "$cache" "$dest" 2>/dev/null; } \
                    || { rm -rf "$dest"; cp -a "$cache" "$dest"; }
                touch "$cache" "$dest" 2>/dev/null || true
            ' _ "$VENV_CACHE" "$WORK_VENV" "$WORK_VENV.ino"; then
                CLONE_OK=1
                CLONED_CACHE_INO="$(cat "$WORK_VENV.ino" 2>/dev/null || true)"
            fi
            rm -f "$WORK_VENV.ino"
            if [ "$CLONE_OK" -eq 1 ]; then
                relink_venv_python "$WORK_VENV"
                write_venv_lease "$WORK_VENV"
                find "$WORK_VENV" -name '*.pth' -type f -delete 2>/dev/null || true
                # Rewrite cloned entrypoint shebangs on fresh inodes (`uv sync` skips rebuilding
                # unchanged third-party scripts such as `bin/pytest`) so they invoke this checkout.
                "$PY_BIN" -c '
import os, sys
from pathlib import Path
bin_dir, py = Path(sys.argv[1]) / "bin", sys.argv[2]
if bin_dir.is_dir():
    shebang = f"#!{py}\n".encode()
    for p in bin_dir.iterdir():
        if p.name.startswith("python") or not p.is_file() or p.is_symlink():
            continue
        data = p.read_bytes()
        if data.startswith(b"#!") and b"python" in data.split(b"\n", 1)[0]:
            rest = data.split(b"\n", 1)[1] if b"\n" in data else b""
            tmp = p.with_name(f".{p.name}.tmp.{os.getpid()}")
            tmp.write_bytes(shebang + rest)
            os.chmod(tmp, p.stat().st_mode & 0o7777)
            tmp.replace(p)
' "$WORK_VENV" "$PWD/.venv/bin/python3"
                ln -sfn "$WORK_VENV" .venv
                if uv sync --frozen --dev --no-install-package pytest-split --python "$PY_BIN" && uv run --no-sync python -c 'import grpc; from grpc._cython import cygrpc'; then
                    RESTORED=1
                else
                    # Recheck cache identity under the per-key lock before evicting so a fresh
                    # replacement published by another worker is never deleted.
                    run_under_venv_lock bash -c '
                        cache="$1"; expected_ino="$2"
                        cur_ino="$(stat -c "%d:%i" "$cache" 2>/dev/null || stat -f "%d:%i" "$cache" 2>/dev/null || true)"
                        if [ -n "$expected_ino" ] && [ "$cur_ino" = "$expected_ino" ]; then
                            rm -rf "$cache" 2>/dev/null || true
                        fi
                    ' _ "$VENV_CACHE" "$CLONED_CACHE_INO"
                    rm -rf "$WORK_VENV" .venv
                fi
            else
                rm -rf "$WORK_VENV"
            fi
        fi
        if [ "$RESTORED" -eq 0 ]; then
            if [ -n "$VENV_CACHE" ] && [ ! -e .venv ]; then
                WORK_VENV="$(mktemp -d "$UV_CACHE_DIR/work/venv.XXXXXX")"
                # Create the venv BEFORE writing `.gha-job-lease`: uv refuses to initialize
                # `.venv` over a non-empty directory that lacks a Python executable (exit 2).
                uv venv --python "$PY_BIN" "$WORK_VENV"
                write_venv_lease "$WORK_VENV"
                ln -sfn "$WORK_VENV" .venv
            fi
            uv sync --frozen --dev --no-install-package pytest-split --compile-bytecode --python "$PY_BIN"
            uv run --no-sync python -c 'import grpc; from grpc._cython import cygrpc'
            if [ "$CACHE_VENV_WRITE" -eq 1 ] && [ -n "$VENV_CACHE" ]; then
                TMP_CACHE="$(mktemp -d "$UV_CACHE_DIR/venv-tmp.XXXXXX")"
                SRC_VENV="$(realpath .venv)"
                if clone_tree "$SRC_VENV" "$TMP_CACHE"; then
                    rm -f "$TMP_CACHE/.gha-job-lease"
                    run_under_venv_lock bash -c '
                        cache="$1"; staged="$2"
                        if [ -d "$cache" ] && [ ! -f "$cache/pyvenv.cfg" ]; then
                            rm -rf "$cache" 2>/dev/null || true
                        fi
                        if [ ! -f "$cache/pyvenv.cfg" ]; then
                            mv -T "$staged" "$cache" 2>/dev/null || { [ ! -d "$cache" ] && mv "$staged" "$cache" 2>/dev/null; } || rm -rf "$staged"
                        else
                            rm -rf "$staged"
                        fi
                    ' _ "$VENV_CACHE" "$TMP_CACHE"
                else
                    rm -rf "$TMP_CACHE"
                fi
                prune_venv_cache
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
        STATIC_PRECOMPRESS=0 python3 manage.py collectstatic --noinput --ignore '.enact-*'
        ;;
    all)
        bash showcase/scripts/setup.sh frontend
        bash showcase/scripts/setup.sh backend
        bash showcase/scripts/setup.sh e2e
        ;;
    *) echo 'usage: just setup [frontend|backend|e2e|all]' >&2; exit 64 ;;
esac
