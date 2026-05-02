"""Model allowlist and rewrite policy for the LLM Gateway.

Two independent controls, both off by default:

* **Allowlist** (``ALLOWED_MODELS``) — comma-separated list of Anthropic
  model names that the gateway will forward. Requests for any other
  model return ``403 Forbidden`` with a structured error body. Use
  this to cap which models a team can use (cost control, compliance).

* **Rewrite** (``MODEL_REWRITE``) — comma-separated list of
  ``from=to`` pairs. When a request specifies ``from``, the gateway
  rewrites the URL to target ``to`` instead. Useful for emergency
  cost-cuts ("force everyone off Opus to Sonnet") or for migrating a
  team off a deprecated model without touching laptops.

Order: rewrite happens BEFORE allowlist. So you can rewrite Opus to
Sonnet AND only allow Sonnet, and the rewritten request will pass.

Both controls operate on the model name as it appears in the URL path
(``/publishers/anthropic/models/<model>:rawPredict``). The model name
typically contains a version qualifier (``claude-opus-4-6``,
``claude-haiku-4-5@20251001``); for simplicity, the matcher is exact
on the full model string. Customers who want loose matching ("any
opus") can list every variant they expect.

Example deployment configuration::

    ALLOWED_MODELS=claude-sonnet-4-6,claude-haiku-4-5,claude-haiku-4-5@20251001
    MODEL_REWRITE=claude-opus-4-6=claude-sonnet-4-6
"""

from __future__ import annotations

import logging
import os
import re
from typing import Optional

log = logging.getLogger(__name__)


# Same regex as proxy.py — single source of truth would be nicer but
# importing across the module would create a cycle.
_MODEL_IN_PATH = re.compile(r"/publishers/anthropic/models/([^:/]+)")


def _parse_csv(value: str) -> list[str]:
    """Split a CSV env value into a clean list, dropping empties."""
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


def _parse_rewrite(value: str) -> dict[str, str]:
    """Parse ``from=to,from2=to2`` syntax into a dict.

    Malformed entries (no ``=``, empty key, or empty value) are dropped
    with a warning so deployment doesn't fail on a typo.
    """
    out: dict[str, str] = {}
    for entry in _parse_csv(value):
        if "=" not in entry:
            log.warning("model_policy.bad_rewrite_entry value=%r — missing '='", entry)
            continue
        src, _, dst = entry.partition("=")
        src, dst = src.strip(), dst.strip()
        if not src or not dst:
            log.warning("model_policy.bad_rewrite_entry value=%r — empty side", entry)
            continue
        out[src] = dst
    return out


# Read once at import time. Cloud Run revisions are immutable in this
# respect; tests use the test-only ``reload_for_tests`` helper.
_ALLOWED: frozenset[str] = frozenset(_parse_csv(os.getenv("ALLOWED_MODELS", "")))
_REWRITE: dict[str, str] = _parse_rewrite(os.getenv("MODEL_REWRITE", ""))


def has_allowlist() -> bool:
    """Return True if a non-empty allowlist is configured."""
    return bool(_ALLOWED)


def has_rewrite() -> bool:
    """Return True if any rewrite rules are configured."""
    return bool(_REWRITE)


def extract_model(path: str) -> Optional[str]:
    """Pull the model name out of a Vertex URL path, if present."""
    m = _MODEL_IN_PATH.search(path)
    return m.group(1) if m else None


def apply_rewrite(path: str) -> tuple[str, Optional[str]]:
    """Rewrite the model in the URL path, if a rule applies.

    Args:
        path: Inbound request path.

    Returns:
        ``(new_path, rewritten_to)`` — ``new_path`` is the path after
        rewrite (same as input if no rule applied), and
        ``rewritten_to`` is the destination model name (``None`` if no
        rewrite happened, useful for logging).
    """
    if not _REWRITE:
        return path, None
    src = extract_model(path)
    if src is None:
        return path, None
    dst = _REWRITE.get(src)
    if dst is None:
        return path, None
    # Replace just the model segment. The capture group above guarantees
    # the model is the segment after ``/models/``.
    new_path = _MODEL_IN_PATH.sub(
        f"/publishers/anthropic/models/{dst}", path, count=1
    )
    return new_path, dst


def is_model_allowed(model: Optional[str]) -> bool:
    """Check a model against the allowlist.

    A request with no recognisable model in its path is allowed — the
    gateway still forwards non-model paths (Vertex listing, etc.) and
    Vertex itself decides what's valid.
    """
    if not _ALLOWED:
        return True
    if model is None:
        return True
    return model in _ALLOWED


def reload_for_tests() -> None:
    """Re-read env vars. Test-only helper; production code never calls this."""
    global _ALLOWED, _REWRITE
    _ALLOWED = frozenset(_parse_csv(os.getenv("ALLOWED_MODELS", "")))
    _REWRITE = _parse_rewrite(os.getenv("MODEL_REWRITE", ""))
