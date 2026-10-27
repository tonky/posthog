#!/usr/bin/env python3
"""The key of the migrated test-database templates: what the migrated schema is made of.

As upstream's CI keys its schema dump (ci-backend.yml's `posthog-schema-mig-*`): the Django
migration files (not ClickHouse's or the async ones: the templates are Postgres), uv.lock
(third-party apps' migrations), the product database routing, and the persons DB's sqlx
migrations; plus how the templates are built (these helpers, the profile's environment, the
Postgres service as enve.cue declares it, enve.lock), the Postgres server and the runtime.
Application code isn't an input: a migration reads the models it needs from the migration
state. Keying on every file instead rebuilt the templates (~3060 migrations, 10-45 min) on
any edit anywhere; keying on all of enve.cue, on an edit to another service.

A key with no dump of its own starts from the newest dump whose migrations the checkout
still has, unchanged (`base`), and `migrate` applies the rest, as upstream restores the
newest `posthog-schema-mig-*` dump and lets pytest's keepdb migrate top it up. Migrations
only apply forward, so a dump recording one the checkout lacks or changed can't be used.

  template_inputs.py key <server_version_num> <bootstrap test>   the key
  template_inputs.py migrations                                  the migration manifest
  template_inputs.py base <snapshot root>                        the dump to top up
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Django migrations at any depth, but not the ClickHouse or async-migration frameworks'.
MIGRATION = re.compile(r"(^|/)migrations/[^/]+\.py$")
NOT_POSTGRES = re.compile(r"(^|/)(clickhouse|async_migrations)/migrations/")
SCHEMA_FILES = {
    "uv.lock",
    # Routing decides which app labels live in which database.
    "products/db_routing.yaml",
    "posthog/product_db_config.py",
    "posthog/product_db_router.py",
    # How the templates are built and what they are built with (enve.cue: its Postgres
    # service and environment, `key`).
    ".env",
    "enve.lock",
    "showcase/scripts/test_databases.sh",
    "showcase/scripts/template_inputs.py",
}
PERSONS_MIGRATIONS = "rust/persons_migrations/"


def schema_input(name: str) -> bool:
    if name in SCHEMA_FILES or name.startswith(PERSONS_MIGRATIONS):
        return True
    return bool(MIGRATION.search(name)) and not NOT_POSTGRES.search(name)


class TemplateInputs:
    def __init__(self, root: Path) -> None:
        self.root = root

    def files(self) -> list[str]:
        output = subprocess.check_output(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=self.root,
        )
        names = set(os.fsdecode(output).split("\0")) - {""}
        names.add(".env")
        return sorted(name for name in names if schema_input(name))

    def migrations(self) -> dict[str, str]:
        """The migrations the templates apply (Django's and the persons DB's), by digest."""
        manifest = {}
        for name in self.files():
            if name in SCHEMA_FILES:
                continue
            path = self.root / name
            if path.is_file():
                with path.open("rb") as stream:
                    manifest[name] = hashlib.file_digest(stream, "sha256").hexdigest()
        return manifest

    def fingerprint(
        self,
        runtime: str,
        environment: dict[str, str | None],
        bootstrap: str,
        postgres: dict | None = None,
    ) -> str:
        digest = hashlib.sha256()
        digest.update(
            json.dumps(
                ["enact-template-v5", runtime, environment, bootstrap, postgres or {}],
                sort_keys=True,
            ).encode()
        )
        for name in self.files():
            path = self.root / name
            digest.update(os.fsencode(name) + b"\0")
            if not path.is_file():
                digest.update(b"missing\0")
                continue
            with path.open("rb") as stream:
                digest.update(hashlib.file_digest(stream, "sha256").digest())
        return digest.hexdigest()


MIGRATIONS_FILE = "migrations.json"


def newest_base(snapshot_root: Path, migrations: dict[str, str]) -> Path | None:
    """The newest saved dump (a `<key>/<generation>` directory) that `migrate` can bring to
    `migrations`: every migration it applied is in the checkout, unchanged."""
    candidates = []
    for pointer in snapshot_root.glob("*/current-v3"):
        try:
            generation = pointer.read_text().strip()
            directory = pointer.parent / generation
            applied = json.loads((directory / MIGRATIONS_FILE).read_text())
            saved = pointer.stat().st_mtime
        except (OSError, ValueError):
            continue  # being replaced, or saved before dumps listed their migrations
        if re.fullmatch(r"v3\.[a-zA-Z0-9]{8}", generation) and isinstance(applied, dict) and all(
            migrations.get(name) == digest for name, digest in applied.items()
        ):
            candidates.append((saved, str(directory), directory))
    return max(candidates)[2] if candidates else None


def declared(path: str) -> dict:
    """enve.cue's value at `path` (`profiles.dev.environment`), as enve evaluates it."""
    return json.loads(
        subprocess.check_output(
            ["enve", "cue", "export", "-q", "-e", path, "enve.cue"], text=True
        )
    )


def postgres_service(service: dict) -> dict:
    """The Postgres service as it builds the templates: its command, init and settings, not
    where the checkout lies (`originDir`, which differs per checkout sharing the dumps)."""
    return {name: value for name, value in service.items() if name != "originDir"}


def key(server_version: str, bootstrap: str) -> str:
    root = Path.cwd()
    environment = schema_environment(declared("profiles.dev.environment"), os.environ)
    for key in ("CI", "DJANGO_SETTINGS_MODULE", "ENACT_TEMPLATE_BOOTSTRAP_TEST"):
        environment[key] = os.environ.get(key)
    postgres = postgres_service(declared("profiles.dev.services.postgres"))
    return TemplateInputs(root).fingerprint(
        runtime(server_version), environment, bootstrap, postgres
    )


# What enve fills in per run and instance: the ports it allocates its services
# (`${ENVE_SERVICE_POSTGRES_PORT}`) and its own paths.
ENVE_ALLOCATED = re.compile(r"\$\{ENVE_[A-Z0-9_]+\}")


def schema_environment(
    declared: dict[str, str], environ: "os._Environ[str] | dict[str, str]"
) -> dict[str, str | None]:
    """The environment the templates are built in, as the key sees it: a value enve
    fills in per run (a service's port, so its URLs) is keyed as declared, with its
    placeholders; hashed as expanded, every run missed the cache (each runs its services
    on ports of its own) and migrated forward. Any other value as the build sees it."""
    return {
        key: value if isinstance(value, str) and ENVE_ALLOCATED.search(value) else environ.get(key)
        for key, value in declared.items()
    }


def main() -> None:
    command, *args = sys.argv[1:]
    if command == "key":
        print(key(*args))
    elif command == "migrations":
        print(json.dumps(TemplateInputs(Path.cwd()).migrations(), indent=1, sort_keys=True))
    elif command == "base":
        base = newest_base(Path(args[0]), TemplateInputs(Path.cwd()).migrations())
        if base is None:
            sys.exit(1)
        print(base)
    else:
        sys.exit(f"unknown command {command!r}")


def runtime(server_version: str) -> str:
    """What builds the schema: Python (Django's migrations), the Postgres server and sqlx
    (the persons migrations). Not enve's own version: enve.lock pins what it provides, and
    keyed on the enve build the templates were rebuilt by every enve release (a 40-minute
    bootstrap failed on an enve rebuilt while it ran)."""
    return json.dumps(
        [
            sys.version,
            str(Path(sys.executable).resolve()),
            server_version,
            subprocess.check_output(["sqlx", "--version"], text=True).strip(),
        ]
    )


if __name__ == "__main__":
    main()
