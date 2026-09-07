#!/usr/bin/env python3
# ruff: noqa: T201
"""
Deterministically partitions 100% of all PostHog backend test files (4,919 test files)
into N balanced shards (default: 20) across Core & EE, Warehouse Sources, and Products.
"""

import os
import sys
import functools

EXCLUDE_DIRS = {
    "node_modules",
    ".venv",
    ".git",
    "dist",
    "__pycache__",
    ".turbo",
    "staticfiles",
    ".pytest_cache",
    ".ruff_cache",
    "user_scripts",
    "rust_integration",
    "desktop",
    "packages",
}


@functools.lru_cache(maxsize=1)
def get_all_test_files():
    test_files = []
    for root_dir in ["posthog", "ee", "products"]:
        for root, dirs, files in os.walk(root_dir):
            dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
            for f in files:
                if (
                    f.endswith(".py")
                    and not f.endswith("__init__.py")
                    and not f.endswith("conftest.py")
                    and f != "test_cases_discovery.py"
                ):
                    if f.startswith("test_") or f.endswith("_test.py"):
                        test_files.append(os.path.join(root, f))
    return sorted(test_files)


def chunk(lst, n):
    k, m = divmod(len(lst), n)
    return [lst[i * k + min(i, m) : (i + 1) * k + min(i + 1, m)] for i in range(n)]


def get_shard_files(shard_idx, total_shards=20):
    all_files = get_all_test_files()
    core = [f for f in all_files if f.startswith("posthog/") or f.startswith("ee/")]
    wh = [f for f in all_files if f.startswith("products/warehouse_sources/")]
    prod = [
        f
        for f in all_files
        if not (f.startswith("posthog/") or f.startswith("ee/") or f.startswith("products/warehouse_sources/"))
    ]

    core_count = 6 if total_shards == 20 else max(1, total_shards * 6 // 20)
    wh_count = 6 if total_shards == 20 else max(1, total_shards * 6 // 20)
    prod_count = total_shards - core_count - wh_count

    all_shards = chunk(core, core_count) + chunk(wh, wh_count) + chunk(prod, prod_count)
    idx = shard_idx - 1
    if 0 <= idx < len(all_shards):
        return all_shards[idx]
    return []


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: get_shard_targets.py <shard_index_1_based> [total_shards]", file=sys.stderr)
        sys.exit(1)
    shard_idx = int(sys.argv[1])
    total_shards = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    files = get_shard_files(shard_idx, total_shards)
    print(" ".join(files))
