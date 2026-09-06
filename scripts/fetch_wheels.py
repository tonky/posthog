#!/usr/bin/env python3
# ruff: noqa: T201
"""
Accelerated Wheel Cache Downloader for PostHog Container Builds.
Reads uv.lock, identifies all production dependencies, and downloads matching
wheels (and sdists) into dist/wheel-cache using concurrent HTTP connections.
"""

import os
import sys
import time
import tomllib
import urllib.request
import concurrent.futures


def score_wheel(filename: str) -> int:
    if not filename.endswith(".whl"):
        return -1

    # Check platform compatibility (reject macOS, Windows, musl, ARM)
    if "none-any" in filename or "-any." in filename:
        plat_score = 10
    elif ("manylinux" in filename or "linux" in filename) and "x86_64" in filename and "musl" not in filename:
        plat_score = 20
    else:
        return -1

    # Check python interpreter compatibility (Python 3.13)
    if "py3-none-" in filename or "py2.py3-none-" in filename:
        py_score = 50
    elif "cp313-cp313" in filename:
        py_score = 100
    elif "abi3" in filename:
        py_score = 80
    elif "cp313" in filename:
        py_score = 70
    else:
        return -1

    return plat_score + py_score


def resolve_packages(uv_lock_path: str):
    with open(uv_lock_path, "rb") as f:
        data = tomllib.load(f)

    pkgs_by_name = {p["name"]: p for p in data.get("package", [])}

    # Traverse dependencies starting from posthog (excluding dev)
    visited = set()
    queue = ["posthog"]
    while queue:
        curr = queue.pop(0)
        if curr in visited or curr not in pkgs_by_name:
            continue
        visited.add(curr)
        for dep in pkgs_by_name[curr].get("dependencies", []):
            queue.append(dep["name"])

    selected = {}
    for name in visited:
        if name in ("posthog", "posthog-owners"):
            continue
        pkg = pkgs_by_name[name]
        best_w = None
        best_s = -1
        for w in pkg.get("wheels", []):
            filename = w["url"].split("/")[-1]
            sc = score_wheel(filename)
            if sc > best_s:
                best_s = sc
                best_w = w
        if best_w:
            selected[name] = (
                best_w["url"].split("/")[-1],
                best_w["url"],
                best_w.get("size", 0),
            )
        elif pkg.get("sdist"):
            sd = pkg["sdist"]
            selected[name] = (
                sd["url"].split("/")[-1],
                sd["url"],
                sd.get("size", 0),
            )

    return selected


def download_item(item, target_dir: str):
    name, (filename, url, expected_size) = item
    target_path = os.path.join(target_dir, filename)

    # If file already exists and size matches, skip download
    if os.path.exists(target_path):
        if expected_size == 0 or os.path.getsize(target_path) == expected_size:
            return filename, 0, "cached"

    # Download file
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "posthog-wheel-fetcher/1.0 (Python-urllib)"},
    )
    tmp_path = f"{target_path}.tmp.{os.getpid()}"
    try:
        with urllib.request.urlopen(req, timeout=30) as resp, open(tmp_path, "wb") as out:
            bytes_written = 0
            while chunk := resp.read(65536):
                out.write(chunk)
                bytes_written += len(chunk)
        os.replace(tmp_path, target_path)
        return filename, bytes_written, "downloaded"
    except Exception as e:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        return filename, 0, f"error: {e}"


def main():
    target_dir = sys.argv[1] if len(sys.argv) > 1 else "dist/wheel-cache"
    uv_lock_path = sys.argv[2] if len(sys.argv) > 2 else "uv.lock"

    os.makedirs(target_dir, exist_ok=True)
    keep_file = os.path.join(target_dir, ".keep")
    if not os.path.exists(keep_file):
        with open(keep_file, "w") as f:
            f.write("")

    start_time = time.time()
    packages = resolve_packages(uv_lock_path)
    print(f"📦 Resolving wheels for {len(packages)} packages from {uv_lock_path}...")

    cached_count = 0
    downloaded_count = 0
    error_count = 0
    total_downloaded_bytes = 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
        futures = {executor.submit(download_item, item, target_dir): item[0] for item in packages.items()}
        for future in concurrent.futures.as_completed(futures):
            pkg_name = futures[future]
            try:
                fn, b, status = future.result()
                if status == "cached":
                    cached_count += 1
                elif status == "downloaded":
                    downloaded_count += 1
                    total_downloaded_bytes += b
                else:
                    error_count += 1
                    print(f"  ⚠️  {pkg_name} ({fn}): {status}", file=sys.stderr)
            except Exception as e:
                error_count += 1
                print(f"  ⚠️  {pkg_name}: {e}", file=sys.stderr)

    elapsed = time.time() - start_time
    mb_downloaded = total_downloaded_bytes / (1024 * 1024)
    print(
        f"✓ Wheel cache ready in {target_dir}: {cached_count} cached, {downloaded_count} downloaded ({mb_downloaded:.1f} MB), {error_count} errors in {elapsed:.2f}s"
    )


if __name__ == "__main__":
    main()
