"""Per-caller rate limiting for the LLM Gateway.

In-process token-bucket implementation. Each caller (identified by the
email that token_validation.py stashed on ``request.state``) gets their
own bucket. Buckets refill at ``RATE_LIMIT_PER_MIN`` per minute and
have a maximum burst capacity of ``RATE_LIMIT_BURST``.

When a caller's bucket is empty, the gateway returns ``429 Too Many
Requests`` with a ``Retry-After`` header set to the seconds the caller
needs to wait for one more token.

Trade-offs vs a Redis-backed implementation:

* **+** No new infrastructure, no extra cost, no extra latency.
* **+** Fails open if memory pressure forces eviction (unlikely at this
  scale).
* **−** Each Cloud Run instance keeps its own buckets, so the effective
  per-caller limit is ``RATE_LIMIT_PER_MIN × N_instances``. Acceptable
  for typical team sizes; switch to Redis if you need tight enforcement
  across hundreds of concurrent instances.

Disabled by default. Set ``RATE_LIMIT_PER_MIN`` to a positive integer to
enable. ``RATE_LIMIT_BURST`` defaults to the same value (a smooth limit
with no burst tolerance).
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
    """Token bucket state for a single caller.

    Attributes:
        tokens: Float — current token count. Capped at ``capacity``.
        last_refill: Monotonic timestamp of the last refill.
    """
    tokens: float
    last_refill: float


# LRU-eviction map of caller email → bucket. 4096 entries is plenty for
# typical deployments; the map auto-evicts the least-recently-seen
# caller when full, which means a flood of unique callers can briefly
# bypass the limit. Acceptable failure mode for this design.
_BUCKETS: cachetools.LRUCache[str, _Bucket] = cachetools.LRUCache(maxsize=4096)


def _read_int_env(name: str, default: int = 0) -> int:
    """Parse an int env var; returns ``default`` if unset, empty, or invalid."""
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        log.warning("rate_limit.bad_env name=%s value=%r — treating as disabled", name, raw)
        return default


# Read configuration at import time. Cloud Run revisions are immutable
# in this respect, and we want the cost of the env-var lookup off the
# hot path.
_PER_MIN: int = _read_int_env("RATE_LIMIT_PER_MIN", 0)
_BURST: int = _read_int_env("RATE_LIMIT_BURST", _PER_MIN)
# Refill rate, in tokens-per-second.
_REFILL_PER_SEC: float = _PER_MIN / 60.0


def is_enabled() -> bool:
    """Return True if rate limiting should run for this revision."""
    return _PER_MIN > 0


def _now() -> float:
    """Monotonic clock — never goes backwards even if wall clock changes."""
    return time.monotonic()


def check_and_consume(caller: str) -> Optional[float]:
    """Try to debit one token from this caller's bucket.

    Args:
        caller: Identifier for the caller (typically email). Empty/None
            is allowed and treated as a single global bucket; callers
            who haven't authenticated yet will share that bucket, but
            we should never reach this code for unauthenticated requests
            because token_validation runs first.

    Returns:
        ``None`` if the request was admitted (token consumed).
        Otherwise the number of seconds the caller must wait before one
        more token is available — feed this into ``Retry-After``.
    """
    if not is_enabled():
        return None

    key = caller or "<anon>"
    now = _now()

    bucket = _BUCKETS.get(key)
    if bucket is None:
        # First request from this caller in the bucket's lifetime.
        # Start with a full bucket (so first-time users aren't penalised
        # for silly bucket warmup).
        bucket = _Bucket(tokens=float(_BURST), last_refill=now)
        _BUCKETS[key] = bucket

    # Refill since last touch — capped at burst capacity.
    elapsed = now - bucket.last_refill
    if elapsed > 0:
        bucket.tokens = min(float(_BURST), bucket.tokens + elapsed * _REFILL_PER_SEC)
        bucket.last_refill = now

    if bucket.tokens >= 1.0:
        bucket.tokens -= 1.0
        return None

    # Calculate how many seconds until one full token regenerates.
    deficit = 1.0 - bucket.tokens
    wait_seconds = deficit / _REFILL_PER_SEC if _REFILL_PER_SEC > 0 else 60.0
    # Round up to the nearest second; HTTP Retry-After is integer.
    return max(1.0, wait_seconds)


def reset_for_tests() -> None:
    """Clear all buckets and re-read env config. Test-only helper.

    Production code never calls this. Tests need it because they tweak
    env vars between cases and the module-level config is otherwise
    sticky.
    """
    global _PER_MIN, _BURST, _REFILL_PER_SEC
    _BUCKETS.clear()
    _PER_MIN = _read_int_env("RATE_LIMIT_PER_MIN", 0)
    _BURST = _read_int_env("RATE_LIMIT_BURST", _PER_MIN)
    _REFILL_PER_SEC = _PER_MIN / 60.0
