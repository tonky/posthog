#!/usr/bin/env bash
# ci-storybook.yml's "Build Storybook" and "Visual regression tests - chromium (<shard>)":
# the static Storybook built (`build --test`), served over HTTP, and @storybook/test-runner
# rendering every story of the shard in Playwright's chromium (the env's browsers,
# PLAYWRIGHT_BROWSERS_PATH), capturing its screenshots. As upstream, the run is capture-only
# (`test:visual:ci:update`): it fails on a story that errors, throws in its play function or
# never settles; comparing the screenshots is Visual Review's (a live service and a token),
# or on a fork PR the VR CLI's exact pixel-hash check, which a different renderer (fonts)
# fails, so neither runs here.
#
#   run_storybook_tests.sh <shard> <total> [story files...]
#   run_storybook_tests.sh --build
#
# The story files (from the checkout's root) narrow the run, as upstream's selective mode;
# none runs every story. One build serves every shard of a source state: storybook:build
# (`--build`) builds it once and records the state's key in dist, which CI restores in each
# shard; a shard finding the key current builds nothing, else it builds under a lock.
# Each shard writes its screenshots and report to a directory of its own under
# .enact/state/storybook (patches/0005), never the committed baselines.
set -euo pipefail
# enact gives the story files relative to the task's directory; jest matches them as
# patterns against absolute paths, so they go as upstream's selective mode passes them,
# from the checkout's root.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
stories=()
for story in "${@:3}"; do
    story="$(cd "$(dirname "$story")" && pwd)/$(basename "$story")"
    stories+=("${story#"$root"/}")
done
cd "$root"

# "Build Storybook", once per source state of what it reads (.storybook/main.ts's stories and
# static dirs, the workspace's manifests).
# quill and hogvm first, once for every job (build_quill.sh, build_hogvm.sh): turbo's
# prepare then restores them.
showcase/scripts/build_quill.sh
showcase/scripts/build_hogvm.sh
# build:products too: storybook's build runs it, a no-op after this one (build_products.sh).
showcase/scripts/build_products.sh
showcase/scripts/build_once.sh storybook-build common/storybook/dist/.enact-build-key \
    frontend products common packages ee/frontend services/mcp/src/ui-apps \
    posthog/templates/replay_player_frame package.json pnpm-lock.yaml pnpm-workspace.yaml \
    turbo.json tsconfig.json patches -- \
    bash -c 'rm -rf common/storybook/dist && bin/turbo --filter=@posthog/storybook prepare &&
        NODE_OPTIONS=--max-old-space-size=32768 pnpm --filter=@posthog/storybook build --test'
[ "${1:-}" != --build ] || exit 0

shard="${1:?usage: run_storybook_tests.sh <shard> <total> [story files...] | --build}"
total="${2:?usage: run_storybook_tests.sh <shard> <total> [story files...] | --build}"

out="$(pwd)/.enact/state/storybook/chromium-${shard}-of-${total}"
rm -rf "$out" && mkdir -p "$out"
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"

# "Serve Storybook in the background": http-server and wait-on, the package's devDependencies,
# the server by its bin (pnpm's shim execs node), so its pid is the server's.
(cd common/storybook && exec node_modules/.bin/http-server dist --port "$port" -a 127.0.0.1 --silent) &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait 2>/dev/null || true' EXIT
pnpm --filter=@posthog/storybook exec wait-on "http://127.0.0.1:$port" --timeout 30000

# Recording footprints for enact (ENACT_FOOTPRINT_DIR set): the test-runner logs the URLs each
# story file's browser requested (.storybook/enact-loads.ts), and storybook_footprint.mjs maps
# them to the repository files the build made them from (dist/enact-chunks.json).
loads=""
if [ -n "${ENACT_FOOTPRINT_DIR:-}" ]; then
    loads="$out/loads"
    mkdir -p "$loads"
fi

# "Run @storybook/test-runner": story files go after `--`, as upstream's selective mode
# passes them. Given files are this shard's share already; with none, jest shards the run.
args=(--shard "$shard/$total")
[ "${#stories[@]}" -eq 0 ] || args=(-- "${stories[@]}")
status=0
OPT_OUT_CAPTURE=1 NODE_OPTIONS=--max-old-space-size=16384 STORYBOOK_SKIP_TAGS=test-skip,test-skip-chromium \
    STORYBOOK_SNAPSHOTS_DIR="$out/snapshots" JEST_JUNIT_OUTPUT_DIR="$out" ENACT_STORYBOOK_LOADS="$loads" \
    pnpm --filter=@posthog/storybook test:visual:ci:update --browsers chromium \
    --url "http://127.0.0.1:$port" "${args[@]}" || status=$?
if [ -n "$loads" ]; then
    node showcase/scripts/storybook_footprint.mjs common/storybook/dist "$loads" "http://127.0.0.1:$port" || status=$((status ? status : 1))
fi
exit "$status"
