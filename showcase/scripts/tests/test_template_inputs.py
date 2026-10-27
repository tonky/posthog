import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "template_inputs", Path(__file__).resolve().parents[1] / "template_inputs.py"
)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TemplateInputsTest(unittest.TestCase):
    """The templates are rebuilt when the migrated schema can differ, and only then."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.write("posthog/migrations/0001_initial.py", "operations = []\n")
        self.write("posthog/models/team.py", "class Team: pass\n")
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        self.inputs = module.TemplateInputs(self.root)

    def write(self, name: str, text: str) -> Path:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def key(self, runtime="pg17-python", environment=None, bootstrap="bootstrap", postgres=None) -> str:
        return self.inputs.fingerprint(runtime, environment or {"CI": "1"}, bootstrap, postgres)

    def test_schema_inputs_invalidate(self) -> None:
        first = self.key()
        for name in (
            "posthog/migrations/0001_initial.py",
            "posthog/migrations/0002_new.py",
            "products/surveys/backend/migrations/0001_initial.py",
            "uv.lock",
            "products/db_routing.yaml",
            "posthog/product_db_router.py",
            "rust/persons_migrations/20240101_init.sql",
            ".env",
            "enve.lock",
            "showcase/scripts/test_databases.sh",
        ):
            with self.subTest(name=name):
                path = self.root / name
                before = path.read_text() if path.exists() else None
                self.write(name, "changed\n")
                self.assertNotEqual(first, self.key())
                if before is None:
                    path.unlink()
                else:
                    path.write_text(before)
                self.assertEqual(first, self.key())
        (self.root / "posthog/migrations/0001_initial.py").unlink()
        self.assertNotEqual(first, self.key())

    def test_how_and_where_they_are_built_invalidates(self) -> None:
        first = self.key()
        self.assertNotEqual(first, self.key(runtime="pg18-python"))
        self.assertNotEqual(first, self.key(environment={"CI": "0"}))
        self.assertNotEqual(first, self.key(bootstrap="other-bootstrap"))

    def test_the_postgres_service_invalidates_wherever_the_checkout_lies(self) -> None:
        service = {
            "command": "postgres -D \"$DATA_DIR\" -c max_connections=1000",
            "lifecycle": {"init": ["initdb -D \"$DATA_DIR\" --locale=C.UTF-8"]},
            "originDir": "/Users/a/posthog",
        }
        first = self.key(postgres=module.postgres_service(service))
        # Checkouts share the dumps: where enve found enve.cue isn't the schema.
        moved = {**service, "originDir": "/Users/b/posthog"}
        self.assertEqual(first, self.key(postgres=module.postgres_service(moved)))
        # The C locale folds LOWER('İ') differently: a template built under it differs.
        c_locale = {**service, "lifecycle": {"init": ["initdb -D \"$DATA_DIR\" --locale=C"]}}
        self.assertNotEqual(first, self.key(postgres=module.postgres_service(c_locale)))

    def test_runtime_is_what_builds_the_schema(self) -> None:
        versions = {"sqlx": "sqlx-cli 0.8.6", "enve": "enve v1"}

        def check_output(argv, text=True):
            return versions[argv[0]] + "\n"

        with mock.patch.object(module.subprocess, "check_output", check_output):
            first = module.runtime("170005")
            self.assertNotEqual(first, module.runtime("180000"))
            versions["sqlx"] = "sqlx-cli 0.9.0"
            second = module.runtime("170005")
            self.assertNotEqual(first, second)
            # An enve rebuild doesn't migrate anything: enve.lock pins what it provides.
            versions["enve"] = "enve v2"
            self.assertEqual(second, module.runtime("170005"))

    def test_code_and_pipeline_edits_reuse_the_templates(self) -> None:
        # Keyed on every file, an edit anywhere rebuilt ~3060 migrations (10-45 min).
        first = self.key()
        for name in (
            "posthog/models/team.py",
            "posthog/api/team.py",
            "frontend/src/index.ts",
            ".enact/components.cue",
            ".enact/state/completed_tasks.json",
            # Its Postgres service and environment are keyed as enve evaluates them: another
            # service's command (ClickHouse's) rebuilt every template.
            "enve.cue",
            "posthog/clickhouse/migrations/0001_initial.py",
            "posthog/async_migrations/migrations/0001_x.py",
        ):
            with self.subTest(name=name):
                self.write(name, "changed\n")
                self.assertEqual(first, self.key())


class SchemaEnvironmentTest(unittest.TestCase):
    """The key is the same in every run and enve instance: each runs its services on ports
    of its own, and keyed on them every run missed the templates and migrated forward."""

    DECLARED = {
        "DATABASE_URL": "postgres://posthog:posthog@127.0.0.1:${ENVE_SERVICE_POSTGRES_PORT}/posthog",
        "PGPORT": "${ENVE_SERVICE_POSTGRES_PORT}",
        "KAFKA_HOSTS": "127.0.0.1:${ENVE_SERVICE_KAFKA_PORT}",
        "PGUSER": "posthog",
        "TZ": "UTC",
    }

    def run_environ(self, port: int, **overrides: str) -> dict[str, str]:
        return {
            "DATABASE_URL": f"postgres://posthog:posthog@127.0.0.1:{port}/posthog",
            "PGPORT": str(port),
            "KAFKA_HOSTS": f"127.0.0.1:{port + 1}",
            "PGUSER": "posthog",
            "TZ": "UTC",
            **overrides,
        }

    def test_per_run_ports_keep_the_key(self) -> None:
        first = module.schema_environment(self.DECLARED, self.run_environ(54011))
        self.assertEqual(first, module.schema_environment(self.DECLARED, self.run_environ(61377)))
        self.assertEqual(first["PGPORT"], "${ENVE_SERVICE_POSTGRES_PORT}")

    def test_what_the_build_sees_otherwise_changes_it(self) -> None:
        first = module.schema_environment(self.DECLARED, self.run_environ(54011))
        for key, value in (("PGUSER", "other"), ("TZ", "Europe/Paris")):
            with self.subTest(key=key):
                self.assertNotEqual(
                    first,
                    module.schema_environment(self.DECLARED, self.run_environ(54011, **{key: value})),
                )
        declared = {**self.DECLARED, "DATABASE_URL": self.DECLARED["DATABASE_URL"] + "_other"}
        self.assertNotEqual(first, module.schema_environment(declared, self.run_environ(54011)))


class NewestBaseTest(unittest.TestCase):
    """A key's miss starts from the newest dump whose migrations the checkout still has."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.current = {"posthog/migrations/0001_initial.py": "a", "posthog/migrations/0002_x.py": "b"}

    def save(self, key: str, applied, generation="v3.abcdefgh", age=0) -> Path:
        directory = self.root / key / generation
        directory.mkdir(parents=True)
        if applied is not None:
            (directory / module.MIGRATIONS_FILE).write_text(json.dumps(applied))
        pointer = self.root / key / "current-v3"
        pointer.write_text(generation + "\n")
        os.utime(pointer, (1_000_000 - age, 1_000_000 - age))
        return directory

    def test_newest_dump_the_checkout_extends(self) -> None:
        self.save("old", {"posthog/migrations/0001_initial.py": "a"}, age=100)
        newest = self.save("new", {"posthog/migrations/0001_initial.py": "a"}, age=10)
        self.assertEqual(newest, module.newest_base(self.root, self.current))

    def test_a_dump_ahead_of_or_apart_from_the_checkout_is_not_a_base(self) -> None:
        # Migrations apply forward only: one the checkout lacks or changed can't be undone.
        older = self.save("older", {"posthog/migrations/0001_initial.py": "a"}, age=100)
        self.save("ahead", {**self.current, "posthog/migrations/0003_y.py": "c"}, age=1)
        self.save("edited", {"posthog/migrations/0001_initial.py": "z"}, age=2)
        self.save("unlisted", None, age=3)  # saved before dumps listed their migrations
        self.assertEqual(older, module.newest_base(self.root, self.current))

    def test_none_without_a_usable_dump(self) -> None:
        self.assertIsNone(module.newest_base(self.root, self.current))
        self.save("broken", {}, generation="../escape")
        self.assertIsNone(module.newest_base(self.root, self.current))

    def test_migrations_are_the_schema_inputs_less_the_build_files(self) -> None:
        root = self.root / "repo"
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        for name in ("posthog/migrations/0001_initial.py", "rust/persons_migrations/1_init.sql", "uv.lock", "posthog/models/team.py"):
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text(name)
        self.assertEqual(
            ["posthog/migrations/0001_initial.py", "rust/persons_migrations/1_init.sql"],
            sorted(module.TemplateInputs(root).migrations()),
        )


if __name__ == "__main__":
    unittest.main()
