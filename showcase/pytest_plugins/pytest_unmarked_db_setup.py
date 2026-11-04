"""pytest plugin: a test whose fixtures depend on `django_db_setup` gets the test databases set
up, whether or not it carries a `django_db` marker.

pytest-django's session `django_db_setup` creates only the databases the session's marked
tests (and Django TestCases) ask for, read from every collected item. A test that reaches
`django_db_setup` through a fixture without the marker (posthog's dags `cluster` fixture, the
visual_review tests' autouse product-database fixture) asks for none. In a session of only
such tests nothing is created: the default connection keeps its real name (posthog's conftest
then refuses to migrate a persons database that isn't a test one) and the product databases
don't exist. Upstream runs a whole directory in one session, so the marked tests always come
along; a selection or a shard of the unmarked modules alone has none.

Such a test doesn't say which databases its fixtures reach, so with this plugin it counts as
asking for every configured one (`databases="__all__"`), a superset of what any whole-suite
session sets up: the tests run as they do in the whole directory, in any subset or order.

A session whose tests all carry markers is set up exactly as without the plugin.
Repository-neutral: it reads the tests' markers and fixture closures. It wraps pytest-django's
`_get_databases_for_setup` and `_get_databases_for_test` (private; pinned ~=4.14) and fails
the session at configure time if a pytest-django upgrade removes them.
"""

import pytest

SETUP_FIXTURE = "django_db_setup"


def _unmarked_setup(item, get_databases_for_test) -> bool:
    databases, _ = get_databases_for_test(item)
    return not databases and SETUP_FIXTURE in getattr(item, "fixturenames", ())


def _with_all(get_databases_for_setup, get_databases_for_test):
    def get_databases(items):
        aliases, serialized_aliases = get_databases_for_setup(items)
        if any(_unmarked_setup(item, get_databases_for_test) for item in items):
            from django.db import connections

            aliases = {*aliases, *connections}
        return aliases, serialized_aliases

    return get_databases


@pytest.hookimpl(trylast=True)
def pytest_configure(config):
    if not config.pluginmanager.hasplugin("django"):
        return
    from pytest_django import fixtures

    for_setup = getattr(fixtures, "_get_databases_for_setup", None)
    for_test = getattr(fixtures, "_get_databases_for_test", None)
    if for_setup is None or for_test is None:
        raise pytest.UsageError(
            "pytest_unmarked_db_setup: pytest-django has no _get_databases_for_setup or "
            "_get_databases_for_test; update the plugin for this pytest-django version"
        )
    fixtures._get_databases_for_setup = _with_all(for_setup, for_test)
