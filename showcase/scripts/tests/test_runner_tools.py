"""The test runners' tools come from the locked environment, not the host.

flock (test_databases.sh) resolved to the host's util-linux, which macOS doesn't have; the rust
builds ran the host's cc, make and perl and found no protoc or openssl. Run inside the locked
environment (`enve run --locked -- python -m unittest ...`); skipped outside it.
"""

import os
import shutil
import unittest

# Every external command the runners (test_databases.sh, run_sharded_pytest.sh,
# run_nodejs_tests.sh, run_rust_tests.sh) and the rust and go builds they start call.
RUNNER_TOOLS = [
    "flock",
    "psql",
    "pg_dump",
    "pg_restore",
    "createdb",
    "clickhouse",
    "redis-cli",
    "sqlx",
    "uv",
    "python3",
    "node",
    "pnpm",
    "cargo",
    "rustc",
    "go",
    "protoc",
    "perl",
    "make",
    "pkg-config",
    "git",
    "curl",
    # bin/download-mmdb (run_rust_tests.sh).
    "brotli",
]
LINUX_ONLY = ["cc", "ld"]


def in_locked_environment() -> bool:
    return any(key.startswith("ENVE_SERVICE_") for key in os.environ)


@unittest.skipUnless(in_locked_environment(), "runs inside `enve run --locked`")
class RunnerToolsTest(unittest.TestCase):
    def test_every_runner_tool_is_locked(self) -> None:
        tools = RUNNER_TOOLS + (LINUX_ONLY if os.uname().sysname == "Linux" else [])
        for tool in tools:
            with self.subTest(tool=tool):
                path = shutil.which(tool)
                self.assertIsNotNone(path, f"{tool} is not on PATH")
                # The store, or enve's own when /nix/store links to it.
                self.assertTrue(
                    path.startswith("/nix/store/") or "/enve/store/" in os.path.realpath(path),
                    f"{tool} resolves to the host's {path}",
                )


if __name__ == "__main__":
    unittest.main()
