"""Every UDF ClickHouse loads from posthog/user_scripts starts on this host.

A wrapper starts the binary for its host through run_udf.sh: a committed Linux one, or on macOS
the host build infra/clickhouse/build_host_udfs.sh makes (the clickhouse service's preStart;
patches/0009). On macOS run_udf.sh globbed /proc, which macOS doesn't have, and then started a
Linux binary, so every UDF call failed (test_event_model's native inserts, the funnel suites). A
UDF that config names and the host build leaves out fails here on the Mac.
"""

import os
import re
import select
import subprocess
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "posthog/user_scripts"
# The unversioned functions, which the code calls outside GitHub Actions (posthog/hogql/functions/udfs.py).
CONFIG = ROOT / "docker/clickhouse/user_defined_function.xml"


@unittest.skipUnless(SCRIPTS.is_dir() and CONFIG.is_file(), "needs a PostHog checkout with the overlay")
class ClickHouseUdfTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # What the clickhouse service's preStart runs: nothing on Linux, the host build on macOS.
        subprocess.run(
            ["showcase/scripts/exclusive.sh", "clickhouse-host-udfs", "infra/clickhouse/build_host_udfs.sh"],
            cwd=ROOT,
            check=True,
        )

    def commands(self) -> list[list[str]]:
        """Each executable command the config declares, a parameter as an empty array."""
        commands = {function.findtext("command") for function in ET.parse(CONFIG).getroot().iter("function")}
        return [
            [str(SCRIPTS / argv[0]), *(re.sub(r"^\{.*\}$", "[]", arg) for arg in argv[1:])]
            for argv in sorted(command.split() for command in commands if command)
            if not argv[0].endswith(".py")
        ]

    def test_every_udf_starts_on_this_host(self) -> None:
        commands = self.commands()
        self.assertTrue(commands)
        for command in commands:
            with self.subTest(command=" ".join(command[:1] + command[1:])):
                done = subprocess.run(command, input=b"", capture_output=True, timeout=60)
                self.assertEqual(0, done.returncode, done.stderr.decode())

    def test_a_udf_keeps_no_inherited_descriptor(self) -> None:
        # ClickHouse starts a UDF with copies of its client connections; a pooled UDF holding one
        # keeps the connection open after the server closes it (run_udf.sh's comment).
        held, inherited = os.pipe()
        try:
            udf = subprocess.Popen(
                [str(SCRIPTS / "decompress_udf")],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                pass_fds=(inherited,),
            )
            os.close(inherited)
            try:
                # While the UDF still waits on its input, the pipe ends only if it closed its copy.
                ready, _, _ = select.select([held], [], [], 20)
                self.assertTrue(ready, "the running UDF still holds the descriptor it inherited")
                self.assertEqual(b"", os.read(held, 1))
                self.assertIsNone(udf.poll())
            finally:
                udf.stdin.close()
                udf.wait(timeout=30)
        finally:
            os.close(held)


if __name__ == "__main__":
    unittest.main()
