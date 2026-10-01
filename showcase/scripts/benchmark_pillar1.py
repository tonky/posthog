#!/usr/bin/env python3
"""
Benchmark script for Pillar 1:
Comparing Full Test Execution vs. Body-Bypassed Tracing vs. Collection Tracing + Static Analysis.
"""

import ast
import os
import re
import socket
import sys
import tempfile
import time
from pathlib import Path
import pytest

REPO_ROOT = Path("/home/tonky/projects/posthog")

# Sample test files to evaluate
TEST_FILES = [
    "tools/hogli-commands/hogli_commands/tests/test_ast_helpers.py",
    "tools/hogli-commands/hogli_commands/tests/test_change_detection.py",
    "tools/hogli-commands/hogli_commands/tests/test_size_lint.py",
]

class BodyBypassPlugin:
    """Bypasses test body execution while letting collection and test lifecycle run."""
    @pytest.hookimpl(tryfirst=True)
    def pytest_pyfunc_call(self, pyfuncitem):
        return True

    @pytest.hookimpl(tryfirst=True)
    def pytest_runtest_setup(self, item):
        # We also skip heavy fixture setups if possible
        pass

def run_test_suite(name: str, extra_args: list, plugins: list = None):
    print(f"\n--- Running: {name} ---")
    args = [
        "-p", "no:django",
        "--confcutdir=tools/hogli-commands",
        "-q",
    ] + extra_args + [str(REPO_ROOT / f) for f in TEST_FILES]

    t0 = time.perf_counter()
    exit_code = pytest.main(args, plugins=plugins or [])
    elapsed = time.perf_counter() - t0
    print(f"[{name}] Exit code: {exit_code}, Elapsed: {elapsed*1000:.1f}ms ({elapsed:.3f}s)")
    return elapsed

def scan_static_assets(test_files: list[str]):
    """Limited static analysis for open(), .read_text(), and in-function lazy imports."""
    t0 = time.perf_counter()
    results = {}
    total_in_func_imports = 0
    total_file_opens = 0

    open_regex = re.compile(r'\b(open|\.read_text|\.read_bytes)\s*\(\s*([^,\)]+)')
    import_regex = re.compile(r'^\s{4,}(import\s+[\w\.]+|from\s+[\w\.]+\s+import)')

    for tf in test_files:
        full_path = REPO_ROOT / tf
        content = full_path.read_text(encoding="utf-8", errors="replace")
        
        file_opens = []
        for m in open_regex.finditer(content):
            file_opens.append(m.group(0).strip())
            total_file_opens += 1

        in_func_imports = []
        for line in content.splitlines():
            if import_regex.match(line):
                in_func_imports.append(line.strip())
                total_in_func_imports += 1

        results[tf] = {
            "file_opens": file_opens,
            "in_func_imports": in_func_imports,
        }

    elapsed = time.perf_counter() - t0
    print(f"\n[Static Analysis] Scanned {len(test_files)} files in {elapsed*1000:.2f}ms:")
    print(f"  Total open() / read_text() calls found: {total_file_opens}")
    print(f"  Total in-function lazy imports found:   {total_in_func_imports}")
    for tf, data in results.items():
        if data["file_opens"] or data["in_func_imports"]:
            print(f"  {tf}:")
            if data["file_opens"]:
                print(f"    opens: {data['file_opens']}")
            if data["in_func_imports"]:
                print(f"    lazy imports ({len(data['in_func_imports'])}): {data['in_func_imports'][:3]}...")

    return results

if __name__ == "__main__":
    print(f"Pillar 1 Evaluation on {len(TEST_FILES)} test files:")
    for tf in TEST_FILES:
        print(f"  • {tf}")

    # 1. Full Test Execution
    time_full = run_test_suite("Full Execution (Test Bodies Executed)", [])

    # 2. Body-Bypassed Execution
    time_bypass = run_test_suite("Body-Bypassed (pytest_pyfunc_call bypass)", [], plugins=[BodyBypassPlugin()])

    # 3. Collection-Only Execution
    time_collect = run_test_suite("Collection-Only (--collect-only)", ["--collect-only"])

    # 4. Static Analysis Scan
    scan_static_assets(TEST_FILES)

    print("\n" + "="*50)
    print("PERFORMANCE COMPARISON:")
    print(f"  1. Full Execution:         {time_full:.3f}s (baseline: 1.0x)")
    print(f"  2. Body-Bypassed:          {time_bypass:.3f}s ({time_full/time_bypass:.1f}x speedup)")
    print(f"  3. Collection-Only:        {time_collect:.3f}s ({time_full/time_collect:.1f}x speedup)")
    print("="*50)
