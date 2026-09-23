#!/usr/bin/env bash
set -euo pipefail
fail() { printf 'Replay Node runtime: %s\n' "$*" >&2; exit 78; }
[[ "${1:-}" == -- ]] || fail 'expected -- <command> [arguments]'
shift
[[ $# -gt 0 ]] || fail 'missing command'
source "$(dirname "${BASH_SOURCE[0]}")/store_runtime.sh"
node=$(owned_tool node)
just=$(owned_tool just)
pnpm=$(owned_tool pnpm)
[[ "$("$node" --version)" == v24.20.0 ]] || fail 'expected Node 24.20.0'
[[ "$("$just" --version)" == 'just 1.58.0' ]] || fail 'expected just 1.58.0'
# pnpm bootstraps the exact packageManager version recorded by upstream.
export npm_config_manage_package_manager_versions=true
export npm_config_package_manager_strict_version=true
export npm_config_userconfig=/dev/null
requested_pnpm=$("$UV_PYTHON" -I -c 'import json; p=json.load(open("package.json"))["packageManager"]; assert p.startswith("pnpm@"); print(p.split("@",1)[1].split("+",1)[0])')
pnpm_version=$("$pnpm" --version)
[[ "$pnpm_version" == "$requested_pnpm" ]] || fail "expected pnpm $requested_pnpm from package.json; selected $pnpm_version"
export PATH="$(dirname "$node"):$(dirname "$just"):$(dirname "$pnpm"):$PATH"
if [[ -n ${ENACT_REPLAY_BINARY:-} ]]; then export PATH="$(dirname "$ENACT_REPLAY_BINARY"):$PATH"; fi
"$UV_PYTHON" -I -c 'import json,sys; p=".enact/replay-runtime.json"; v=json.load(open(p)); v.update(node={"version":"24.20.0","path":sys.argv[1]},just={"version":"1.58.0","path":sys.argv[2]},pnpm={"bootstrap_path":sys.argv[3],"version":sys.argv[4],"project_version":json.load(open("package.json"))["packageManager"]}); open(p,"w").write(json.dumps(v)+"\n")' "$node" "$just" "$pnpm" "$pnpm_version"
exec "$@"
