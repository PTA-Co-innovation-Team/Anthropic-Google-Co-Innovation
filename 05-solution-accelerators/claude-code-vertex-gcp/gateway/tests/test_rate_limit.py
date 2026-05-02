"""Unit tests for the per-caller rate limiter."""

from __future__ import annotations

import os
import time

import pytest

from app import rate_limit


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    """Each test starts from a clean module state."""
    for var in ("RATE_LIMIT_PER_MIN", "RATE_LIMIT_BURST"):
        monkeypatch.delenv(var, raising=False)
    rate_limit.reset_for_tests()
    yield
    rate_limit.reset_for_tests()


def test_disabled_by_default():
    assert rate_limit.is_enabled() is False
    assert rate_limit.check_and_consume("alice@example.com") is None


def test_enable_and_admit_first_requests(monkeypatch):
    monkeypatch.setenv("RATE_LIMIT_PER_MIN", "60")
    rate_limit.reset_for_tests()
    assert rate_limit.is_enabled()
    # Burst defaults to PER_MIN, so first 60 requests should pass.
    for _ in range(60):
        assert rate_limit.check_and_consume("alice@example.com") is None


def test_429_after_bucket_drained(monkeypatch):
    monkeypatch.setenv("RATE_LIMIT_PER_MIN", "5")
    monkeypatch.setenv("RATE_LIMIT_BURST", "5")
    rate_limit.reset_for_tests()
    for _ in range(5):
        assert rate_limit.check_and_consume("alice@example.com") is None
    retry = rate_limit.check_and_consume("alice@example.com")
    assert retry is not None
    assert retry > 0


def test_per_caller_isolation(monkeypatch):
    monkeypatch.setenv("RATE_LIMIT_PER_MIN", "2")
    monkeypatch.setenv("RATE_LIMIT_BURST", "2")
    rate_limit.reset_for_tests()
    # alice exhausts hers
    assert rate_limit.check_and_consume("alice@example.com") is None
    assert rate_limit.check_and_consume("alice@example.com") is None
    assert rate_limit.check_and_consume("alice@example.com") is not None
    # bob has his own bucket
    assert rate_limit.check_and_consume("bob@example.com") is None
    assert rate_limit.check_and_consume("bob@example.com") is None
    assert rate_limit.check_and_consume("bob@example.com") is not None


def test_burst_independent_of_per_min(monkeypatch):
    """A larger BURST than PER_MIN should allow short spikes."""
    monkeypatch.setenv("RATE_LIMIT_PER_MIN", "60")
    monkeypatch.setenv("RATE_LIMIT_BURST", "120")
    rate_limit.reset_for_tests()
    for _ in range(120):
        assert rate_limit.check_and_consume("alice@example.com") is None
    # 121st blocks
    assert rate_limit.check_and_consume("alice@example.com") is not None


def test_bucket_refills_over_time(monkeypatch):
    """After waiting, tokens regenerate."""
    monkeypatch.setenv("RATE_LIMIT_PER_MIN", "60")  # 1 token / sec
    monkeypatch.setenv("RATE_LIMIT_BURST", "1")
    rate_limit.reset_for_tests()
    assert rate_limit.check_and_consume("alice@example.com") is None
    assert rate_limit.check_and_consume("alice@example.com") is not None
    # Patch time to advance 1 second.
    real_now = rate_limit._now()
    fake = [real_now + 1.5]
    monkeypatch_now = lambda: fake[0]  # noqa: E731
    monkeypatch.setattr(rate_limit, "_now", monkeypatch_now)
    assert rate_limit.check_and_consume("alice@example.com") is None


def test_invalid_env_disables(monkeypatch):
    monkeypatch.setenv("RATE_LIMIT_PER_MIN", "not-a-number")
    rate_limit.reset_for_tests()
    assert rate_limit.is_enabled() is False
    assert rate_limit.check_and_consume("alice@example.com") is None


def test_retry_after_is_positive_integer_lower_bound(monkeypatch):
    """Retry-After should never be < 1."""
    monkeypatch.setenv("RATE_LIMIT_PER_MIN", "1000")
    monkeypatch.setenv("RATE_LIMIT_BURST", "1")
    rate_limit.reset_for_tests()
    rate_limit.check_and_consume("alice@example.com")
    retry = rate_limit.check_and_consume("alice@example.com")
    assert retry is not None and retry >= 1.0
