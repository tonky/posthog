"""The Playwright browsers come from the locked environment's store and render headless DOM.

Run inside the locked environment (`enve run --locked -- python -m unittest ...`); skipped
outside it.
"""

import os
from pathlib import Path
import subprocess
import unittest


def in_locked_environment() -> bool:
    return any(key.startswith("ENVE_SERVICE_") for key in os.environ)


@unittest.skipUnless(in_locked_environment(), "runs inside `enve run --locked`")
class BrowserStoreTest(unittest.TestCase):
    def test_playwright_browsers_are_locked_and_render_dom(self) -> None:
        raw_path = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")
        self.assertIsNotNone(raw_path, "PLAYWRIGHT_BROWSERS_PATH is not set")
        assert raw_path is not None
        self.assertTrue(
            raw_path.startswith("/nix/store/") or "/enve/store/" in os.path.realpath(raw_path),
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


if __name__ == "__main__":
    unittest.main()
