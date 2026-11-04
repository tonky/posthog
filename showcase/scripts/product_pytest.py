#!/usr/bin/env python3
"""A shard's pytest targets as upstream runs them: one pytest process per product, and per
segment of core.

ci-backend.yml's product jobs run `turbo run backend:test`: each product's own script
(products/<name>/package.json), from the product's directory, one product after another.
Core's targets (posthog/, ee/, ...) run from the repository root in the processes upstream
gives them: the Django job's Core segment ignores posthog/temporal (its Temporal segment),
posthog/dags (ci-dagster.yml) and posthog/test/repo_invariants (their own job), so each of
those is a run of its own. Batched into Core's process, the temporal tests' structlog setup
left command_exec_audit's capture_logs() empty. The Dagster tests (`dagster:test`) are one run
from the root, posthog/dags and every product's dags/ together, with ci-dagster.yml's reruns.
Core's, Temporal's and the products' runs retry a failed test once, as ci-backend.yml's legs.

Prints one line per run, in target order of first appearance: the run's group, a tab, its
directory, a tab, and its pytest arguments shell-quoted (its script's flags, then its
targets relative to that directory). Core's runs are from `.` with `-v`.

    product_pytest.py <target>...
"""

import json
import shlex
import sys
from pathlib import Path

# pytest options whose value is the next word; any other word not starting with `-`
# in a script is one of its test paths, which the shard's targets replace.
TAKES_VALUE = {"-c", "--rootdir", "-m", "-k", "-p", "-o", "--override-ini"}
TAKES_VALUE |= {"--reruns", "--force-reruns", "--reruns-delay"}
DEFAULT_FLAGS = ["-c", "../../pytest.ini", "--rootdir", "../..", "-v", "--tb=short"]


# Flags the overlay adds to a product's script:
# business_knowledge's script clears addopts (`--override-ini='addopts='`), so the root
# pytest.ini's `-p no:tach` is gone and tach's plugin loads. Without --tach it only builds the
# import graph to print a skip hint, running git over the whole repository (diff, ls-files):
# its tests' footprints were whole-tree, incomplete. Its tests run as with every other
# product's, tach off.
OVERLAY_FLAGS = {"business_knowledge": ["-p", "no:tach"]}


def script_flags(product_dir: Path) -> list[str]:
    """The flags of the product's `backend:test` script (its paths dropped)."""
    try:
        script = json.loads((product_dir / "package.json").read_text())["scripts"]["backend:test"]
    except (OSError, ValueError, KeyError, TypeError):
        return list(DEFAULT_FLAGS)
    words = shlex.split(script.split("||", 1)[0])
    if not words or words[0] != "pytest":
        return list(DEFAULT_FLAGS)  # `echo 'No backend tests'`: none to run as its own
    flags: list[str] = []
    value_next = False
    for word in words[1:]:
        if value_next:
            flags.append(word)
            value_next = False
        elif word.startswith("-"):
            flags.append(word)
            value_next = word in TAKES_VALUE
    return flags


# Core's segments run apart from it, as upstream's jobs: (path prefix, group).
CORE_SEGMENTS = [
    ("posthog/temporal/", "temporal"),
    ("posthog/dags/", "dags"),
    ("posthog/test/repo_invariants/", "repo_invariants"),
]

# ci-backend.yml's Django legs (Core, Temporal) and product legs (turbo-tests) retry a failed test
# once: `--force-reruns 1 --reruns-delay 1`, as their checkout's posthog/conftest.py carries the
# retry diagnostics ("posthog.runner_name"). A test passing only on its retry passes there; e.g.
# access_control's query counts, whose first try also loads ContentType's cache.
RETRY_FLAGS = ["--force-reruns", "1", "--reruns-delay", "1"]

# Flags a root run's group adds before its targets: the Django legs' retry, ci-dagster.yml's
# `--reruns 2 --reruns-delay 1`; the repo invariants' job runs its guards once.
GROUP_FLAGS = {"core": RETRY_FLAGS, "temporal": RETRY_FLAGS, "dags": ["--reruns", "2", "--reruns-delay", "1"]}


def group_of(target: str) -> tuple[str, str]:
    """The target's (group, directory)."""
    parts = target.split("/")
    if parts[0] == "products" and len(parts) > 3 and parts[2] == "dags":
        return "dags", "."  # ci-dagster.yml: `pytest posthog/dags products/*/dags` from the root
    if parts[0] == "products" and len(parts) > 2:
        return parts[1], "/".join(parts[:2])
    for prefix, group in CORE_SEGMENTS:
        if target.startswith(prefix):
            return group, "."
    return "core", "."


def runs(targets: list[str]) -> list[tuple[str, str, list[str]]]:
    groups: dict[tuple[str, str], list[str]] = {}
    for target in targets:
        groups.setdefault(group_of(target), []).append(target)
    out = []
    for (group, directory), members in groups.items():
        if directory == ".":
            out.append((group, directory, ["-v", *GROUP_FLAGS.get(group, []), *members]))
        else:
            relative = [t[len(directory) + 1 :] for t in members]
            flags = [*script_flags(Path(directory)), *OVERLAY_FLAGS.get(group, []), *RETRY_FLAGS]
            out.append((group, directory, [*flags, *relative]))
    return out


def main() -> None:
    for group, directory, args in runs(sys.argv[1:]):
        print(f"{group}\t{directory}\t{shlex.join(args)}")


if __name__ == "__main__":
    main()
