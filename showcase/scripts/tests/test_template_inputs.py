"""`template_inputs.py` (`enact helper pg-template`) keys templates on schema inputs, migrations, and base dumps."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("template_inputs.py")
if not SCRIPT.is_file():
    SCRIPT = Path(__file__).resolve().parents[1] / "template_inputs.py"

ENVE_CUE = """profiles: dev: {
\tenvironment: {
\t\tDATABASE_URL: "postgres://posthog:posthog@127.0.0.1:${ENVE_SERVICE_POSTGRES_PORT}/posthog"
\t\tPGPORT: "${ENVE_SERVICE_POSTGRES_PORT}"
\t\tPGUSER: "posthog"
\t\tTZ: "UTC"
\t}
\tservices: postgres: {
\t\tcommand: "postgres -D \\"$DATA_DIR\\" -c max_connections=1000"
\t\tlifecycle: init: ["initdb -D \\"$DATA_DIR\\" --locale=__LOCALE__"]
\t\toriginDir: "__ORIGIN__"
\t}
}
"""


def init_repo(root: Path, locale: str = "C.UTF-8", origin: str = "/Users/a/posthog") -> None:
    root.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    (root / "enve.cue").write_text(
        ENVE_CUE.replace("__LOCALE__", locale).replace("__ORIGIN__", origin)
    )
    bin_dir = root / ".test-bin"
    bin_dir.mkdir(exist_ok=True)
    sqlx = bin_dir / "sqlx"
    sqlx.write_text("#!/bin/sh\necho 'sqlx-cli 0.8.6'\n")
    sqlx.chmod(0o755)
    (root / ".gitignore").write_text(".test-bin/\n")


def run_cmd(root: Path, *args: str, env_overrides: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    env = {
        **os.environ,
        "PATH": f"{root / '.test-bin'}:{os.environ.get('PATH', '')}",
        "CI": "1",
        "PGUSER": "posthog",
        "TZ": "UTC",
        "PGPORT": "54011",
        "DATABASE_URL": "postgres://posthog:posthog@127.0.0.1:54011/posthog",
    }
    if env_overrides:
        env.update(env_overrides)
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        cwd=root,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


class TemplateInputsTest(unittest.TestCase):
    """The templates are rebuilt when the migrated schema can differ, and only then."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        init_repo(self.root)
        self.write("posthog/migrations/0001_initial.py", "operations = []\n")
        self.write("posthog/models/team.py", "class Team: pass\n")
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)

    def write(self, name: str, text: str) -> Path:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def key(
        self,
        server_version: str = "170005",
        bootstrap: str = "bootstrap",
        env_overrides: dict[str, str] | None = None,
    ) -> str:
        res = run_cmd(self.root, "key", server_version, bootstrap, env_overrides=env_overrides)
        self.assertEqual(res.returncode, 0, res.stderr)
        return res.stdout.strip()

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
        self.assertNotEqual(first, self.key(server_version="180000"))
        self.assertNotEqual(first, self.key(env_overrides={"CI": "0"}))
        self.assertNotEqual(first, self.key(bootstrap="other-bootstrap"))
        self.assertEqual(
            first,
            self.key(
                env_overrides={
                    "PGPORT": "61377",
                    "DATABASE_URL": "postgres://posthog:posthog@127.0.0.1:61377/posthog",
                }
            ),
        )
        self.assertNotEqual(first, self.key(env_overrides={"TZ": "Europe/Paris"}))

        init_repo(self.root, locale="C.UTF-8", origin="/Users/b/posthog")
        self.assertEqual(first, self.key())
        init_repo(self.root, locale="C", origin="/Users/b/posthog")
        self.assertNotEqual(first, self.key())

    def test_code_and_pipeline_edits_reuse_the_templates(self) -> None:
        first = self.key()
        for name in (
            "posthog/models/team.py",
            "posthog/api/team.py",
            "frontend/src/index.ts",
            ".enact/components.cue",
            ".enact/state/summary.html",
            "posthog/clickhouse/migrations/0001_initial.py",
            "posthog/async_migrations/migrations/0001_x.py",
        ):
            with self.subTest(name=name):
                self.write(name, "changed\n")
                self.assertEqual(first, self.key())


class NewestBaseTest(unittest.TestCase):
    """A key's miss starts from the newest dump whose migrations the checkout still has."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.repo = self.work / "repo"
        self.snapshots = self.work / "snapshots"
        init_repo(self.repo)
        for name, body in (
            ("posthog/migrations/0001_initial.py", "a"),
            ("posthog/migrations/0002_x.py", "b"),
            ("rust/persons_migrations/1_init.sql", "c"),
            ("uv.lock", "lock"),
            ("posthog/models/team.py", "team"),
        ):
            p = self.repo / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body)
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        res = run_cmd(self.repo, "migrations")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.current: dict[str, str] = json.loads(res.stdout)

    def save(self, key: str, applied: dict[str, str] | None, generation: str = "v3.abcdefgh", age: int = 0) -> Path:
        directory = self.snapshots / key / generation
        directory.mkdir(parents=True, exist_ok=True)
        if applied is not None:
            (directory / "migrations.json").write_text(json.dumps(applied))
        pointer = self.snapshots / key / "current-v3"
        pointer.write_text(generation + "\n")
        os.utime(pointer, (1_000_000 - age, 1_000_000 - age))
        return directory

    def base(self) -> Path | None:
        res = run_cmd(self.repo, "base", str(self.snapshots))
        if res.returncode != 0:
            return None
        return Path(res.stdout.strip())

    def test_migrations_are_the_schema_inputs_less_the_build_files(self) -> None:
        self.assertEqual(
            [
                "posthog/migrations/0001_initial.py",
                "posthog/migrations/0002_x.py",
                "rust/persons_migrations/1_init.sql",
            ],
            sorted(self.current),
        )

    def test_newest_dump_the_checkout_extends_and_rejects_ahead_or_edited(self) -> None:
        self.assertIsNone(self.base())
        self.save("broken", {}, generation="../escape")
        self.assertIsNone(self.base())

        one = {"posthog/migrations/0001_initial.py": self.current["posthog/migrations/0001_initial.py"]}
        older = self.save("old", one, age=100)
        self.save("ahead", {**self.current, "posthog/migrations/0003_y.py": "d"}, age=1)
        self.save("edited", {"posthog/migrations/0001_initial.py": "z"}, age=2)
        self.save("unlisted", None, age=3)
        self.assertEqual(older, self.base())

        newest = self.save("new", one, age=10)
        self.assertEqual(newest, self.base())


if __name__ == "__main__":
    unittest.main()
