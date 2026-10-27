#!/usr/bin/env bash
# Upstream's per-test durations (pytest-split's .test_durations, .test_durations.core and
# .test_durations.temporal), as ci-backend.yml's "Fall back to the last published
# durations" step takes them: the test-durations artifact of the newest successful
# ci-backend-update-test-timing.yml run on master. They aren't in the repository (ignored).
#
# enact balances base's and products' shards with .enact/state/pytest/durations-upstream.json,
# which this writes from them as per-file totals, not with their test ids: they're timed on
# master, newer than the checkout, and enact splits a big file into the ids its history
# names, so a test master added would be passed to pytest, which fails the run on an id it
# can't find. The overlay's own durations-shard-*.json (pytest_timings.py) give the ids.
#
# Usage: showcase/scripts/fetch_test_durations.sh [run id]   (needs gh, authenticated)
# Env:   POSTHOG_REPO (default PostHog/posthog)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
REPO=${POSTHOG_REPO:-PostHog/posthog}
run_id=${1:-$(gh run list --repo "$REPO" --workflow ci-backend-update-test-timing.yml \
    --branch master --status success --limit 1 --json databaseId --jq '.[0].databaseId // empty')}
if [ -z "$run_id" ]; then
    echo "No successful timing run in $REPO: shards split without upstream's durations" >&2
    exit 1
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh run download "$run_id" --repo "$REPO" --name test-durations --dir "$work"
for file in "$work"/.test_durations*; do
    [ -f "$file" ] || continue
    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$file"
    mv "$file" "./$(basename "$file")"
    echo "$(basename "$file"): from run $run_id"
done
mkdir -p .enact/state/pytest
python3 - .enact/state/pytest/durations-upstream.json .test_durations* <<'PY'
import json, sys
tests = {}
for path in sys.argv[2:]:
    tests.update(json.load(open(path)))
files = {}
for node, seconds in tests.items():
    path = node.split("::", 1)[0]
    files[path] = files.get(path, 0.0) + seconds
json.dump(dict(sorted(files.items())), open(sys.argv[1], "w"), indent=0)
print(f"{sys.argv[1]}: {len(files)} files, {len(tests)} tests")
PY
