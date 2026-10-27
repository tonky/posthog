"""pytest plugin: a session- or package-scoped fixture failing its setup ends the session at
once, with pytest's own "interrupted" exit (2), naming the fixture and its error.

Such a fixture serves every later test: pytest caches its error and reports it again for each
one (and pytest-rerunfailures reruns each), so the session runs on for minutes to say one
thing many times. posthog's `django_db_setup` creating the ClickHouse tables timed out once,
and every test of both shards reported that same error. A test's own failure, or a class-
or module-scoped fixture's (a test class's own setup), only fails the tests that use it and
doesn't stop anything.

enact maps the exit through the task's `error_exit_codes` ([2, 3, 4]: interrupted, internal
error, usage error) to an error, which stops the whole run; the tests' failures (1) don't. No
output is parsed: pytest's exit code says it. Repository-neutral: it only reads fixtures'
scopes.
"""

import pytest

BROAD_SCOPES = ("session", "package")


@pytest.hookimpl(wrapper=True)
def pytest_fixture_setup(fixturedef, request):
    try:
        return (yield)
    except (Exception, pytest.fail.Exception) as error:
        session = request.session
        if fixturedef.scope in BROAD_SCOPES and not session.shouldstop:
            first = str(error).strip().splitlines()[:1]
            detail = f"{type(error).__name__}: {first[0]}" if first else type(error).__name__
            session.shouldstop = (
                f"{fixturedef.scope}-scoped fixture '{fixturedef.argname}' failed its setup "
                f"({detail}): every later test would fail on it"
            )
        raise
