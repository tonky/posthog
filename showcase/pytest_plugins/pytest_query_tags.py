"""pytest plugin: each test starts with posthog's base ClickHouse query tags.

`posthog.clickhouse.query_tagging.query_tags` is a process-wide contextvar. Code under test
tags it without restoring (`ee/billing/quota_limiting.py` sets `product=BILLING`), and
`tags_context` copies the ambient tags, so a later test in the same process inherits them:
`test_execute.py::test_process_query_task_workload_routing` then routes to the BILLING
ClickHouse user. Upstream's jobs happen to run those files in different processes; a packed
or re-selected shard can put them in one. Resetting before each test makes the order moot.
"""

import pytest


@pytest.fixture(scope="module", autouse=True)
def _restore_structlog_config_per_module():
    """Restore process-wide structlog configuration after each module so module-scoped
    Temporal `configure_logger_auto` fixtures never leak `WrapperLogger` into later modules."""
    try:
        import structlog
    except ImportError:
        yield
        return
    previous_config = structlog.get_config()
    previously_configured = structlog.is_configured()
    yield
    if previously_configured:
        structlog.configure(**previous_config)
    else:
        structlog.reset_defaults()


@pytest.fixture(autouse=True)
def _reset_posthog_query_tags():
    try:
        from posthog.clickhouse.query_tagging import reset_query_tags
    except ImportError:
        yield
        return
    reset_query_tags()
    yield
