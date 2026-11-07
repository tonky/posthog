"""The Playwright browsers come from the locked environment's store and render headless DOM.

Run inside the locked environment (`enve run --locked -- python -m unittest ...`); skipped
outside it.
"""

import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path

PRELOAD = Path(__file__).resolve().parents[3] / ".enact" / "vitest" / "node_env_preload.cjs"


def in_locked_environment() -> bool:
    return any(key.startswith("ENVE_SERVICE_") for key in os.environ)


@unittest.skipUnless(in_locked_environment(), "runs inside `enve run --locked`")
class BrowserStoreTest(unittest.TestCase):
    def test_playwright_browsers_are_locked_and_render_dom(self) -> None:
        raw_path = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")
        self.assertIsNotNone(raw_path, "PLAYWRIGHT_BROWSERS_PATH is not set")
        assert raw_path is not None
        self.assertTrue(
            raw_path.startswith("/nix/store/")
            or "/enve/store/" in os.path.realpath(raw_path)
            # A relocated store (a runner's host cache, /cache/repo/enve-store).
            or bool(store := os.environ.get("ENVE_STORE_DIR"))
            and os.path.realpath(raw_path).startswith(os.path.join(os.path.realpath(store), "")),
            f"PLAYWRIGHT_BROWSERS_PATH resolves outside the store: {raw_path}",
        )
        browsers_dir = Path(raw_path)
        self.assertTrue(browsers_dir.is_dir(), f"{browsers_dir} is not a directory")

        chromium_dirs = [p for p in browsers_dir.glob("chromium-*") if p.is_dir()]
        self.assertTrue(chromium_dirs, f"no chromium-* directory in {browsers_dir}")
        for d in chromium_dirs:
            self.assertTrue(
                (d / "INSTALLATION_COMPLETE").is_file(),
                f"missing INSTALLATION_COMPLETE in {d}",
            )

        headless_dirs = [p for p in browsers_dir.glob("chromium_headless_shell-*") if p.is_dir()]
        self.assertTrue(
            headless_dirs,
            f"no chromium_headless_shell-* directory in {browsers_dir}",
        )
        for d in headless_dirs:
            self.assertTrue(
                (d / "INSTALLATION_COMPLETE").is_file(),
                f"missing INSTALLATION_COMPLETE in {d}",
            )

        executables = [
            p
            for d in headless_dirs
            for name in ("chrome-headless-shell", "headless_shell")
            for p in d.rglob(name)
            if p.is_file() and os.access(p, os.X_OK)
        ]
        self.assertTrue(
            executables,
            f"no executable chrome-headless-shell/headless_shell in {headless_dirs}",
        )
        exe = str(executables[0])
        res = subprocess.run(
            [
                exe,
                "--headless",
                "--no-sandbox",
                "--dump-dom",
                "data:text/html,<title>enve-posthog-ok</title>",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertIn("enve-posthog-ok", res.stdout)


@unittest.skipUnless(shutil.which("node"), "needs node")
class NodeEnvPreloadTest(unittest.TestCase):
    def _stringify_with_preload(self, payload: object, pg_port: str = "55432") -> object:
        script = "process.stdout.write(JSON.stringify(JSON.parse(process.argv[1])))"
        res = subprocess.run(
            ["node", "--require", str(PRELOAD), "-e", script, json.dumps(payload)],
            check=True,
            capture_output=True,
            text=True,
            env={**os.environ, "PGPORT": pg_port},
        )
        return json.loads(res.stdout)

    def test_pgport_rewrites_plain_and_playwright_serialized_trees(self) -> None:
        cases = [
            (
                "plain job_inputs string port",
                {"job_inputs": {"host": "127.0.0.1", "port": "5432", "dbname": "posthog"}},
                {"job_inputs": {"host": "127.0.0.1", "port": "55432", "dbname": "posthog"}},
            ),
            (
                "plain payload string port",
                {"payload": {"host": "localhost", "port": "5432", "database": "posthog"}},
                {"payload": {"host": "localhost", "port": "55432", "database": "posthog"}},
            ),
            (
                "nested body payload numeric port",
                {"body": {"payload": {"host": "localhost", "port": 5432, "database": "posthog"}}},
                {"body": {"payload": {"host": "localhost", "port": 55432, "database": "posthog"}}},
            ),
            (
                "playwright serializeAsCallArgument nested payload",
                {
                    "o": [
                        {
                            "k": "body",
                            "v": {
                                "o": [
                                    {
                                        "k": "payload",
                                        "v": {
                                            "o": [
                                                {"k": "host", "v": {"s": "localhost"}},
                                                {"k": "port", "v": {"s": "5432"}},
                                                {"k": "database", "v": {"s": "posthog"}},
                                            ]
                                        },
                                    }
                                ]
                            },
                        }
                    ]
                },
                {
                    "o": [
                        {
                            "k": "body",
                            "v": {
                                "o": [
                                    {
                                        "k": "payload",
                                        "v": {
                                            "o": [
                                                {"k": "host", "v": {"s": "localhost"}},
                                                {"k": "port", "v": {"s": "55432"}},
                                                {"k": "database", "v": {"s": "posthog"}},
                                            ]
                                        },
                                    }
                                ]
                            },
                        }
                    ]
                },
            ),
            (
                "playwright serialized array numeric port with dbname",
                {
                    "a": [
                        {
                            "o": [
                                {"k": "host", "v": {"s": "127.0.0.1"}},
                                {"k": "port", "v": {"n": 5432}},
                                {"k": "dbname", "v": {"s": "posthog"}},
                            ]
                        }
                    ]
                },
                {
                    "a": [
                        {
                            "o": [
                                {"k": "host", "v": {"s": "127.0.0.1"}},
                                {"k": "port", "v": {"n": 55432}},
                                {"k": "dbname", "v": {"s": "posthog"}},
                            ]
                        }
                    ]
                },
            ),
            (
                "non-matching database stays untouched",
                {
                    "plain_other_db": {"host": "localhost", "port": "5432", "database": "other"},
                    "serialized_other": {
                        "o": [
                            {"k": "host", "v": {"s": "localhost"}},
                            {"k": "port", "v": {"s": "5432"}},
                            {"k": "database", "v": {"s": "other"}},
                        ]
                    },
                },
                {
                    "plain_other_db": {"host": "localhost", "port": "5432", "database": "other"},
                    "serialized_other": {
                        "o": [
                            {"k": "host", "v": {"s": "localhost"}},
                            {"k": "port", "v": {"s": "5432"}},
                            {"k": "database", "v": {"s": "other"}},
                        ]
                    },
                },
            ),
            (
                "non-matching host stays untouched",
                {
                    "plain_remote": {"host": "db.example.com", "port": "5432", "database": "posthog"},
                    "serialized_remote": {
                        "o": [
                            {"k": "host", "v": {"s": "db.example.com"}},
                            {"k": "port", "v": {"s": "5432"}},
                            {"k": "database", "v": {"s": "posthog"}},
                        ]
                    },
                },
                {
                    "plain_remote": {"host": "db.example.com", "port": "5432", "database": "posthog"},
                    "serialized_remote": {
                        "o": [
                            {"k": "host", "v": {"s": "db.example.com"}},
                            {"k": "port", "v": {"s": "5432"}},
                            {"k": "database", "v": {"s": "posthog"}},
                        ]
                    },
                },
            ),
        ]
        for label, given, expected in cases:
            with self.subTest(case=label):
                self.assertEqual(expected, self._stringify_with_preload(given))

    def test_pgport_handles_circular_objects_without_recursing_forever(self) -> None:
        script = (
            "const obj = { payload: { host: 'localhost', port: '5432', database: 'posthog' } };"
            "obj.self = obj;"
            "process.stdout.write(JSON.stringify(obj, (k, v) => (k === 'self' ? undefined : v)));"
        )
        res = subprocess.run(
            ["node", "--require", str(PRELOAD), "-e", script],
            check=True,
            capture_output=True,
            text=True,
            env={**os.environ, "PGPORT": "55432"},
        )
        self.assertEqual(
            {"payload": {"host": "localhost", "port": "55432", "database": "posthog"}},
            json.loads(res.stdout),
        )


if __name__ == "__main__":
    unittest.main()
