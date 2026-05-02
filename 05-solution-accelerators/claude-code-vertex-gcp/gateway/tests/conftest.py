"""Shared pytest fixtures for the gateway test suite.

The rate_limit and model_policy modules read configuration from
environment variables at import time (and on explicit reload). Without
a global reset between tests, state from one test file leaks into
another — most visibly: test_model_policy.py sets ``ALLOWED_MODELS``
mid-test, the env var is cleared by monkeypatch's teardown, but the
in-memory state in app.model_policy remains until somebody calls
``reload_for_tests``.

This conftest runs an autouse fixture against every test, ensuring
both modules start from a clean slate.
"""

from __future__ import annotations

import os

import pytest


@pytest.fixture(autouse=True)
def _reset_gateway_state(monkeypatch):
    """Reset rate_limit and model_policy state before AND after every test."""
    # Belt-and-braces: also delete any env vars they read, in case a test
    # leaks one without using monkeypatch.
    _TRAFFIC_VARS = (
        "RATE_LIMIT_PER_MIN",
        "RATE_LIMIT_BURST",
        "ALLOWED_MODELS",
        "MODEL_REWRITE",
        "TOKEN_LIMIT_PER_MIN",
        "TOKEN_LIMIT_BURST",
    )
    for var in _TRAFFIC_VARS:
        os.environ.pop(var, None)

    # Lazily import — these aren't available until the gateway package
    # is on PYTHONPATH, which happens when tests run from the gateway/
    # directory.
    from app import model_policy, rate_limit, token_limit

    rate_limit.reset_for_tests()
    token_limit.reset_for_tests()
    model_policy.reload_for_tests()

    yield

    for var in _TRAFFIC_VARS:
        os.environ.pop(var, None)
    rate_limit.reset_for_tests()
    token_limit.reset_for_tests()
    model_policy.reload_for_tests()
