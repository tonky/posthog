#!/usr/bin/env bash
# ==============================================================================
# tools/showcase/explore-reach-map.sh
# ==============================================================================
# Pre-PR Offline Reachability Explorer.
# Runs stratified seccomp test sampling, generates or updates the reach map,
# and packs it into the high-compression binary format (.enact/trace-reach.bin).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(pwd)"

SAMPLES=50
COMPONENT=""
COMMIT=false
OUTPUT_BIN=".enact/trace-reach.bin"
OUTPUT_JSON=".enact/trace-reach.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--samples)
            SAMPLES="$2"
            shift 2
            ;;
        -c|--component)
            COMPONENT="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_BIN="$2"
            shift 2
            ;;
        --commit)
            COMMIT=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

mkdir -p "$(dirname "${OUTPUT_BIN}")" "$(dirname "${OUTPUT_JSON}")"

echo "🚀 [Reach Explorer] Starting stratified seccomp trace exploration..."
echo "   • Samples: ${SAMPLES}"
if [ -n "${COMPONENT}" ]; then
    echo "   • Target component: ${COMPONENT}"
fi

SAMPLE_ARGS=("-n" "${SAMPLES}" "-o" "${OUTPUT_JSON}")
if [ -n "${COMPONENT}" ]; then
    SAMPLE_ARGS+=("-c" "${COMPONENT}")
fi

# Run seccomp-supervised sampling via enact trace sample
if command -v enact >/dev/null 2>&1; then
    enact trace sample "${SAMPLE_ARGS[@]}"
elif [ -f "${SCRIPT_DIR}/../../target/debug/enact" ]; then
    "${SCRIPT_DIR}/../../target/debug/enact" trace sample "${SAMPLE_ARGS[@]}"
else
    cargo run -p enact-cli -- trace sample "${SAMPLE_ARGS[@]}"
fi

echo ""
echo "📦 [Reach Explorer] Packing JSON reach map into binary (.bin)..."
if command -v enact >/dev/null 2>&1; then
    enact trace pack -i "${OUTPUT_JSON}" -o "${OUTPUT_BIN}"
elif [ -f "${SCRIPT_DIR}/../../target/debug/enact" ]; then
    "${SCRIPT_DIR}/../../target/debug/enact" trace pack -i "${OUTPUT_JSON}" -o "${OUTPUT_BIN}"
else
    cargo run -p enact-cli -- trace pack -i "${OUTPUT_JSON}" -o "${OUTPUT_BIN}"
fi

JSON_SIZE=$(stat -c%s "${OUTPUT_JSON}" 2>/dev/null || stat -f%z "${OUTPUT_JSON}")
BIN_SIZE=$(stat -c%s "${OUTPUT_BIN}" 2>/dev/null || stat -f%z "${OUTPUT_BIN}")
RATIO=$(awk "BEGIN {printf \"%.1f\", ${JSON_SIZE}/${BIN_SIZE}}")

echo ""
echo "✅ [Reach Explorer] Exploration complete!"
echo "   • Raw JSON : $(numfmt --to=iec ${JSON_SIZE} 2>/dev/null || echo "${JSON_SIZE} bytes")"
echo "   • Packed BIN: $(numfmt --to=iec ${BIN_SIZE} 2>/dev/null || echo "${BIN_SIZE} bytes") (${RATIO}x smaller)"

if [ "${COMMIT}" = "true" ]; then
    echo "🌿 Committing updated binary reach map..."
    git add "${OUTPUT_BIN}"
    git commit -m "chore(reach): update binary reach map [skip ci]" || echo "No changes to commit."
fi
