#!/usr/bin/env python3
"""Compute Postgres template keys, migration manifests, and base dumps via `enact helper pg-template`."""

import os
import shutil
import sys

SCHEMA_ARGS = [
    "--schema-file",
    "products/db_routing.yaml",
    "--schema-file",
    "posthog/product_db_config.py",
    "--schema-file",
    "posthog/product_db_router.py",
    "--schema-file",
    "showcase/scripts/test_databases.sh",
    "--schema-file",
    "showcase/scripts/template_inputs.py",
    "--migrations-prefix",
    "rust/persons_migrations/",
]


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in ("key", "migrations", "base"):
        sys.exit(f"unknown command {sys.argv[1:]!r}")
    enact = os.environ.get("ENACT_EXE") or os.environ.get("ENACT_BIN") or shutil.which("enact") or "enact"
    os.execv(enact, [enact, "helper", "pg-template", sys.argv[1], *SCHEMA_ARGS, *sys.argv[2:]])


if __name__ == "__main__":
    sys.exit(main())
