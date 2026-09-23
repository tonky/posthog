#!/usr/bin/env bash
# Applied by replay to every command inside this overlay's enve environment.
set -euo pipefail
fail() { printf 'Replay Python runtime: %s\n' "$*" >&2; exit 78; }
[[ "${1:-}" == -- ]] || fail 'expected -- <command> [arguments]'
shift
[[ $# -gt 0 ]] || fail 'missing command'

# A compatible host installation is not evidence of an enve-provided runtime.
source "$(dirname "${BASH_SOURCE[0]}")/store_runtime.sh"
python=$(owned_tool python3)
uv=$(owned_tool uv)
# -I prevents host Python environment variables or user site packages affecting checks.
python_version=$("$python" -I -c 'import platform; print(platform.python_version())')
uv_version=$("$uv" --version)
[[ "$python_version" == 3.13.13 ]] || fail "expected Python 3.13.13; enve selected $python_version ($python)"
[[ "$uv_version" == 'uv 0.12.11' || "$uv_version" == 'uv 0.12.11 '* ]] || fail "expected uv 0.12.11; enve selected $uv_version ($uv)"

unset PYTHONHOME PYTHONPATH VIRTUAL_ENV UV_CONFIG_FILE UV_PYTHON_INSTALL_DIR UV_PYTHON_BIN_DIR
export PYTHONNOUSERSITE=1
export UV_PYTHON="$python"
export UV_PYTHON_DOWNLOADS=never
export UV_PYTHON_PREFERENCE=only-system
export UV_PROJECT_ENVIRONMENT="$PWD/.venv"
export UV_FROZEN=true
export PATH="$(dirname "$uv"):$(dirname "$python"):$PATH"
# uv can reuse an existing same-version venv from a different interpreter.
# Compare store objects, not path strings: a venv provisioned through a
# nested enve run records the /nix/store alias of the same interpreter.
if [[ -e .venv/pyvenv.cfg ]]; then
    [[ -x .venv/bin/python ]] || fail 'existing .venv has no executable Python; move it aside and provision again'
    base=$(realpath .venv/bin/python)
    base_object=$(store_relative "$base") || fail "existing .venv uses $base outside the enve store; expected $python. Move .venv aside and provision again"
    [[ "$base_object" == "$(store_relative "$python")" ]] || fail "existing .venv uses $base; expected $python. Move .venv aside and provision again"
fi

mkdir -p .enact
"$python" -I -c 'import json,sys; print(json.dumps({"python":{"version":sys.argv[1],"path":sys.argv[2]},"uv":{"version":sys.argv[3],"path":sys.argv[4]}}))' \
    "$python_version" "$python" '0.12.11' "$uv" > .enact/replay-runtime.json
exec "$@"
