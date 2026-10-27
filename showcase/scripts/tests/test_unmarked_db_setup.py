"""A test reaching `django_db_setup` through a fixture without a `django_db` marker gets every
test database set up (pytest_unmarked_db_setup.py), even in a session of only such tests:
pytest-django sets up only what marked tests ask for, so posthog's dags modules using the
`cluster` fixture, and visual_review's unmarked tests (an autouse fixture on the product
database), failed when selected alone. A session of marked tests only is set up
as without the plugin.

Runs a real pytest session with Django and pytest-django (the backend environment's); skipped
without them.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PLUGINS = Path(__file__).resolve().parents[2] / "pytest_plugins"

SETTINGS = """
SECRET_KEY = "x"
INSTALLED_APPS = []
DATABASES = {
    "default": {"ENGINE": "django.db.backends.sqlite3", "NAME": "real.sqlite3"},
    "product": {"ENGINE": "django.db.backends.sqlite3", "NAME": "product.sqlite3"},
}
USE_TZ = True
"""

CONFTEST = """
import pytest
from django.db import connections

def names():
    return {alias: connections[alias].settings_dict["NAME"] for alias in ("default", "product")}

@pytest.fixture
def cluster(django_db_setup):
    yield names()
"""

UNMARKED = """
def test_unmarked(cluster):
    assert cluster["default"] != "real.sqlite3", cluster
    assert cluster["product"] != "product.sqlite3", cluster
"""

MARKED = """
import pytest
from conftest import names

@pytest.mark.django_db
def test_marked():
    assert names()["default"] != "real.sqlite3", names()
    assert names()["product"] == "product.sqlite3", names()
"""


@unittest.skipUnless(
    importlib.util.find_spec("pytest_django") and importlib.util.find_spec("django"),
    "needs django and pytest-django",
)
class UnmarkedDbSetupTest(unittest.TestCase):
    def pytest(self, *plugins: str, unmarked: bool = True, marked: bool = False) -> subprocess.CompletedProcess:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        directory = Path(tmp.name)
        (directory / "pytest.ini").write_text("[pytest]\nDJANGO_SETTINGS_MODULE = settings\n")
        (directory / "settings.py").write_text(SETTINGS)
        (directory / "conftest.py").write_text(CONFTEST)
        if unmarked:
            (directory / "test_unmarked.py").write_text(UNMARKED)
        if marked:
            (directory / "test_marked.py").write_text(MARKED)
        plugin_args = [arg for plugin in plugins for arg in ("-p", plugin)]
        return subprocess.run(
            [sys.executable, "-m", "pytest", "-p", "no:cacheprovider", "-p", "django", *plugin_args, "-v"],
            cwd=directory,
            env={
                **os.environ,
                "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1",
                "PYTHONPATH": os.pathsep.join([str(directory), str(PLUGINS)]),
            },
            capture_output=True,
            text=True,
        )

    def test_unmarked_tests_alone_get_every_test_database(self) -> None:
        done = self.pytest("pytest_unmarked_db_setup")
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)

    def test_marked_tests_alone_get_what_they_ask_for(self) -> None:
        done = self.pytest("pytest_unmarked_db_setup", unmarked=False, marked=True)
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)

    def test_without_the_plugin_they_get_the_real_ones(self) -> None:
        # pytest-django's own behaviour, which the plugin exists for: a session of only
        # unmarked tests sets up nothing.
        alone = self.pytest()
        self.assertEqual(1, alone.returncode, alone.stdout + alone.stderr)
        self.assertIn("AssertionError: {'default': 'real.sqlite3'", alone.stdout)


if __name__ == "__main__":
    unittest.main()
