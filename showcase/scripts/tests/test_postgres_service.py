"""The postgres service runs with docker-compose.dev.yml's settings, as every CI job's db does.

With the default 100 connections the nodejs suite's jest workers failed with "sorry, too many
clients already". Needs the running service and psql (`enve run --locked -- python3 -m unittest
showcase/scripts/tests/test_postgres_service.py`).
"""

import os
import shutil
import subprocess
import unittest


def setting(name: str) -> str | None:
    # The env's server only (PGPORT): a fixed default would reach another run's.
    if not os.environ.get("PGPORT"):
        return None
    result = subprocess.run(
        ["psql", "-h", os.environ.get("PGHOST", "127.0.0.1"), "-p", os.environ["PGPORT"],
         "-U", "postgres", "-d", "postgres", "-Atc", f"SHOW {name}"],
        capture_output=True, text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else None


@unittest.skipUnless(shutil.which("psql") and setting("server_version"), "needs the postgres service")
class PostgresServiceTest(unittest.TestCase):
    def test_compose_settings(self) -> None:
        self.assertGreaterEqual(int(setting("max_connections")), 1000)
        self.assertGreaterEqual(int(setting("max_prepared_transactions")), 10)
        self.assertEqual(setting("idle_in_transaction_session_timeout"), "5min")


if __name__ == "__main__":
    unittest.main()
