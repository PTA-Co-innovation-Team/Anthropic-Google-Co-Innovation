"""Unit tests for the model allowlist + rewrite policy."""

from __future__ import annotations

import pytest

from app import model_policy


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for var in ("ALLOWED_MODELS", "MODEL_REWRITE"):
        monkeypatch.delenv(var, raising=False)
    model_policy.reload_for_tests()
    yield
    model_policy.reload_for_tests()


# --- extract_model ---------------------------------------------------------

def test_extract_model_from_path():
    p = "/v1/projects/p/locations/global/publishers/anthropic/models/claude-haiku-4-5:rawPredict"
    assert model_policy.extract_model(p) == "claude-haiku-4-5"


def test_extract_model_returns_none_for_non_model_path():
    assert model_policy.extract_model("/v1/projects/p/locations") is None


# --- allowlist -------------------------------------------------------------

def test_no_allowlist_means_everything_allowed():
    assert not model_policy.has_allowlist()
    assert model_policy.is_model_allowed("claude-opus-4-6") is True
    assert model_policy.is_model_allowed("anything-else") is True


def test_allowlist_admits_listed_model(monkeypatch):
    monkeypatch.setenv(
        "ALLOWED_MODELS", "claude-haiku-4-5,claude-sonnet-4-6"
    )
    model_policy.reload_for_tests()
    assert model_policy.has_allowlist()
    assert model_policy.is_model_allowed("claude-haiku-4-5") is True
    assert model_policy.is_model_allowed("claude-sonnet-4-6") is True


def test_allowlist_blocks_unlisted_model(monkeypatch):
    monkeypatch.setenv("ALLOWED_MODELS", "claude-haiku-4-5")
    model_policy.reload_for_tests()
    assert model_policy.is_model_allowed("claude-opus-4-6") is False


def test_allowlist_admits_when_no_model_in_path(monkeypatch):
    """Non-model paths (Vertex listing, etc.) bypass the allowlist."""
    monkeypatch.setenv("ALLOWED_MODELS", "claude-haiku-4-5")
    model_policy.reload_for_tests()
    assert model_policy.is_model_allowed(None) is True


def test_allowlist_versioned_model_string(monkeypatch):
    """Version-suffixed models match exactly."""
    monkeypatch.setenv(
        "ALLOWED_MODELS", "claude-haiku-4-5@20251001,claude-sonnet-4-6"
    )
    model_policy.reload_for_tests()
    assert model_policy.is_model_allowed("claude-haiku-4-5@20251001") is True
    # Non-versioned haiku is NOT in the allowlist:
    assert model_policy.is_model_allowed("claude-haiku-4-5") is False


# --- rewrite ---------------------------------------------------------------

def test_no_rewrite_means_path_unchanged():
    p = "/v1/projects/p/locations/global/publishers/anthropic/models/claude-opus-4-6:rawPredict"
    new_path, dst = model_policy.apply_rewrite(p)
    assert new_path == p
    assert dst is None


def test_rewrite_replaces_model_in_path(monkeypatch):
    monkeypatch.setenv(
        "MODEL_REWRITE", "claude-opus-4-6=claude-sonnet-4-6"
    )
    model_policy.reload_for_tests()
    p = "/v1/projects/p/locations/global/publishers/anthropic/models/claude-opus-4-6:rawPredict"
    new_path, dst = model_policy.apply_rewrite(p)
    assert dst == "claude-sonnet-4-6"
    assert "/models/claude-sonnet-4-6:rawPredict" in new_path
    assert "/models/claude-opus-4-6" not in new_path


def test_rewrite_only_applies_to_configured_source(monkeypatch):
    monkeypatch.setenv(
        "MODEL_REWRITE", "claude-opus-4-6=claude-sonnet-4-6"
    )
    model_policy.reload_for_tests()
    p = "/v1/projects/p/locations/global/publishers/anthropic/models/claude-haiku-4-5:rawPredict"
    new_path, dst = model_policy.apply_rewrite(p)
    assert new_path == p
    assert dst is None


def test_rewrite_handles_multiple_rules(monkeypatch):
    monkeypatch.setenv(
        "MODEL_REWRITE",
        "claude-opus-4-6=claude-sonnet-4-6,claude-sonnet-4-6=claude-haiku-4-5",
    )
    model_policy.reload_for_tests()
    p_opus = "/v1/.../publishers/anthropic/models/claude-opus-4-6:rawPredict"
    p_sonnet = "/v1/.../publishers/anthropic/models/claude-sonnet-4-6:rawPredict"
    _, dst1 = model_policy.apply_rewrite(p_opus)
    _, dst2 = model_policy.apply_rewrite(p_sonnet)
    assert dst1 == "claude-sonnet-4-6"
    assert dst2 == "claude-haiku-4-5"


def test_rewrite_drops_malformed_entries(monkeypatch):
    monkeypatch.setenv(
        "MODEL_REWRITE", "good=ok,no-equals,empty-key=,=empty-value"
    )
    model_policy.reload_for_tests()
    # Only "good=ok" survives.
    assert model_policy.has_rewrite()
    p = "/v1/.../publishers/anthropic/models/good:rawPredict"
    _, dst = model_policy.apply_rewrite(p)
    assert dst == "ok"


def test_rewrite_then_allowlist_admits(monkeypatch):
    """Rewrite happens before allowlist; rewritten target must be allowed."""
    monkeypatch.setenv("MODEL_REWRITE", "claude-opus-4-6=claude-sonnet-4-6")
    monkeypatch.setenv("ALLOWED_MODELS", "claude-sonnet-4-6")
    model_policy.reload_for_tests()
    p = "/v1/.../publishers/anthropic/models/claude-opus-4-6:rawPredict"
    new_path, dst = model_policy.apply_rewrite(p)
    assert dst == "claude-sonnet-4-6"
    # The rewritten model is allowed:
    assert model_policy.is_model_allowed(model_policy.extract_model(new_path)) is True
