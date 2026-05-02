"""Unit tests for the token-cap limiter (input + output)."""

from __future__ import annotations

import pytest

from app import token_limit


def test_disabled_by_default():
    assert token_limit.is_enabled() is False
    assert token_limit.check_pre_charge("alice@x.com", 1000) is None


def test_pre_charge_admits_when_under_bucket(monkeypatch):
    monkeypatch.setenv("TOKEN_LIMIT_PER_MIN", "10000")
    monkeypatch.setenv("TOKEN_LIMIT_BURST", "10000")
    token_limit.reset_for_tests()
    assert token_limit.check_pre_charge("alice@x.com", 5000) is None


def test_pre_charge_blocks_when_input_exceeds_bucket(monkeypatch):
    monkeypatch.setenv("TOKEN_LIMIT_PER_MIN", "10000")
    monkeypatch.setenv("TOKEN_LIMIT_BURST", "10000")
    token_limit.reset_for_tests()
    retry = token_limit.check_pre_charge("alice@x.com", 50000)
    assert retry is not None and retry > 0


def test_post_charge_debits_bucket(monkeypatch):
    monkeypatch.setenv("TOKEN_LIMIT_PER_MIN", "10000")
    monkeypatch.setenv("TOKEN_LIMIT_BURST", "10000")
    token_limit.reset_for_tests()
    # Pre-check passes (small input)
    assert token_limit.check_pre_charge("alice@x.com", 100) is None
    # Response actually consumed 9000 tokens (input + output)
    token_limit.debit_post_response("alice@x.com", 9000)
    # Next request with 2000 input is blocked (only ~1000 left in bucket)
    retry = token_limit.check_pre_charge("alice@x.com", 2000)
    assert retry is not None and retry > 0


def test_post_charge_can_go_negative(monkeypatch):
    """A request that consumed more than bucket is debited fully; bucket goes negative."""
    monkeypatch.setenv("TOKEN_LIMIT_PER_MIN", "10000")
    monkeypatch.setenv("TOKEN_LIMIT_BURST", "10000")
    token_limit.reset_for_tests()
    token_limit.check_pre_charge("alice@x.com", 100)  # pass
    token_limit.debit_post_response("alice@x.com", 50000)  # 5x bucket
    # Now even a 100-token request is blocked
    retry = token_limit.check_pre_charge("alice@x.com", 100)
    assert retry is not None and retry > 0


def test_per_caller_isolation(monkeypatch):
    monkeypatch.setenv("TOKEN_LIMIT_PER_MIN", "10000")
    monkeypatch.setenv("TOKEN_LIMIT_BURST", "10000")
    token_limit.reset_for_tests()
    # alice burns through her bucket
    token_limit.check_pre_charge("alice@x.com", 100)
    token_limit.debit_post_response("alice@x.com", 50000)
    assert token_limit.check_pre_charge("alice@x.com", 100) is not None
    # bob has his own bucket
    assert token_limit.check_pre_charge("bob@x.com", 5000) is None


def test_invalid_env_disables(monkeypatch):
    monkeypatch.setenv("TOKEN_LIMIT_PER_MIN", "not-a-number")
    token_limit.reset_for_tests()
    assert token_limit.is_enabled() is False


def test_burst_independent_of_per_min(monkeypatch):
    monkeypatch.setenv("TOKEN_LIMIT_PER_MIN", "10000")
    monkeypatch.setenv("TOKEN_LIMIT_BURST", "30000")
    token_limit.reset_for_tests()
    # Should admit a burst up to 30k even though refill is 10k/min
    assert token_limit.check_pre_charge("alice@x.com", 25000) is None


def test_bucket_refills_over_time(monkeypatch):
    """After waiting, tokens regenerate."""
    monkeypatch.setenv("TOKEN_LIMIT_PER_MIN", "60000")  # 1000 tokens / sec
    monkeypatch.setenv("TOKEN_LIMIT_BURST", "1000")
    token_limit.reset_for_tests()
    token_limit.check_pre_charge("alice@x.com", 100)
    token_limit.debit_post_response("alice@x.com", 5000)  # bucket goes negative
    assert token_limit.check_pre_charge("alice@x.com", 100) is not None

    # Advance the clock 5 seconds → 5000 more tokens refilled.
    real_now = token_limit._now()
    fake_now = [real_now + 5.0]
    monkeypatch.setattr(token_limit, "_now", lambda: fake_now[0])
    assert token_limit.check_pre_charge("alice@x.com", 100) is None


def test_estimate_input_tokens_heuristic():
    body = b'{"messages":[{"role":"user","content":"hello world"}]}'
    n = token_limit.estimate_input_tokens_from_body(body)
    # At ~4 chars/token, this body is ~12 tokens
    assert 5 <= n <= 25


def test_estimate_handles_empty():
    assert token_limit.estimate_input_tokens_from_body(b"") == 0


def test_debit_when_disabled_is_noop(monkeypatch):
    """When TOKEN_LIMIT_PER_MIN is unset, debit() should silently do nothing."""
    token_limit.reset_for_tests()
    # Should not raise
    token_limit.debit_post_response("alice@x.com", 99999)
    # And bucket dict stays empty
    assert len(token_limit._BUCKETS) == 0
