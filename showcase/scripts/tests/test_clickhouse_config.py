"""The overlay's ClickHouse config (infra/clickhouse/config.xml) on the checkout it is copied onto."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CONFIG = ROOT / "infra/clickhouse/config.xml"
START = ROOT / "infra/clickhouse/start.sh"
JIT_SETTINGS = ["compile_expressions", "compile_aggregate_expressions", "compile_sort_description"]
# The service's command renders @ROOT@ (the checkout) and @DATA_DIR@ (its instance's data dir).
DATA_DIR = ROOT / ".enve/instances/enact-0/data/clickhouse"


@unittest.skipUnless((ROOT / "posthog/user_scripts").is_dir(), "needs a PostHog checkout with the overlay")
class ClickHouseConfigTest(unittest.TestCase):
    def setUp(self) -> None:
        self.config = ET.parse(CONFIG).getroot()

    def resolve(self, value: str) -> Path:
        return Path(value.replace("@ROOT@", str(ROOT)).replace("@DATA_DIR@", str(DATA_DIR))).resolve()

    def test_listeners_and_paths_follow_the_instance(self) -> None:
        # A fixed port or a default-instance path reaches, or overwrites, another instance's server (E7).
        for tag in ["http_port", "tcp_port", "interserver_http_port", "keeper_server/tcp_port"]:
            self.assertFalse(self.config.findtext(tag), tag)
            self.assertTrue(self.config.find(tag).get("from_env", "").startswith("PORT"), tag)
        for port in self.config.iter("port"):
            self.assertIsNotNone(port.get("from_env"), ET.tostring(port))
        for element in self.config.iter():
            text = (element.text or "").strip()
            self.assertFalse(".enve/data" in text or text.startswith("../"), (element.tag, text))

    def test_udf_paths_resolve_in_the_checkout(self) -> None:
        scripts = self.resolve(self.config.findtext("user_scripts_path"))
        self.assertEqual(scripts, ROOT / "posthog/user_scripts")
        for entry in self.config.findall("user_defined_executable_functions_config"):
            self.assertTrue(self.resolve(entry.text).is_file(), entry.text)

    def test_both_udf_namings_are_defined(self) -> None:
        # Outside CI the code calls JSONDropKeys, under CI (posthog.udf_versioner) JSONDropKeys_v<N>.
        names = set()
        for entry in self.config.findall("user_defined_executable_functions_config"):
            names |= {n.text for n in ET.parse(self.resolve(entry.text)).getroot().findall("function/name")}
        self.assertIn("JSONDropKeys", names)
        self.assertTrue(any(n.startswith("JSONDropKeys_v") for n in names), names)

    def start(self, platform: str) -> tuple[Path, list[str]]:
        """Runs start.sh as the service does (in the checkout, with $DATA_DIR), uname and the
        server stubbed: the data dir it prepared, and the server's arguments."""
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        data, stubs = Path(tmp.name) / "data", Path(tmp.name) / "bin"
        data.mkdir()
        stubs.mkdir()
        shutil.copy(CONFIG, data / "config.template.xml")
        for name, body in (("uname", f"echo {platform}"), ("clickhouse-server", 'printf "%s\\n" "$@"')):
            (stubs / name).write_text(f"#!/bin/sh\n{body}\n")
            (stubs / name).chmod(0o755)
        done = subprocess.run(
            [str(START)], cwd=ROOT, capture_output=True, text=True, check=True,
            env={**os.environ, "DATA_DIR": str(data), "PATH": f"{stubs}:{os.environ['PATH']}"},
        )
        return data, done.stdout.splitlines()

    def test_users_and_profiles_are_upstreams(self) -> None:
        # A copy drifts (it had lost insert_distributed_sync and the Kafka flush interval).
        self.assertIsNone(self.config.find("profiles"))
        self.assertIsNone(self.config.find("users"))
        self.assertEqual("@DATA_DIR@/users.xml", self.config.findtext("user_directories/users_xml/path"))
        data, argv = self.start("Linux")
        self.assertEqual([f"--config-file={data}/config.xml"], argv)
        self.assertEqual((data / "users.xml").resolve(), (ROOT / "docker/clickhouse/users-dev.xml").resolve())
        rendered = ET.parse(data / "config.xml").getroot()
        self.assertEqual(f"{data}/users.xml", rendered.findtext("user_directories/users_xml/path"))
        # Upstream's container runs Linux: nothing laid over its profiles there.
        self.assertEqual([], sorted(p.name for p in (data / "users.d").iterdir()))

    def test_macos_runs_without_jit_in_every_profile(self) -> None:
        # The macOS build's JIT can't link what it compiles (Code: 263, _bzero): every profile
        # a query can run under turns it off, not only default.
        data, _ = self.start("Darwin")
        self.assertEqual(["darwin.xml"], sorted(p.name for p in (data / "users.d").iterdir()))
        overrides = ET.parse(data / "users.d/darwin.xml").getroot().find("profiles")
        profiles = ET.parse(ROOT / "docker/clickhouse/users-dev.xml").getroot().find("profiles")
        roots = {p.tag for p in profiles if p.find("profile") is None}
        self.assertEqual(roots, {p.tag for p in overrides})
        for profile in overrides:
            for setting in JIT_SETTINGS:
                self.assertEqual("0", profile.findtext(setting), (profile.tag, setting))

    # The env's server only (CLICKHOUSE_TCP_PORT): a fixed default would reach another run's.
    @unittest.skipUnless(
        shutil.which("clickhouse-client") and os.environ.get("CLICKHOUSE_TCP_PORT"),
        "needs clickhouse-client and the clickhouse service",
    )
    def test_the_running_server_applies_upstreams_profile(self) -> None:
        upstream = ET.parse(ROOT / "docker/clickhouse/users-dev.xml").getroot().find("profiles/default")
        names = ["insert_distributed_sync", "stream_flush_interval_ms", "async_insert", "compatibility"]
        result = subprocess.run(
            ["clickhouse-client", "--port", os.environ["CLICKHOUSE_TCP_PORT"], "-q",
             "SELECT name, value FROM system.settings WHERE name IN (%s) FORMAT TSV"
             % ", ".join(f"'{n}'" for n in names)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            self.skipTest("the clickhouse service isn't running")
        live = dict(line.split("\t", 1) for line in result.stdout.splitlines())
        for name in names:
            self.assertEqual(live[name], upstream.findtext(name), name)

    @unittest.skipUnless(
        shutil.which("clickhouse-client") and os.environ.get("CLICKHOUSE_TCP_PORT"),
        "needs clickhouse-client and the clickhouse service",
    )
    def test_the_running_server_compiles_expressions_where_it_can_link_them(self) -> None:
        result = subprocess.run(
            ["clickhouse-client", "--port", os.environ["CLICKHOUSE_TCP_PORT"], "-q",
             "SELECT name, value FROM system.settings WHERE name IN (%s) FORMAT TSV"
             % ", ".join(f"'{n}'" for n in JIT_SETTINGS)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            self.skipTest("the clickhouse service isn't running")
        expected = "0" if sys.platform == "darwin" else "1"
        self.assertEqual({n: expected for n in JIT_SETTINGS}, dict(l.split("\t", 1) for l in result.stdout.splitlines()))

    def test_every_named_collection_upstream_defines_is_defined(self) -> None:
        # The Kafka engine tables name their cluster; upstream's dev server defines them all.
        upstream = ET.parse(ROOT / "docker/clickhouse/config.d/default.xml").getroot()
        expected = {c.tag for c in upstream.find("named_collections")}
        ours = {c.tag for c in self.config.find("named_collections")}
        self.assertTrue(expected, "upstream defines no named collections")
        self.assertLessEqual(expected, ours)


if __name__ == "__main__":
    unittest.main()
