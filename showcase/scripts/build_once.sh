#!/usr/bin/env bash
# Runs a build once per source state of what it reads:
#
#   showcase/scripts/build_once.sh <name> <stamp file> <input path...> -- <command...>
#
# The jobs of a run (and every shard of one) find the build of the checkout's current sources
# done: the first to arrive builds under exclusive.sh's lock <name> and records the state's key
# in <stamp file>, inside the build's output; the others, waiting on the lock, find the key
# current and build nothing. The key covers the command and the inputs' content: their
# committed entries, tracked changes and untracked files (a git-ignored build output isn't
# an input), never the commit, so a build output restored from another commit's cache
# (enact's `outputs`, CI's build-outputs job) whose inputs are the same is current. A
# command may run builds of its own (the frontend's quill and hogvm): each takes its own
# lock. Run from the checkout root.
set -euo pipefail

name="${1:?usage: build_once.sh <name> <stamp file> <input path...> -- <command...>}"
stamp="${2:?usage: build_once.sh <name> <stamp file> <input path...> -- <command...>}"
shift 2
inputs=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do inputs+=("$1"); shift; done
[ "$#" -gt 1 ] && [ "${#inputs[@]}" -gt 0 ] || { echo "usage: build_once.sh <name> <stamp file> <input path...> -- <command...>" >&2; exit 64; }
shift

if [ -z "${BUILD_ONCE_LOCKED:-}" ]; then
    BUILD_ONCE_LOCKED=1 exec "$(dirname "${BASH_SOURCE[0]}")/exclusive.sh" "$name" "$0" "$name" "$stamp" "${inputs[@]}" -- "$@"
fi

unset BUILD_ONCE_LOCKED
key="$({
    printf '%s\0' "$@"
    git ls-tree -r HEAD -- "${inputs[@]}"
    git diff HEAD --binary -- "${inputs[@]}"
    git ls-files -o --exclude-standard -z -- "${inputs[@]}" | xargs -0 sha256sum --
} | sha256sum | cut -c1-64)"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$key" ]; then
    echo "$name current ($key)"
    exit 0
fi
"$@"
mkdir -p "$(dirname "$stamp")"
echo "$key" >"$stamp"
