"""The environment the helpers' tests run a helper in: the caller's, less what reaches the job
or the services that run the tests.

The tests run as helper_tests' job, inside `enact run` and `enve run`: the job's ENACT_* context
(its selected targets, shard, service slot, footprint dir) and its environment's service
variables (ENVE_SERVICE_*, the profile's URLs and ports) are in os.environ. A helper reading one
the test doesn't set found the caller's instead: run_nodejs_tests.sh took the job's
$ENACT_TARGETS_FILE for jest's, and the default instance's DynamoDB port for a shard instance's, which
the enve stub never gave. Here such a read is unset and fails, on every
machine.
"""

import json
import os
import re
import subprocess
from collections.abc import Sequence
from pathlib import Path


def declared_services(root: Path) -> list[tuple[str, str, int]]:
    """Each service the checkout's enve.cue declares, its port and named ports: (service, slot
    or "-", port), from `enve services --json`."""
    out = subprocess.run(["enve", "services", "--json"], cwd=root, capture_output=True, text=True, check=True)
    rows = []
    for name, service in json.loads(out.stdout)["data"]["services"].items():
        declaration = service["declaration"]
        if declaration.get("port"):
            rows.append((name, "-", declaration["port"]))
        rows += [(name, slot, port) for slot, port in sorted((declaration.get("ports") or {}).items())]
    return rows


def helper_env(services: Sequence[tuple[str, str, int]] = ()) -> dict[str, str]:
    """os.environ less every ENACT_* variable and, given the declared services, every variable
    that reaches one of them: ENVE_SERVICE_*, and any whose value is one of their ports or a
    loopback endpoint on one."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("ENACT_")}
    if not services:
        return env
    ports = "|".join(sorted({str(port) for _, _, port in services}))
    endpoint = re.compile(rf"^({ports})$|(127\.0\.0\.1|localhost|\[::1\]):({ports})(?![0-9])")
    return {k: v for k, v in env.items() if not k.startswith("ENVE_SERVICE_") and not endpoint.search(v)}
