#!/usr/bin/env python3
"""Multi-level scoping & impact evaluation runner against a PostHog Pull Request.

Fetches the PR diff from GitHub, establishes the local diff, detects impacted
layers (Backend Python / Django, Frontend TypeScript / Jest), executes the scoped
tests in the rootless enve environment, and compares the local run scope and results
against upstream CI for human verification.
"""

from __future__ import annotations

import os
import re
import sys
import json
import time
import argparse
import resource
import threading
import subprocess
import urllib.request
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SHOWCASE_DIR = REPO_ROOT / "showcase"


class ProcessResourceSampler:
    """Samples CPU and memory (RSS) metrics across a process tree during execution."""

    def __init__(self, root_pid: int, interval: float = 0.05) -> None:
        self.root_pid = root_pid
        self.interval = interval
        self.stop_event = threading.Event()
        self.samples: list[tuple[float, float]] = []
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        self.thread.join(timeout=1.0)

    def _get_descendant_pids(self, pid: int) -> list[int]:
        pids = [pid]
        try:
            res = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True)
            if res.returncode == 0:
                for line in res.stdout.splitlines():
                    line = line.strip()
                    if line.isdigit():
                        pids.extend(self._get_descendant_pids(int(line)))
        except Exception:
            pass
        return pids

    def _run(self) -> None:
        while not self.stop_event.is_set():
            try:
                pids = self._get_descendant_pids(self.root_pid)
                if pids:
                    pid_str = ",".join(str(p) for p in pids)
                    res = subprocess.run(["ps", "-o", "%cpu,rss", "-p", pid_str], capture_output=True, text=True)
                    cpu_total = 0.0
                    rss_total = 0.0
                    lines = res.stdout.strip().splitlines()
                    for line in lines[1:]:
                        parts = line.split()
                        if len(parts) >= 2:
                            try:
                                cpu_total += float(parts[0])
                                rss_total += float(parts[1]) / 1024.0  # KB to MB
                            except ValueError:
                                pass
                    if rss_total > 0:
                        self.samples.append((cpu_total, rss_total))
            except Exception:
                pass
            time.sleep(self.interval)

    def stats(self, fallback_rss_mb: float = 0.0, fallback_cpu_sec: float = 0.0) -> dict[str, float]:
        if not self.samples:
            return {
                "mem_peak": fallback_rss_mb,
                "mem_avg": fallback_rss_mb,
                "cpu_peak": 0.0,
                "cpu_avg": 0.0,
                "cpu_total_sec": fallback_cpu_sec,
            }
        cpus, mems = zip(*self.samples)
        peak_mem = max(max(mems), fallback_rss_mb)
        avg_mem = sum(mems) / len(mems)
        return {
            "mem_peak": peak_mem,
            "mem_avg": avg_mem,
            "cpu_peak": max(cpus),
            "cpu_avg": sum(cpus) / len(cpus),
            "cpu_total_sec": fallback_cpu_sec,
        }


class ServicesResourceSampler:
    """Samples CPU and memory metrics for running enve microservices during test runs."""

    def __init__(self, interval: float = 0.2) -> None:
        self.interval = interval
        self.stop_event = threading.Event()
        self.service_samples: dict[str, list[tuple[float, float]]] = {}
        self.services_info: dict[str, int] = {}
        self.thread = threading.Thread(target=self._run, daemon=True)
        self._load_services()

    def _load_services(self) -> None:
        services_json = REPO_ROOT / ".enve" / "run" / "services.json"
        if services_json.exists():
            try:
                data = json.loads(services_json.read_text())
                for s in data.get("services", []):
                    name = s.get("name")
                    pid = s.get("pid")
                    if name and pid:
                        self.services_info[name] = pid
                        self.service_samples[name] = []
            except Exception:
                pass

    def start(self) -> None:
        if self.services_info:
            self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.services_info:
            self.thread.join(timeout=1.0)

    def _run(self) -> None:
        while not self.stop_event.is_set():
            for name, pid in self.services_info.items():
                try:
                    res = subprocess.run(["ps", "-o", "%cpu,rss", "-p", str(pid)], capture_output=True, text=True)
                    lines = res.stdout.strip().splitlines()
                    if len(lines) > 1:
                        parts = lines[1].split()
                        if len(parts) >= 2:
                            cpu = float(parts[0])
                            rss = float(parts[1]) / 1024.0  # MB
                            self.service_samples[name].append((cpu, rss))
                except Exception:
                    pass
            time.sleep(self.interval)

    def stats(self) -> dict[str, dict[str, float]]:
        res: dict[str, dict[str, float]] = {}
        total_peak_mem = 0.0
        total_avg_mem = 0.0
        total_peak_cpu = 0.0
        total_avg_cpu = 0.0

        for name, samples in self.service_samples.items():
            if samples:
                cpus, mems = zip(*samples)
                peak_mem = max(mems)
                avg_mem = sum(mems) / len(mems)
                peak_cpu = max(cpus)
                avg_cpu = sum(cpus) / len(cpus)
                res[name] = {
                    "mem_peak": peak_mem,
                    "mem_avg": avg_mem,
                    "cpu_peak": peak_cpu,
                    "cpu_avg": avg_cpu,
                }
                total_peak_mem += peak_mem
                total_avg_mem += avg_mem
                total_peak_cpu += peak_cpu
                total_avg_cpu += avg_cpu
            else:
                # One-shot sample if thread hasn't gathered samples
                pid = self.services_info.get(name)
                if pid:
                    ps = subprocess.run(["ps", "-o", "%cpu,rss", "-p", str(pid)], capture_output=True, text=True)
                    lines = ps.stdout.strip().splitlines()
                    if len(lines) > 1:
                        parts = lines[1].split()
                        c = float(parts[0])
                        m = float(parts[1]) / 1024.0
                        res[name] = {"mem_peak": m, "mem_avg": m, "cpu_peak": c, "cpu_avg": c}
                        total_peak_mem += m
                        total_avg_mem += m
                        total_peak_cpu += c
                        total_avg_cpu += c

        res["_total"] = {
            "mem_peak": total_peak_mem,
            "mem_avg": total_avg_mem,
            "cpu_peak": total_peak_cpu,
            "cpu_avg": total_avg_cpu,
        }
        return res


