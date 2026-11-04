#!/usr/bin/env bash
# container-images-ci.yml's "Lint changed Dockerfile(s) with Hadolint": the files given, as
# jbergstroem/hadolint-gh-action runs them with its defaults (no config, error_level 0):
# every finding is printed, and only a DL rule at error severity fails. hadolint's own
# --failure-threshold error would also fail on a ShellCheck error inside a RUN, which the
# action lets pass.
set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "✗ hadolint.sh: no Dockerfiles given" >&2
    exit 1
fi

out="$(hadolint --no-fail --no-color -f tty "$@")"
[ -z "$out" ] || printf '%s\n' "$out"
if printf '%s\n' "$out" | rg -q 'DL[0-9]+[[:space:]]error:'; then
    exit 1
fi
