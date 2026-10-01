#!/usr/bin/env python3
# ruff: noqa: T201
"""
tools/showcase/prepare-showcase-env.py
======================================
Prepares the repository workspace for a showcase benchmark run.
Supports:
  1. Resolving PR metadata from GitHub CLI (`gh pr view`) or explicit commit SHAs.
  2. Scraping upstream GitHub Actions check-run telemetry (actual run duration, CPU time, shard count).
  3. Non-destructively overlaying the PR code onto the workspace while preserving .enact/ and enve configurations.
  4. Computing changed files and outputting GitHub Actions step variables.
"""

import os
import json
import argparse
import subprocess
from datetime import datetime
from pathlib import Path


def run_cmd(cmd, cwd=None, check=True, capture=True):
    """Executes a shell command and returns stdout."""
    res = subprocess.run(
        cmd,
        cwd=cwd,
        check=check,
        shell=isinstance(cmd, str),
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    return res.stdout.strip() if capture else ""


def set_gha_output(key: str, value: str):
    """Sets a GitHub Actions step output."""
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as f:
            if "\n" in value:
                delimiter = "EOF_" + os.urandom(8).hex()
                f.write(f"{key}<<{delimiter}\n{value}\n{delimiter}\n")
            else:
                f.write(f"{key}={value}\n")
    print(f"   [GHA Output] {key} = {value[:80] if len(value) > 80 else value}")


def scrape_upstream_checks(repo: str, commit_sha: str) -> dict:
    """Scrapes upstream check runs for a commit and computes total CPU & max wall time."""
    print(f"🔍 Scraping upstream CI check runs for {repo}@{commit_sha[:10]}...")
    try:
        out = run_cmd(["gh", "api", f"repos/{repo}/commits/{commit_sha}/check-runs?per_page=100"])
        data = json.loads(out)
        check_runs = data.get("check_runs", [])
    except Exception as e:
        print(f"⚠️ Warning: could not scrape upstream checks via gh api: {e}")
        return {}

    total_cpu_seconds = 0.0
    max_wall_seconds = 0.0
    runs_summary = []

    for cr in check_runs:
        started = cr.get("started_at")
        completed = cr.get("completed_at")
        conclusion = cr.get("conclusion") or "pending"
        name = cr.get("name", "unnamed")
        if started and completed:
            try:
                t0 = datetime.fromisoformat(started.replace("Z", "+00:00"))
                t1 = datetime.fromisoformat(completed.replace("Z", "+00:00"))
                dur = (t1 - t0).total_seconds()
                if dur > 3:  # ignore sub-second noise
                    total_cpu_seconds += dur
                    max_wall_seconds = max(max_wall_seconds, dur)
                    runs_summary.append(
                        {
                            "name": name,
                            "duration_s": dur,
                            "conclusion": conclusion,
                        }
                    )
            except Exception:
                continue

    runs_summary.sort(key=lambda x: x["duration_s"], reverse=True)
    return {
        "repo": repo,
        "commit": commit_sha,
        "total_check_runs": len(check_runs),
        "timed_runs_count": len(runs_summary),
        "total_cpu_seconds": total_cpu_seconds,
        "total_cpu_minutes": round(total_cpu_seconds / 60.0, 1),
        "max_wall_seconds": max_wall_seconds,
        "max_wall_minutes": round(max_wall_seconds / 60.0, 1),
        "top_runs": runs_summary[:10],
    }


def main():
    parser = argparse.ArgumentParser(description="Prepare showcase benchmark environment")
    parser.add_argument("--pr", help="Upstream PR number or URL (e.g. 102450 or https://github.com/...)")
    parser.add_argument("--head", help="PR head commit SHA or branch name")
    parser.add_argument("--base", default="master", help="Target base commit SHA or branch name (default: master)")
    parser.add_argument("--repo", help="Upstream GitHub repository (e.g. PostHog/posthog, n8n-io/n8n, odoo/odoo)")
    parser.add_argument("--workspace", default=".", help="Target repository directory (default: .)")
    parser.add_argument("--overlay", help="Directory containing .enact/ and enve configs to preserve/project")
    args = parser.parse_args()

    repo_dir = Path(args.workspace).resolve()
    print(f"🚀 Preparing showcase environment in {repo_dir}...")

    # Determine default upstream repo if not passed
    upstream_repo = args.repo
    if not upstream_repo:
        try:
            remote_url = run_cmd(
                "git config --get remote.upstream.url || git config --get remote.origin.url", cwd=repo_dir
            )
            if "github.com" in remote_url:
                # git@github.com:owner/repo.git or https://github.com/owner/repo.git
                parts = remote_url.split("github.com")[-1].lstrip("/:").rstrip(".git")
                upstream_repo = parts
        except Exception:
            pass

    pr_title = ""
    pr_url = ""
    pr_author = ""
    head_sha = args.head or ""
    base_sha = args.base or "master"

    # 1. Resolve PR details via gh CLI if PR is provided
    if args.pr:
        pr_id = args.pr.strip()
        if pr_id.startswith("http"):
            # Extract number from URL
            pr_id = pr_id.rstrip("/").split("/")[-1]

        gh_cmd = [
            "gh",
            "pr",
            "view",
            pr_id,
            "--json",
            "number,title,url,author,baseRefOid,headRefOid,headRefName,baseRefName",
        ]
        if upstream_repo:
            gh_cmd.extend(["--repo", upstream_repo])

        print(f"📋 Resolving PR #{pr_id} from {upstream_repo or 'origin'}...")
        try:
            out = run_cmd(gh_cmd, cwd=repo_dir)
            pr_data = json.loads(out)
            head_sha = pr_data.get("headRefOid") or head_sha
            base_sha = pr_data.get("baseRefOid") or base_sha
            pr_title = pr_data.get("title", "")
            pr_url = pr_data.get("url", "")
            pr_author = (pr_data.get("author") or {}).get("login", "")
            print(f"   ✓ PR #{pr_id}: '{pr_title}' by @{pr_author}")
            print(f"   ✓ Base: {base_sha[:10]} | Head: {head_sha[:10]}")
        except Exception as e:
            print(f"⚠️ Warning: Could not resolve PR #{pr_id} via gh: {e}")

    if not head_sha:
        head_sha = run_cmd("git rev-parse HEAD", cwd=repo_dir)
    if not base_sha:
        base_sha = "master"

    # 2. Scrape Upstream CI Baseline
    upstream_baseline = {}
    if upstream_repo and head_sha:
        upstream_baseline = scrape_upstream_checks(upstream_repo, head_sha)
        enact_dir = repo_dir / ".enact"
        enact_dir.mkdir(parents=True, exist_ok=True)
        baseline_file = enact_dir / "upstream-baseline.json"
        with open(baseline_file, "w") as f:
            json.dump(upstream_baseline, f, indent=2)
        print(f"   💾 Saved upstream baseline metrics to {baseline_file}")

    # 3. Ensure base and head commits are available in local git tree
    print("🌿 Ensuring commits are available locally...")
    if args.pr:
        pr_id_clean = args.pr.strip().rstrip("/").split("/")[-1]
        run_cmd(
            f"git fetch --no-tags --depth=1 origin pull/{pr_id_clean}/head 2>/dev/null || git fetch --no-tags --depth=1 https://github.com/{upstream_repo}.git pull/{pr_id_clean}/head 2>/dev/null || true",
            cwd=repo_dir,
            check=False,
        )
        base_branch = pr_data.get("baseRefName") if "pr_data" in locals() else ""
        if base_branch:
            run_cmd(
                f"git fetch --no-tags --depth=1 origin {base_branch} 2>/dev/null || git fetch --no-tags --depth=1 https://github.com/{upstream_repo}.git {base_branch} 2>/dev/null || true",
                cwd=repo_dir,
                check=False,
            )

    def ensure_commit(sha: str):
        if not sha:
            return
        res = subprocess.run(
            f"git rev-parse --verify {sha}^{{commit}}",
            cwd=repo_dir,
            shell=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if res.returncode == 0:
            return  # Already available locally
        run_cmd(f"git fetch --no-tags --depth=1 origin {sha} 2>/dev/null || true", cwd=repo_dir, check=False)
        res = subprocess.run(
            f"git rev-parse --verify {sha}^{{commit}}",
            cwd=repo_dir,
            shell=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if res.returncode != 0 and upstream_repo:
            run_cmd(
                f"git fetch --no-tags --depth=1 https://github.com/{upstream_repo}.git {sha} 2>/dev/null || true",
                cwd=repo_dir,
                check=False,
            )

    ensure_commit(base_sha)
    ensure_commit(head_sha)

    # 4. Compute changed files between base and head
    changed_files = []
    if args.pr:
        pr_id_clean = args.pr.strip().rstrip("/").split("/")[-1]
        try:
            gh_diff_cmd = ["gh", "pr", "diff", pr_id_clean, "--name-only"]
            if upstream_repo:
                gh_diff_cmd.extend(["--repo", upstream_repo])
            out = run_cmd(gh_diff_cmd, cwd=repo_dir)
            changed_files = [line.strip() for line in out.splitlines() if line.strip()]
            if changed_files:
                print(f"   ✓ Fetched {len(changed_files)} changed files directly via GitHub CLI for PR #{pr_id_clean}")
        except Exception as e:
            print(f"⚠️ Warning: Could not get PR diff via gh: {e}")

    if not changed_files and base_sha and head_sha:
        try:
            changed_output = run_cmd(f"git diff --name-only {base_sha} {head_sha}", cwd=repo_dir)
            changed_files = [line.strip() for line in changed_output.splitlines() if line.strip()]
        except Exception as e:
            print(f"⚠️ Warning: Could not get git diff between {base_sha} and {head_sha}: {e}")

    if not changed_files and base_sha and head_sha:
        try:
            changed_output = run_cmd(f"git diff --name-only {base_sha}...{head_sha}", cwd=repo_dir)
            changed_files = [line.strip() for line in changed_output.splitlines() if line.strip()]
        except Exception:
            pass

    if not changed_files:
        try:
            changed_output = run_cmd("git diff --name-only HEAD~1", cwd=repo_dir)
            changed_files = [line.strip() for line in changed_output.splitlines() if line.strip()]
        except Exception:
            pass

    print(f"📝 Changed files detected: {len(changed_files)}")
    for f in changed_files[:8]:
        print(f"   • {f}")
    if len(changed_files) > 8:
        print(f"   ... and {len(changed_files) - 8} more")

    # Save changed files list
    enact_dir = repo_dir / ".enact"
    enact_dir.mkdir(parents=True, exist_ok=True)
    with open(enact_dir / "changed-files.txt", "w") as f:
        f.write("\n".join(changed_files))

    # 5. Non-destructively overlay PR code if checkout requested
    # Checkout only the changed files from head_sha (excluding protected enact/enve/workflow paths)
    current_head = run_cmd("git rev-parse HEAD", cwd=repo_dir)
    if current_head != head_sha and head_sha and changed_files:
        print(f"🔄 Projecting PR code changes from {head_sha[:10]} ({len(changed_files)} files)...")
        protected_prefixes = (".enact", "enve.cue", "enve.lock", "showcase", "helpers", ".github/workflows")
        pr_files_to_checkout = [f for f in changed_files if not any(f.startswith(p) for p in protected_prefixes)]
        if pr_files_to_checkout:
            for f in pr_files_to_checkout:
                dest = repo_dir / f
                res = subprocess.run(
                    f"git cat-file -e {head_sha}:'{f}'",
                    shell=True,
                    cwd=repo_dir,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                if res.returncode == 0:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    with open(dest, "wb") as out_f:
                        subprocess.run(
                            ["git", "show", f"{head_sha}:{f}"],
                            stdout=out_f,
                            cwd=repo_dir,
                            check=True,
                        )
                else:
                    dest.unlink(missing_ok=True)
        print("   ✓ PR code changes projected successfully.")

        # Package changed files so subsequent workflow stages (preflight, test) can restore them
        try:
            existing_pr_files = [f for f in pr_files_to_checkout if (repo_dir / f).exists()]
            if existing_pr_files:
                archive_path = enact_dir / "showcase-changes.tar.gz"
                file_list_path = enact_dir / "pr-files-list.tmp"
                with open(file_list_path, "w") as fl:
                    fl.write("\n".join(existing_pr_files) + "\n")
                run_cmd(f"tar -czf {archive_path} -T {file_list_path}", cwd=repo_dir)
                file_list_path.unlink(missing_ok=True)
                print(f"   📦 Packaged {len(existing_pr_files)} PR files into {archive_path}")
        except Exception as e:
            print(f"⚠️ Warning: Could not package PR files: {e}")

    # 6. Set GitHub Actions outputs
    set_gha_output("base_sha", base_sha)
    set_gha_output("head_sha", head_sha)
    set_gha_output("pr_title", pr_title or f"Showcase run: {base_sha[:8]}..{head_sha[:8]}")
    set_gha_output("pr_url", pr_url)
    set_gha_output("pr_author", pr_author)
    set_gha_output("changed_files_count", str(len(changed_files)))
    set_gha_output("has_upstream_baseline", "true" if upstream_baseline.get("total_cpu_seconds", 0) > 0 else "false")
    set_gha_output("upstream_cpu_minutes", str(upstream_baseline.get("total_cpu_minutes", "N/A")))
    set_gha_output("upstream_wall_minutes", str(upstream_baseline.get("max_wall_minutes", "N/A")))

    print("\n✅ Showcase environment preparation complete.")


if __name__ == "__main__":
    main()
