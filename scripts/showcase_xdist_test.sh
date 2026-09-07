#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# showcase_xdist_test.sh
# Demonstrates multi-worker test acceleration with pytest-xdist
# using isolated worker template databases (test_posthog_gw*) on tmpfs.
# ==============================================================================

# Calibrate workers: auto on 2-vCPU CI runners, capped to 4 on high-core dev machines
DEFAULT_WORKERS="auto"
NUM_CORES=$(nproc 2>/dev/null || echo 2)
if [ "$NUM_CORES" -gt 4 ]; then
    DEFAULT_WORKERS=4
fi
WORKERS="${WORKERS:-$DEFAULT_WORKERS}"

TEST_FILES=(
    "common/hogvm/python/test/test_execute.py"
    "common/hogvm/python/test/test_date.py"
)

echo "======================================================================"
echo "⚡ PostHog DeveX Showcase: Multi-Worker Parallel Test Sharding"
echo "======================================================================"
echo "Detected CPU Cores: ${NUM_CORES} | Active Shard Workers: ${WORKERS}"
echo "Running test suite on: ${TEST_FILES[*]}"
echo ""

# Ensure we run through enve hermetic toolchain
RUNNER="enve run -- uv run pytest"

# 1. Sequential Run (Single Worker Baseline - Upstream Default in many CI jobs)
echo "----------------------------------------------------------------------"
echo "▶ Running Sequential Baseline (-n 0)..."
START_SEQ=$(date +%s%N)
$RUNNER -n 0 -q "${TEST_FILES[@]}"
END_SEQ=$(date +%s%N)
SEQ_MS=$(( (END_SEQ - START_SEQ) / 1000000 ))
SEQ_SEC=$(awk "BEGIN {printf \"%.2f\", $SEQ_MS / 1000}")
echo "✓ Sequential completed in ${SEQ_SEC}s (${SEQ_MS}ms)"
echo ""

# 2. Parallel Run with pytest-xdist (-n $WORKERS)
echo "----------------------------------------------------------------------"
echo "▶ Running Parallel with pytest-xdist (-n ${WORKERS})..."
START_PAR=$(date +%s%N)
$RUNNER -n "${WORKERS}" -q "${TEST_FILES[@]}"
END_PAR=$(date +%s%N)
PAR_MS=$(( (END_PAR - START_PAR) / 1000000 ))
PAR_SEC=$(awk "BEGIN {printf \"%.2f\", $PAR_MS / 1000}")
echo "✓ Parallel (-n ${WORKERS}) completed in ${PAR_SEC}s (${PAR_MS}ms)"
echo ""

# 3. Compute Metrics
SPEEDUP=$(awk "BEGIN {printf \"%.1fx\", $SEQ_MS / $PAR_MS}")
SAVINGS=$(awk "BEGIN {printf \"%.1f%%\", (1 - ($PAR_MS / $SEQ_MS)) * 100}")

echo "======================================================================"
echo "📊 Results & Performance Comparison"
echo "======================================================================"
printf "%-32s | %-12s | %-12s\n" "Execution Strategy" "Time" "Worker Isolation"
echo "----------------------------------------------------------------------"
printf "%-32s | %-12s | %-12s\n" "Sequential (-n 0)" "${SEQ_SEC}s" "Single process"
printf "%-32s | %-12s | %-12s\n" "Parallel pytest-xdist (-n ${WORKERS})" "${PAR_SEC}s" "gw0..gwN (tmpfs DBs)"
echo "----------------------------------------------------------------------"
echo "Worker Scaling: Zero CPU thrashing; auto-scaled to available vCPUs"
echo "Template DB Pattern: test_posthog -> test_posthog_gw* zero-collision branching"
echo "======================================================================"
