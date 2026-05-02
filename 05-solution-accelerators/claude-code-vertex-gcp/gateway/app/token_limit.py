"""Per-caller LLM-token cap (input + output combined).

Sister module to ``rate_limit.py``. Where ``rate_limit`` counts HTTP
requests, this counts the actual model tokens — the unit Vertex bills
on and the one customers care about for budget control.

Trade-offs vs counting requests:

* **+** Fair: a developer sending 5 huge-context requests pays the
  same as one sending 5 small ones.
* **+** Tracks real cost driver: tokens, not requests.
* **−** Output tokens are only known *after* the response, so the
  bucket is debited post-hoc. The first violator gets through; the
  next request from that caller is blocked. This is the same trade-off
  every streaming-LLM gateway makes (Apigee, Kong, etc.).

Configuration (all unset = disabled):

* ``TOKEN_LIMIT_PER_MIN`` — combined input+output tokens per minute
  per caller.
* ``TOKEN_LIMIT_BURST`` — max bucket capacity (defaults to PER_MIN).

When a caller is over their limit, the gateway returns 429 with a
``Retry-After`` header. Subsequent requests are blocked until enough
tokens have refilled.
"""

from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass
from typing import Optional

import cachetools

log = logging.getLogger(__name__)


@dataclass
class _Bucket:
    tokens: float
    last_refill: float


_BUCKETS: cachetools.LRUCache[str, _Bucket] = cachetools.LRUCache(maxsize=4096)


def _read_int_env(name: str, default: int = 0) -> int:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        log.warning("token_limit.bad_env name=%s value=%r — treating as disabled", name, raw)
        return default


_PER_MIN: int = _read_int_env("TOKEN_LIMIT_PER_MIN", 0)
_BURST: int = _read_int_env("TOKEN_LIMIT_BURST", _PER_MIN)
_REFILL_PER_SEC: float = _PER_MIN / 60.0


def is_enabled() -> bool:
    return _PER_MIN > 0


def _now() -> float:
    return time.monotonic()


def _ensure_bucket(caller: str) -> _Bucket:
    """Get-or-create a bucket; idempotent."""
    bucket = _BUCKETS.get(caller)
    if bucket is None:
        bucket = _Bucket(tokens=float(_BURST), last_refill=_now())
        _BUCKETS[caller] = bucket
    return bucket


def _refill(bucket: _Bucket) -> None:
    """Add tokens accumulated since last refill, capped at _BURST."""
    now = _now()
    elapsed = now - bucket.last_refill
    if elapsed > 0:
        bucket.tokens = min(float(_BURST), bucket.tokens + elapsed * _REFILL_PER_SEC)
        bucket.last_refill = now


def check_pre_charge(caller: str, estimated_input_tokens: int) -> Optional[float]:
    """Pre-flight check before forwarding to Vertex.

    Looks at the bucket and the input-token estimate. If the bucket
    has fewer tokens than the estimate, reject 429 BEFORE we send the
    request upstream — saves the cost of a Vertex call we'd otherwise
    have to charge for.

    Args:
        caller: Identity (typically email).
        estimated_input_tokens: Best-effort input-token count derived
            from the request body. See proxy.py for how this is
            estimated.

    Returns:
        ``None`` if the request should be admitted; otherwise the
        seconds-until-retry to populate ``Retry-After``.
    """
    if not is_enabled():
        return None

    key = caller or "<anon>"
    bucket = _ensure_bucket(key)
    _refill(bucket)

    if bucket.tokens >= float(estimated_input_tokens):
        # Don't debit yet — actual debit happens post-response with
        # exact input + output counts. We only block here when the
        # input alone already exceeds the bucket.
        return None

    deficit = float(estimated_input_tokens) - bucket.tokens
    wait = deficit / _REFILL_PER_SEC if _REFILL_PER_SEC > 0 else 60.0
    return max(1.0, wait)


def debit_post_response(caller: str, total_tokens: int) -> None:
    """Debit the bucket after the response has completed.

    Called once Vertex's response is fully received and the actual
    ``usage`` field has been parsed. ``total_tokens`` should be
    ``input_tokens + output_tokens`` from that response.

    The bucket can go *negative* — that's expected and intentional.
    A caller who consumed 80k tokens with a bucket of 50k now has
    -30k tokens, which means their next request is blocked until
    refill catches up. No data loss; over-the-line by exactly one
    request.
    """
    if not is_enabled():
        return
    key = caller or "<anon>"
    bucket = _ensure_bucket(key)
    _refill(bucket)
    bucket.tokens -= float(total_tokens)
    # Don't bother flooring at zero — the negative balance is what
    # makes the next-request rejection work correctly.


def estimate_input_tokens_from_body(body: bytes) -> int:
    """Rough input-token estimate from a JSON request body.

    We don't ship a tokenizer (Anthropic's Claude tokenizer isn't in
    the standard Python distribution). Instead we use the well-known
    "~4 chars per token" heuristic on the user-visible content.

    For the bucket-check use case this is fine: we only need to know
    whether the request is small enough to admit. The exact debit
    happens post-response with Vertex's authoritative count.
    """
    # Cheap heuristic: 1 token ≈ 4 chars of UTF-8 text.
    # Strip JSON overhead by approximating: total chars / 4 - 10%.
    if not body:
        return 0
    n_chars = len(body)
    return max(1, int(n_chars * 0.9 / 4))


def reset_for_tests() -> None:
    """Re-read env, clear buckets. Test-only."""
    global _PER_MIN, _BURST, _REFILL_PER_SEC
    _BUCKETS.clear()
    _PER_MIN = _read_int_env("TOKEN_LIMIT_PER_MIN", 0)
    _BURST = _read_int_env("TOKEN_LIMIT_BURST", _PER_MIN)
    _REFILL_PER_SEC = _PER_MIN / 60.0