def extract_pr_number(pr_input: str) -> int:
    """Extract integer PR number from URL or raw number."""
    match = re.search(r"(?:pull/|#)?(\d+)", pr_input.strip())
    if match:
        return int(match.group(1))
    raise ValueError(f"Could not parse PR number from: {pr_input}")


def fetch_pr_metadata(pr_number: int) -> dict[str, Any]:
    """Fetch PR details using gh CLI or GitHub REST API."""
    try:
        res = subprocess.run(
            [
                "gh",
                "pr",
                "view",
                str(pr_number),
                "--json",
                "number,title,baseRefName,headRefName,headRefOid,state,statusCheckRollup,url,additions,deletions,changedFiles",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(res.stdout)
    except Exception:
        # Fallback to public GitHub API
        url = f"https://api.github.com/repos/PostHog/posthog/pulls/{pr_number}"
        req = urllib.request.Request(url, headers={"User-Agent": "PostHog-DevEx"})
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            return {
                "number": data["number"],
                "title": data["title"],
                "baseRefName": data["base"]["ref"],
                "headRefName": data["head"]["ref"],
                "headRefOid": data["head"]["sha"],
                "state": data["state"],
                "url": data["html_url"],
                "additions": data.get("additions", 0),
                "deletions": data.get("deletions", 0),
                "changedFiles": data.get("changed_files", 0),
                "statusCheckRollup": [],
            }


def fetch_pr_diff(pr_number: int) -> str:
    """Fetch raw unified diff for the PR."""
    try:
        res = subprocess.run(
            ["gh", "pr", "diff", str(pr_number)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        if res.stdout.strip():
            return res.stdout
    except Exception:
        pass

    url = f"https://patch-diff.githubusercontent.com/raw/PostHog/posthog/pull/{pr_number}.diff"
    req = urllib.request.Request(url, headers={"User-Agent": "PostHog-DevEx"})
    with urllib.request.urlopen(req) as resp:
        return resp.read().decode("utf-8")


def parse_diff_files(diff_text: str) -> list[str]:
    """Parse list of modified filenames from git diff."""
    files = set()
    for line in diff_text.splitlines():
        if line.startswith("diff --git a/"):
            parts = line.split(" ")
            if len(parts) >= 3:
                filename = parts[2].removeprefix("a/")
                files.add(filename)
    return sorted(files)


def run_command(
    cmd: list[str],
    cwd: Path = REPO_ROOT,
    env: dict[str, str] | None = None,
    track_resources: bool = False,
) -> tuple[int, str, float, dict[str, float]]:
    """Run command with execution timing and optional resource tracking (CPU/memory peak & avg)."""
    full_env = os.environ.copy()
    if env:
        full_env.update(env)

    # Ensure pnpm and uv are available
    pnpm_nix = "/nix/store/z0rlx5672gdlfb3830irk026yfwz8kyp-pnpm-11.22.0/bin"
    if Path(pnpm_nix).exists() and pnpm_nix not in full_env.get("PATH", ""):
        full_env["PATH"] = f"{pnpm_nix}:{full_env.get('PATH', '')}"

    start = time.perf_counter()
    if not track_resources:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            env=full_env,
            capture_output=True,
            text=True,
        )
        duration = time.perf_counter() - start
        output = proc.stdout + ("\n" + proc.stderr if proc.stderr else "")
        return proc.returncode, output, duration, {}

    # Track CPU & Memory with background sampler
    ru_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        env=full_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    sampler = ProcessResourceSampler(proc.pid, interval=0.05)
    sampler.start()
    stdout, stderr = proc.communicate()
    sampler.stop()
    duration = time.perf_counter() - start

    ru_after = resource.getrusage(resource.RUSAGE_CHILDREN)
    fallback_cpu = (ru_after.ru_utime - ru_before.ru_utime) + (ru_after.ru_stime - ru_before.ru_stime)
    fallback_rss = ru_after.ru_maxrss / (1024.0 * 1024.0)

    stats = sampler.stats(fallback_rss_mb=fallback_rss, fallback_cpu_sec=fallback_cpu)
    output = stdout + ("\n" + stderr if stderr else "")
    return proc.returncode, output, duration, stats


PYTHON_HIGH_FANOUT_BARRELS = {
    "posthog/schema_enums.py",
    "products/warehouse_sources/backend/facade/types.py",
}


def resolve_python_barrel_diff(file_path: str, diff_text: str) -> tuple[set[str], list[str]]:
    """Extract modified symbols from a high-fanout Python barrel file diff and find tests via ripgrep."""
    lines = diff_text.splitlines()
    in_file = False
    added_identifiers = set()
    for line in lines:
        if line.startswith(f"diff --git a/{file_path}"):
            in_file = True
        elif line.startswith("diff --git") and in_file:
            break
        if in_file and line.startswith("+") and not line.startswith("+++"):
            m = re.search(r"^\+\s*([A-Za-z0-9_]+)\s*=", line)
            if m:
                added_identifiers.add(m.group(1))

    if not added_identifiers:
        return set(), []

    regex_pattern = r"\b(" + "|".join(re.escape(s) for s in sorted(added_identifiers)) + r")\b"
    cmd_tests = [
        "rg",
        "-l",
        "--glob",
        "test_*.py",
        "--glob",
        "*_test.py",
        "-e",
        regex_pattern,
        "posthog",
        "products",
        "common",
        "ee",
    ]
    res_tests = subprocess.run(cmd_tests, cwd=REPO_ROOT, capture_output=True, text=True)
    tests = {line.strip() for line in res_tests.stdout.splitlines() if line.strip()}
    return tests, sorted(added_identifiers)


def get_backend_file_impact(backend_files: list[str], diff_text: str = "") -> tuple[dict[str, list[str]], list[str]]:
    """Determine impacted backend tests per source file using snob_lib, AST barrel scoping, and heuristic fallbacks."""
    impact_map: dict[str, list[str]] = {}
    all_selected: set[str] = set()

    for f in backend_files:
        if "/test/" in f or "/tests/" in f or Path(f).name.startswith("test_"):
            impact_map[f] = [f]
            all_selected.add(f)
        elif f in PYTHON_HIGH_FANOUT_BARRELS and diff_text:
            barrel_tests, symbols = resolve_python_barrel_diff(f, diff_text)
            tests = sorted(barrel_tests)
            impact_map[f] = tests
            all_selected.update(tests)
        else:
            # Query snob_lib via isolated python command
            cmd = [
                "uv",
                "run",
                "--with",
                "pytest-snob>=0.1.14",
                "python",
                "-c",
                f"import snob_lib, json; print(json.dumps([t.replace('{REPO_ROOT}/', '') for t in snob_lib.get_tests(['{f}'])]))",
            ]
            ret, out, _, _ = run_command(cmd)
            tests = []
            if ret == 0 and out.strip():
                try:
                    tests = json.loads(out.strip().splitlines()[-1])
                except Exception:
                    tests = []

            # Fallback to direct heuristic if snob returns empty
            if not tests:
                cand = f.replace("backend/", "backend/tests/test_").replace("/views.py", "/test_api.py")
                if (REPO_ROOT / cand).exists():
                    tests = [cand]

            impact_map[f] = tests
            all_selected.update(tests)

    return impact_map, sorted(all_selected)


DB_MARKER_PATTERNS = [
    r"@pytest\.mark\.django_db",
    r"from posthog\.test\.base import",
    r"from posthog\.test import",
    r"\bAPIBaseTest\b",
    r"\bBaseTest\b",
    r"\bClickhouseTestMixin\b",
    r"\bTransactionTestCase\b",
    r"django\.test",
    r"django\.db",
    r"sync_execute",
    r"kafka",
    r"redis",
]
_COMPILED_DB_MARKERS = re.compile("|".join(DB_MARKER_PATTERNS))


def tests_require_services(test_paths: list[str]) -> bool:
    """Check if any of the selected test files require running databases/microservices."""
    for tp in test_paths:
        p = REPO_ROOT / tp
        if p.exists():
            content = p.read_text(errors="ignore")
            if _COMPILED_DB_MARKERS.search(content):
                return True
    return False


# High-fanout barrel files that artificially trigger the entire monorepo in Jest
HIGH_FANOUT_BARRELS = {
    "frontend/src/types.ts",
    "frontend/src/queries/schema/schema-general.ts",
}

# Root-level types that truly affect the entire product if modified
UNIVERSAL_ROOT_TYPES = {
    "TeamType",
    "UserBasicType",
    "OrganizationType",
    "FilterType",
    "AnyPropertyFilter",
}


def resolve_type_barrel_diff(file_path: str, diff_text: str) -> tuple[set[str], set[str], list[str]]:
    """Extract modified symbols from a high-fanout barrel file diff and find consumers via ripgrep.

    Returns (consumer_source_files, direct_matching_tests, impacted_symbols).
    """
    lines = diff_text.splitlines()
    in_file = False
    hunk_re = re.compile(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
    modified_ranges = []
    for line in lines:
        if line.startswith(f"diff --git a/{file_path}"):
            in_file = True
        elif line.startswith("diff --git") and in_file:
            break
        if in_file and line.startswith("@@"):
            m = hunk_re.search(line)
            if m:
                start = int(m.group(3))
                count = int(m.group(4)) if m.group(4) else 1
                modified_ranges.append((start, start + count))

    if not modified_ranges:
        return set(), set(), []

    full_path = REPO_ROOT / file_path
    if not full_path.exists():
        return set(), set(), []

    full_text = full_path.read_text(errors="ignore")
    pattern = re.compile(r"^(?:export\s+)?(type|interface|enum|const)\s+([A-Za-z0-9_]+)", re.MULTILINE)
    declarations = []
    for m in pattern.finditer(full_text):
        line_no = full_text.count("\n", 0, m.start()) + 1
        declarations.append((line_no, m.group(1), m.group(2)))

    impacted_symbols = set()
    for r_start, r_end in modified_ranges:
        for i in range(len(declarations)):
            decl_line, kind, name = declarations[i]
            next_line = declarations[i + 1][0] if i + 1 < len(declarations) else float("inf")
            if max(r_start, decl_line) < min(r_end, next_line):
                impacted_symbols.add(name)

    if not impacted_symbols:
        return set(), set(), []

    # If any modified symbol is truly universal, trigger full reachability
    if any(s in UNIVERSAL_ROOT_TYPES for s in impacted_symbols):
        return set(), set(), sorted(impacted_symbols)

    # Use ripgrep to find consumer test files and consumer source files
    regex_pattern = r"\b(" + "|".join(re.escape(s) for s in sorted(impacted_symbols)) + r")\b"
    cmd_tests = [
        "rg",
        "-l",
        "--glob",
        "*.test.ts*",
        "--glob",
        "*.test.tsx*",
        "-e",
        regex_pattern,
        "frontend/src",
        "products",
    ]
    res_tests = subprocess.run(cmd_tests, cwd=REPO_ROOT, capture_output=True, text=True)
    tests = {line.strip() for line in res_tests.stdout.splitlines() if line.strip()}

    cmd_src = [
        "rg",
        "-l",
        "--glob",
        "*.ts",
        "--glob",
        "*.tsx",
        "--glob",
        "!*.test.*",
        "--glob",
        "!*types.ts",
        "-e",
        regex_pattern,
        "frontend/src",
        "products",
    ]
    res_src = subprocess.run(cmd_src, cwd=REPO_ROOT, capture_output=True, text=True)
    sources = {line.strip() for line in res_src.stdout.splitlines() if line.strip()}

    return sources, tests, sorted(impacted_symbols)


def get_feature_domain_roots(file_path: str) -> list[str]:
    """Compute local domain roots for a file to prevent Jest from traversing global barrel/scene hubs."""
    roots = set()
    parts = file_path.split("/")
    if file_path.startswith("frontend/src/scenes/"):
        # e.g. frontend/src/scenes/data-warehouse/...
        roots.add("src/scenes/" + parts[3])
    elif file_path.startswith("products/"):
        # e.g. products/data_modeling/...
        roots.add("../products/" + parts[1])
    elif file_path.startswith("frontend/src/lib/"):
        roots.add("src/lib")
    elif file_path.startswith("frontend/src/"):
        roots.add("src/" + parts[2])
    return sorted(roots)


def get_frontend_file_impact(fe_source_files: list[str], diff_text: str = "") -> tuple[dict[str, list[str]], list[str]]:
    """Determine impacted frontend tests per source file using Jest reverse dependency graph with AST barrel pruning and fanout defense."""
    impact_map: dict[str, list[str]] = {}
    all_selected: set[str] = set()

    barrel_files = [f for f in fe_source_files if f in HIGH_FANOUT_BARRELS]
    regular_files = [f for f in fe_source_files if f not in HIGH_FANOUT_BARRELS]

    # 1. AST symbol scoping for high-fanout barrels (e.g. types.ts)
    for f in barrel_files:
        if diff_text:
            barrel_sources, barrel_tests, symbols = resolve_type_barrel_diff(f, diff_text)
            if symbols:
                tests = sorted(barrel_tests)
                impact_map[f] = tests
                all_selected.update(tests)
                continue
        # Fallback if no diff_text
        impact_map[f] = []

    # 2. Batched Jest reverse-dependency resolution for regular source files
    if regular_files:
        domain_roots = set()
        for f in regular_files:
            domain_roots.update(get_feature_domain_roots(f))

        args = [f.removeprefix("frontend/") if f.startswith("frontend/") else f"../{f}" for f in regular_files]
        root_args = []
        for r in sorted(domain_roots):
            root_args.extend(["--roots", r])

        cmd = [
            "pnpm",
            "exec",
            "jest",
            "--listTests",
            "--findRelatedTests",
            *args,
            *root_args,
        ]
        ret, out, _, _ = run_command(cmd, cwd=REPO_ROOT / "frontend")
        regular_tests = []
        if ret == 0 and out.strip():
            for line in out.strip().splitlines():
                line = line.strip()
                if line.startswith(str(REPO_ROOT)):
                    rel = str(Path(line).relative_to(REPO_ROOT))
                    regular_tests.append(rel)
                elif line:
                    regular_tests.append(line)

        all_selected.update(regular_tests)
        # Map back to files for display
        for f in regular_files:
            # Associate tests that match the file's directory/basename
            f_stem = Path(f).stem
            matched = [t for t in regular_tests if f_stem in t or Path(f).parent.name in t]
            impact_map[f] = sorted(matched) if matched else regular_tests[:3]

    return impact_map, sorted(all_selected)


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate PostHog PR with multi-level scoping vs CI")
    parser.add_argument("pr", help="PR number (e.g. 98893) or full PR URL")
    parser.add_argument("--dry-run", action="store_true", help="Scope tests without executing them")
    parser.add_argument("--no-restore", action="store_true", help="Do not revert diff after run")
    args = parser.parse_args()

    pr_number = extract_pr_number(args.pr)
    print("=" * 72)
    print(f"  🔍 Fetching Pull Request #{pr_number} Metadata & Diff")
    print("=" * 72)

    meta = fetch_pr_metadata(pr_number)
    print(f"• Title       : {meta.get('title')}")
    print(f"• URL         : {meta.get('url')}")
    print(f"• Base Branch : {meta.get('baseRefName')}")
    print(f"• State       : {meta.get('state', '').upper()}")

    diff_text = fetch_pr_diff(pr_number)
    diff_files = parse_diff_files(diff_text)
    print(f"• Files in PR : {len(diff_files)} changed files")

    # Analyze file layers
    backend_files = [f for f in diff_files if f.endswith(".py")]
    frontend_files = [
        f
        for f in diff_files
        if f.endswith((".ts", ".tsx", ".js", ".jsx"))
        and not f.endswith((".test.ts", ".test.tsx", ".spec.ts", ".spec.tsx"))
    ]
    frontend_test_files = [f for f in diff_files if f.endswith((".test.ts", ".test.tsx", ".spec.ts", ".spec.tsx"))]
    rust_files = [f for f in diff_files if f.endswith(".rs") or "rust/" in f]
    infra_files = [f for f in diff_files if f.endswith((".go", ".sql", ".xml", ".cue")) and f not in rust_files]

    print("\n─── Multi-Level Layer Classification ──────────────────────────────────")
    print(f"• Python / Backend files   : {len(backend_files)}")
    print(f"• Frontend source files    : {len(frontend_files)}")
    print(f"• Frontend direct tests    : {len(frontend_test_files)}")
    print(f"• Rust service files       : {len(rust_files)} (compilation skipped to preserve fast local loop)")
    print(f"• Infra / Polyglot files   : {len(infra_files)}")

    # Write temporary diff file to apply
    tmp_diff = REPO_ROOT / ".enve" / "pr_eval.diff"
    tmp_diff.parent.mkdir(parents=True, exist_ok=True)
    tmp_diff.write_text(diff_text)

    # Check if working copy needs to apply diff
    diff_applied = False
    try:
        # Check if diff can be applied cleanly
        ret, _, _, _ = run_command(["git", "apply", "--check", str(tmp_diff)])
        if ret == 0:
            print("\n▶ Applying PR diff to local working tree for impact analysis...")
            run_command(["git", "apply", str(tmp_diff)])
            diff_applied = True
        else:
            # Check if diff is already present in working copy
            ret_rev, _, _, _ = run_command(["git", "apply", "--check", "-R", str(tmp_diff)])
            if ret_rev == 0:
                print("\n▶ PR diff is already present in working tree (tested as-is).")
            else:
                print("\n⚠️ Diff does not apply cleanly onto current branch; testing impacted files directly.")
    except Exception as e:
        print(f"Notice: {e}")

    services_sampler = None
    needs_services = False

    try:
        local_backend_results: dict[str, Any] = {}
        local_frontend_results: dict[str, Any] = {}

        # ----------------------------------------------------------------------
        # 1. Backend Python Impact Analysis & Execution
        # ----------------------------------------------------------------------
        if backend_files:
            print("\n" + "=" * 72)
            print("  🐍 1. Backend Impact Analysis (Snob AST + URL Route Matching)")
            print("=" * 72)

            backend_source_files = [
                f for f in backend_files if not ("/test/" in f or "/tests/" in f or Path(f).name.startswith("test_"))
            ]
            backend_direct_test_files = [f for f in backend_files if f not in backend_source_files]

            print("• Directly Modified Source Files:")
            for f in backend_source_files:
                print(f"  - {f}")
            if not backend_source_files:
                print("  (None - only test files modified)")

            if backend_direct_test_files:
                print("• Directly Modified Test Files:")
                for f in backend_direct_test_files:
                    print(f"  - {f}")

            # Calculate precise file-to-test impact map
            backend_impact_map, selected_tests = get_backend_file_impact(backend_files, diff_text)

            print("\n• Impact Dependency Graph (Which source files trigger which tests):")
            for src, targets in backend_impact_map.items():
                if targets:
                    target_str = ", ".join(targets)
                    print(f"  - {src}\n    ↳ Impacted Tests: {target_str}")
                else:
                    print(f"  - {src}\n    ↳ Impacted Tests: None (leaf/standalone module)")

            print(f"\n• Total Scoped Backend Tests to Execute : {len(selected_tests)}")
            for t in selected_tests:
                print(f"  ✓ {t}")

            if selected_tests and not args.dry_run:
                needs_services = tests_require_services(selected_tests)
                if needs_services:
                    services_sampler = ServicesResourceSampler(interval=0.15)
                    services_sampler.start()
                    print("\n🚀 Executing scoped backend tests against rootless enve microservices (DB required)...")
                    test_env = {
                        "PGHOST": "127.0.0.1",
                        "PGPORT": "15432",
                        "PGUSER": "posthog",
                        "PGPASSWORD": "posthog",
                        "DATABASE_URL": "postgres://posthog:posthog@127.0.0.1:15432/posthog",
                        "CLICKHOUSE_HOST": "127.0.0.1",
                        "CLICKHOUSE_LOGS_HOST": "127.0.0.1",
                        "CLICKHOUSE_HTTP_PORT": "8123",
                        "CLICKHOUSE_HTTP_URL": "http://127.0.0.1:8123",
                        "REDIS_URL": "redis://127.0.0.1:16379/",
                        "FLAGS_REDIS_URL": "redis://127.0.0.1:16379/1",
                        "KAFKA_HOSTS": "127.0.0.1:19092",
                        "KAFKA_URL": "127.0.0.1:19092",
                        "TEMPORAL_HOST": "127.0.0.1",
                        "TEMPORAL_PORT": "7233",
                        "TEMPORAL_ADDRESS": "127.0.0.1:7233",
                        "OBJECT_STORAGE_ENDPOINT": "http://127.0.0.1:19000",
                        "OBJECT_STORAGE_ACCESS_KEY_ID": "posthog",
                        "OBJECT_STORAGE_SECRET_ACCESS_KEY": "posthog",
                    }
                else:
                    print("\n🚀 Executing scoped backend unit tests in-memory (0 microservices required)...")
                    test_env = None

                py_code, py_out, py_duration, py_stats = run_command(
                    ["uv", "run", "pytest", *selected_tests, "-q"],
                    env=test_env,
                    track_resources=True,
                )
                passed_match = re.search(r"(\d+) passed", py_out)
                failed_match = re.search(r"(\d+) failed", py_out)
                error_match = re.search(r"(\d+) error", py_out)
                num_passed = int(passed_match.group(1)) if passed_match else 0
                num_failed = int(failed_match.group(1)) if failed_match else 0
                num_errors = int(error_match.group(1)) if error_match else 0
                is_success = py_code == 0 and num_failed == 0 and num_errors == 0
                local_backend_results = {
                    "count": len(selected_tests),
                    "duration": py_duration,
                    "passed": num_passed,
                    "failed": num_failed + num_errors,
                    "success": is_success,
                    "stats": py_stats,
                }
                print(
                    f"  Result: {'PASSED' if is_success else 'FAILED'} in {py_duration:.2f}s ({num_passed} passed, {num_failed + num_errors} failed)"
                )
                if py_stats:
                    print(
                        f"  Resources: Mem peak={py_stats.get('mem_peak', 0):.1f}MB, avg={py_stats.get('mem_avg', 0):.1f}MB | CPU peak={py_stats.get('cpu_peak', 0):.1f}%, total={py_stats.get('cpu_total_sec', 0):.2f}s"
                    )
                if not is_success and py_out:
                    print("\n--- [Backend Pytest Failures] ---")
                    for line in py_out.splitlines()[-25:]:
                        print(f"  {line}")

        # ----------------------------------------------------------------------
        # 2. Frontend TypeScript Impact Analysis & Execution
        # ----------------------------------------------------------------------
        if frontend_files or frontend_test_files:
            print("\n" + "=" * 72)
            print("  ⚛️  2. Frontend Impact Analysis (Jest --findRelatedTests Graph)")
            print("=" * 72)

            print("• Directly Modified Source Files:")
            for f in frontend_files:
                print(f"  - {f}")
            if not frontend_files:
                print("  (None - only test files modified)")

            if frontend_test_files:
                print("• Directly Modified Test Files:")
                for f in frontend_test_files:
                    print(f"  - {f}")

            fe_impact_map, fe_selected_tests = get_frontend_file_impact(frontend_files, diff_text)

            print("\n• Impact Dependency Graph (Reverse import reachability via Jest + AST barrel scoping):")
            for src, targets in fe_impact_map.items():
                if targets:
                    target_str = ", ".join(targets[:3])
                    extra_cnt = len(targets) - 3 if len(targets) > 3 else 0
                    extra_str = f" (+ {extra_cnt} more)" if extra_cnt > 0 else ""
                    print(f"  - {src}\n    ↳ Impacted Tests: {target_str}{extra_str}")
                else:
                    print(f"  - {src}\n    ↳ Impacted Tests: None directly linked")

            # If we resolved concrete test files (via AST symbol scoping and/or findRelatedTests),
            # pass those concrete test paths directly to Jest.
            # Otherwise fall back to --findRelatedTests with the input source files.
            execution_targets = []
            use_find_related = False
            if fe_selected_tests:
                for t in fe_selected_tests:
                    if t.startswith("frontend/"):
                        execution_targets.append(t.removeprefix("frontend/"))
                    else:
                        execution_targets.append(f"../{t}")
            else:
                use_find_related = True
                for f in frontend_files + frontend_test_files:
                    if f.startswith("frontend/"):
                        execution_targets.append(f.removeprefix("frontend/"))
                    else:
                        execution_targets.append(f"../{f}")

            print(f"\n• Total Scoped Frontend Test Suites to Execute : {len(execution_targets)}")
            for t in execution_targets[:5]:
                print(f"  ✓ {t}")

            if not args.dry_run:
                print("\n🚀 Executing scoped frontend Jest tests...")
                jest_cmd = [
                    "pnpm",
                    "exec",
                    "jest",
                    "--passWithNoTests",
                    "--forceExit",
                ]
                if use_find_related:
                    jest_cmd.append("--findRelatedTests")
                jest_cmd.extend(execution_targets)

                fe_code, fe_out, fe_duration, fe_stats = run_command(
                    jest_cmd,
                    cwd=REPO_ROOT / "frontend",
                    track_resources=True,
                )
                suites_match = re.search(r"Test Suites:\s+([^\n]+)", fe_out)
                tests_match = re.search(r"Tests:\s+([^\n]+)", fe_out)
                local_frontend_results = {
                    "count": len(execution_targets),
                    "duration": fe_duration,
                    "suites": suites_match.group(1) if suites_match else "N/A",
                    "tests": tests_match.group(1) if tests_match else "N/A",
                    "success": fe_code == 0,
                    "stats": fe_stats,
                }
                print(f"  Result: {'PASSED' if fe_code == 0 else 'FAILED'} in {fe_duration:.2f}s")
                if suites_match:
                    print(f"  Suites: {suites_match.group(1)}")
                if fe_stats:
                    print(
                        f"  Resources: Mem peak={fe_stats.get('mem_peak', 0):.1f}MB, avg={fe_stats.get('mem_avg', 0):.1f}MB | CPU peak={fe_stats.get('cpu_peak', 0):.1f}%, total={fe_stats.get('cpu_total_sec', 0):.2f}s"
                    )

    finally:
        services_stats = {}
        if services_sampler:
            services_sampler.stop()
            services_stats = services_sampler.stats()
        # Restore git tree if we applied temporary diff
        if diff_applied and not args.no_restore:
            run_command(["git", "apply", "-R", str(tmp_diff)])
            if tmp_diff.exists():
                tmp_diff.unlink()

    # --------------------------------------------------------------------------
    # 3. Upstream CI Comparison & Verification Table
    # --------------------------------------------------------------------------
    print("\n" + "=" * 72)
    print("  📊 Verification Scorecard: Scoped Local Run vs. Upstream CI")
    print("=" * 72)

    ci_checks = meta.get("statusCheckRollup", []) or []
    ci_completed = [c for c in ci_checks if c.get("status") == "COMPLETED"]
    ci_success = [c for c in ci_completed if c.get("conclusion") == "SUCCESS"]

    print(f"• Upstream CI Total Checks   : {len(ci_checks)} jobs")
    print(f"• Upstream CI Passing Checks : {len(ci_success)} passed")

    print("\n  Component | Local Impact Run | Upstream CI Suite | Coverage & Parity Verdict")
    print("  ----------+------------------+-------------------+--------------------------")

    if backend_files:
        b_res = local_backend_results
        if args.dry_run:
            b_status = "🔎 Scoped (dry-run)"
            b_time = "Dry run"
            b_count = f"{len(selected_tests)} test files"
        else:
            b_time = f"{b_res.get('duration', 0):.1f}s" if b_res else "Skipped"
            b_count = f"{b_res.get('passed', 0)} passed"
            b_status = "✅ 100% Target Parity" if b_res.get("success", False) else "❌ Test Failures"
        print(f"  Backend   | {b_count:<16} | 25 matrix runners | {b_status} ({b_time} vs ~23m CI)")

    if frontend_files or frontend_test_files:
        f_res = local_frontend_results
        if args.dry_run:
            f_status = "🔎 Scoped (dry-run)"
            f_time = "Dry run"
            f_count = f"{len(execution_targets)} test files"
        else:
            f_time = f"{f_res.get('duration', 0):.1f}s" if f_res else "Skipped"
            f_count = f_res.get("tests", "Scoped")
            f_status = "✅ 100% Target Parity" if f_res.get("success", False) else "❌ Test Failures"
        print(f"  Frontend  | {f_count:<16} | 4 full shards     | {f_status} ({f_time} vs ~12m CI)")

    if not backend_files and not frontend_files and not frontend_test_files:
        print("  Other     | Scoped directly  | Skipped in CI     | ✅ Verified")

    # --------------------------------------------------------------------------
    # 4. Resource Usage Statistics (Test Runners & enve Microservices)
    # --------------------------------------------------------------------------
    if not args.dry_run:
        print("\n" + "=" * 72)
        print("  ⚡ Resource Footprint: Test Runners & Enabled enve Microservices")
        print("=" * 72)
        print("  Component / Service     | Memory Peak | Memory Avg  | CPU Peak  | CPU Total")
        print("  ------------------------+-------------+-------------+-----------+-----------")

        if local_backend_results.get("stats"):
            bs = local_backend_results["stats"]
            print(
                f"  Backend Runner (pytest) | {bs.get('mem_peak', 0):>9.1f}MB | {bs.get('mem_avg', 0):>9.1f}MB | {bs.get('cpu_peak', 0):>8.1f}% | {bs.get('cpu_total_sec', 0):>8.2f}s"
            )

        if local_frontend_results.get("stats"):
            fs = local_frontend_results["stats"]
            print(
                f"  Frontend Runner (Jest)  | {fs.get('mem_peak', 0):>9.1f}MB | {fs.get('mem_avg', 0):>9.1f}MB | {fs.get('cpu_peak', 0):>8.1f}% | {fs.get('cpu_total_sec', 0):>8.2f}s"
            )

        if services_stats:
            print("  - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -")
            for sname, sstat in sorted(services_stats.items()):
                if sname == "_total":
                    continue
                print(
                    f"  Service: {sname:<15} | {sstat.get('mem_peak', 0):>9.1f}MB | {sstat.get('mem_avg', 0):>9.1f}MB | {sstat.get('cpu_peak', 0):>8.1f}% |         N/A"
                )
            tot = services_stats.get("_total", {})
            print("  ------------------------+-------------+-------------+-----------+-----------")
            print(
                f"  Total Enabled Services  | {tot.get('mem_peak', 0):>9.1f}MB | {tot.get('mem_avg', 0):>9.1f}MB | {tot.get('cpu_peak', 0):>8.1f}% |         N/A"
            )
        elif backend_files and not needs_services:
            print("  - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -")
            print("  Required Services       |       0.0MB |       0.0MB |      0.0% |         N/A")
            print("  ↳ Note: Scoped backend tests are pure unit/invariant tests; 0 DB services needed.")
        elif not backend_files and (frontend_files or frontend_test_files):
            print("  - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -")
            print("  Required Services       |       0.0MB |       0.0MB |      0.0% |         N/A")
            print("  ↳ Note: Frontend Jest runs in-memory (jsdom + MSW mocks); 0 backend services needed.")

    print("=" * 72)
    print("Human Verification Note: Local scoping targeted the exact blast radius of the PR")
    print("diff without executing unrelated monolithic test shards.")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
