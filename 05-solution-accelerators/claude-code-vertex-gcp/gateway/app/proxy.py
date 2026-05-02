"""Pass-through reverse proxy logic.

This is the core of the gateway. Given an incoming request from Claude
Code, we:

1. Compute the Vertex AI upstream URL (same path, swapped hostname).
2. Sanitize the request headers (strip Anthropic-only betas, etc.).
3. Add an ``Authorization: Bearer <token>`` header using the gateway's
   own service-account credentials — the caller's token is NOT forwarded.
4. Stream the request body through to Vertex, stream the response back.
5. Emit a structured log entry with caller, model, status, and latency.

We do **not** rewrite payloads. Claude Code emits Vertex-formatted JSON
when ``CLAUDE_CODE_USE_VERTEX=1``, and we pass it through unchanged.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import time
from typing import AsyncIterator, Optional

import httpx
from fastapi import Request
from fastapi.responses import StreamingResponse

from . import model_policy, rate_limit, token_limit
from .auth import CallerIdentity, extract_caller_identity, get_vertex_access_token
from .headers import sanitize_request_headers
from .logging_config import get_logger

log = get_logger(__name__)


# The Cloud Run region of this service. Used only for logging; has nothing
# to do with the Vertex region we call. Set automatically by Cloud Run.
_CLOUD_RUN_REGION = os.getenv("K_SERVICE_REGION") or os.getenv("GOOGLE_CLOUD_REGION", "unknown")

# Default Vertex region if the caller did not encode one in the URL path.
# "global" is the multi-region Vertex endpoint, which uses a different
# hostname from regional endpoints (see ``_vertex_host_for_region``).
_DEFAULT_VERTEX_REGION = os.getenv("VERTEX_DEFAULT_REGION", "global")

# The GCP project ID for Vertex calls. Cloud Run populates GOOGLE_CLOUD_PROJECT.
# Falls back to VERTEX_PROJECT_ID if the operator set it explicitly.
_VERTEX_PROJECT_ID = (
    os.getenv("VERTEX_PROJECT_ID")
    or os.getenv("GOOGLE_CLOUD_PROJECT")
    or ""
)


# Shared httpx client. Creating one per request would defeat connection
# pooling and keepalive. Created in main.py's lifespan hook and injected
# into functions here via the request state.
#
# The timeout is generous because Claude responses (especially with long
# contexts) can take tens of seconds. We rely on Cloud Run's own 15-minute
# request timeout as the outer bound.
DEFAULT_TIMEOUT = httpx.Timeout(
    connect=10.0,
    read=300.0,
    write=60.0,
    pool=10.0,
)


def _vertex_host_for_region(region: str) -> str:
    """Return the correct Vertex AI hostname for a given region.

    The multi-region "global" endpoint is served from the bare
    ``aiplatform.googleapis.com`` hostname. Every specific region has its
    own regional hostname.

    Args:
        region: A Vertex region string, e.g. "us-east5" or "global".

    Returns:
        Hostname suitable for use in an HTTPS URL.
    """
    if region == "global":
        return "aiplatform.googleapis.com"
    return f"{region}-aiplatform.googleapis.com"


# Paths that look like Vertex publisher calls. We use this to extract the
# model name for logging, e.g. ``.../publishers/anthropic/models/claude-opus-4-6:rawPredict``.
_MODEL_IN_PATH = re.compile(r"/publishers/anthropic/models/([^:/]+)")


def _extract_model(path: str) -> Optional[str]:
    """Pull the Anthropic model name out of a Vertex URL path, if present."""
    match = _MODEL_IN_PATH.search(path)
    return match.group(1) if match else None


def _normalize_path(path: str) -> str:
    """Ensure the path has a Vertex API version prefix.

    Claude Code omits the ``/v1/`` prefix when ``ANTHROPIC_VERTEX_BASE_URL``
    is set, sending paths like ``/projects/P/locations/R/...`` directly.
    Vertex AI requires ``/v1/projects/...``, so we prepend it if missing.
    """
    stripped = path.lstrip("/")
    if not re.match(r"v\d", stripped):
        return "/v1/" + stripped
    return "/" + stripped


def _extract_region_from_path(path: str) -> str:
    """Pull the Vertex region from a path like ``/v1/projects/<p>/locations/<r>/...``."""
    match = re.match(
        r"^/?v\d[^/]*/projects/[^/]+/locations/([^/]+)/",
        path,
    )
    if match:
        return match.group(1)
    # Also handle paths without the version prefix.
    match = re.match(
        r"^/?projects/[^/]+/locations/([^/]+)/",
        path,
    )
    if match:
        return match.group(1)
    return _DEFAULT_VERTEX_REGION


def build_upstream_url(path: str, query: str) -> str:
    """Compose the full Vertex URL for an inbound path.

    Args:
        path: Request path as seen by FastAPI, e.g.
              ``/v1/projects/my-proj/locations/us-east5/...`` or
              ``/projects/my-proj/locations/us-east5/...`` (Claude Code
              omits the version prefix with custom base URLs).
        query: Raw query string (no leading ``?``).

    Returns:
        The fully-qualified Vertex URL with the correct regional host.
    """
    region = _extract_region_from_path(path)
    host = _vertex_host_for_region(region)
    clean_path = _normalize_path(path)

    url = f"https://{host}{clean_path}"
    if query:
        url = f"{url}?{query}"
    return url


async def _iter_upstream(response: httpx.Response) -> AsyncIterator[bytes]:
    """Yield the upstream response body chunk by chunk.

    Using an async iterator here lets us stream very large responses
    (Claude with long output + thinking tokens) back to the client without
    buffering the whole thing in memory.
    """
    async for chunk in response.aiter_raw():
        yield chunk


def _extract_usage_from_body(body: bytes) -> tuple[Optional[int], Optional[int]]:
    """Pull (input_tokens, output_tokens) out of a Vertex response body.

    Vertex returns two response shapes:

    * **Non-streaming JSON** (rawPredict): a single JSON object with a
      top-level ``usage`` field — ``{"input_tokens": ..., "output_tokens": ...}``.
    * **Streaming SSE** (streamRawPredict): a stream of ``data: {...}``
      lines. The final ``message_delta`` event carries
      ``usage`` with the cumulative output count and ``message_start``
      carries ``input_tokens``. We aggregate.

    Vertex frequently gzip-encodes the response body even when the
    gateway sends no Accept-Encoding header. ``aiter_raw()`` yields
    the on-wire gzip bytes, so we must decompress here before parsing.

    Returns ``(None, None)`` if we can't parse — the gateway must not
    crash because of an unexpected response shape; we just skip the
    debit and rely on operator alerting.
    """
    if not body:
        return None, None

    # Detect gzip via magic bytes (0x1f 0x8b) and decompress.
    if len(body) >= 2 and body[0] == 0x1F and body[1] == 0x8B:
        try:
            import gzip
            body = gzip.decompress(body)
        except Exception:
            log.debug("usage_gzip_decode_failed", exc_info=True)
            return None, None

    # Try non-streaming JSON first (fastest path).
    try:
        obj = json.loads(body)
        usage = obj.get("usage") if isinstance(obj, dict) else None
        if isinstance(usage, dict):
            return (
                usage.get("input_tokens"),
                usage.get("output_tokens"),
            )
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError):
        pass

    # Streaming SSE — parse "data: {...}" lines, look for usage in any.
    input_tokens: Optional[int] = None
    output_tokens: Optional[int] = None
    try:
        text = body.decode("utf-8", errors="replace")
        for line in text.splitlines():
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if not payload or payload == "[DONE]":
                continue
            try:
                event = json.loads(payload)
            except json.JSONDecodeError:
                continue
            # message_start: {"message": {"usage": {"input_tokens": N}}}
            msg = event.get("message")
            if isinstance(msg, dict):
                u = msg.get("usage")
                if isinstance(u, dict):
                    if input_tokens is None and "input_tokens" in u:
                        input_tokens = u["input_tokens"]
                    if "output_tokens" in u:
                        output_tokens = u["output_tokens"]
            # message_delta: {"usage": {"output_tokens": M}} (cumulative)
            u = event.get("usage")
            if isinstance(u, dict):
                if input_tokens is None and "input_tokens" in u:
                    input_tokens = u["input_tokens"]
                if "output_tokens" in u:
                    output_tokens = u["output_tokens"]
    except Exception:
        log.debug("usage_parse_failed", exc_info=True)

    return input_tokens, output_tokens


async def _tee_and_debit(
    response: httpx.Response,
    caller_email: str,
) -> AsyncIterator[bytes]:
    """Stream the upstream response to the client AND capture bytes for usage.

    The capture buffer is only used to parse Vertex's ``usage`` field
    after the stream completes. We do not delay the client; bytes are
    yielded as they arrive. The post-stream debit is best-effort — if
    the parse fails or the response was truncated, we skip the debit
    rather than risk over- or under-charging.

    Memory: capped buffer (we keep at most ~256KB). Larger responses
    typically still have ``usage`` in the message_delta near the
    beginning of the stream; for non-streaming JSON the body is
    bounded by Vertex's per-call response cap (well under 256KB).
    """
    captured = bytearray()
    # 1 MB is enough for the largest Vertex responses we've seen in practice
    # (typically under 200KB even gzip-decompressed). Bounded to protect
    # memory at scale; truncated gzip will fail the parse and skip the debit
    # — acceptable degradation.
    cap = 1024 * 1024
    try:
        async for chunk in response.aiter_raw():
            if len(captured) < cap:
                # Bound buffer growth so a streamed multi-MB response
                # doesn't blow memory just to capture usage tokens.
                captured.extend(chunk[: cap - len(captured)])
            yield chunk
    finally:
        # Stream done (success or client disconnect). Best-effort debit.
        if token_limit.is_enabled() and caller_email:
            try:
                in_tok, out_tok = _extract_usage_from_body(bytes(captured))
                total = (in_tok or 0) + (out_tok or 0)
                if total > 0:
                    token_limit.debit_post_response(caller_email, total)
                    log.info(
                        "token_debit",
                        extra={
                            "caller": caller_email,
                            "input_tokens": in_tok,
                            "output_tokens": out_tok,
                            "total_tokens": total,
                        },
                    )
            except Exception:
                log.warning("token_debit_failed", exc_info=True)


async def proxy_request(
    request: Request,
    client: httpx.AsyncClient,
) -> StreamingResponse:
    """Forward one inbound request to Vertex AI and stream the response back.

    Args:
        request: The FastAPI request. We read body, headers, path, query.
        client: A shared ``httpx.AsyncClient`` (created in app lifespan).

    Returns:
        A ``StreamingResponse`` that proxies the upstream body to the client.
    """
    started = time.monotonic()

    # --- Inspect the inbound request (for logging) -------------------------
    caller = extract_caller_identity(
        {k.lower(): v for k, v in request.headers.items()}
    )
    if caller.email is None and hasattr(request.state, "caller_email"):
        caller = CallerIdentity(
            email=request.state.caller_email,
            source=getattr(request.state, "caller_source", "token_validation"),
        )

    # --- Per-caller rate limiting (off unless RATE_LIMIT_PER_MIN > 0) ------
    # Runs immediately after caller identity is known so 429s are emitted
    # without paying the cost of upstream URL construction or body reads.
    retry_after = rate_limit.check_and_consume(caller.email or "")
    if retry_after is not None:
        log.warning(
            "rate_limited",
            extra={"caller": caller.email, "retry_after_s": int(retry_after)},
        )
        return StreamingResponse(
            iter([b'{"error":"rate_limited","detail":"too many requests"}']),
            status_code=429,
            headers={"Retry-After": str(int(retry_after)),
                     "Content-Type": "application/json"},
        )

    # --- Per-caller token cap pre-check (off unless TOKEN_LIMIT_PER_MIN > 0) ---
    # We need the body for the input-token estimate, so this is the
    # earliest place we can check. Read body once, reuse below.
    body = await request.body()
    if token_limit.is_enabled():
        est_input = token_limit.estimate_input_tokens_from_body(body)
        token_retry = token_limit.check_pre_charge(caller.email or "", est_input)
        if token_retry is not None:
            log.warning(
                "token_limited",
                extra={
                    "caller": caller.email,
                    "estimated_input_tokens": est_input,
                    "retry_after_s": int(token_retry),
                },
            )
            return StreamingResponse(
                iter([b'{"error":"token_limited","detail":"per-caller token cap exceeded"}']),
                status_code=429,
                headers={"Retry-After": str(int(token_retry)),
                         "Content-Type": "application/json"},
            )

    # --- Model policy: rewrite first, then allowlist -----------------------
    inbound_path = request.url.path
    rewritten_path, rewritten_to = model_policy.apply_rewrite(inbound_path)
    effective_path = rewritten_path
    model = _extract_model(effective_path)
    region = _extract_region_from_path(effective_path)

    if not model_policy.is_model_allowed(model):
        log.warning(
            "model_not_allowed",
            extra={"caller": caller.email, "model": model},
        )
        return StreamingResponse(
            iter([
                f'{{"error":"model_not_allowed","detail":"model {model} is not in ALLOWED_MODELS"}}'.encode()
            ]),
            status_code=403,
            headers={"Content-Type": "application/json"},
        )

    # --- Sanitize headers and add gateway auth -----------------------------
    cleaned, stripped = sanitize_request_headers(
        [(k, v) for k, v in request.headers.items()]
    )
    token = await asyncio.to_thread(get_vertex_access_token)
    cleaned["Authorization"] = f"Bearer {token}"

    # --- Build upstream URL ------------------------------------------------
    url = build_upstream_url(effective_path, request.url.query)

    # --- Read body ---------------------------------------------------------
    # Body was already read above (the token-cap block reads it
    # unconditionally so it's always available here).

    # --- Forward -----------------------------------------------------------
    # httpx ``stream`` returns an async context manager around a response
    # whose body has not been fully read; we pass that streaming body back
    # to the client, so the client sees Vertex's bytes as they arrive.
    req = client.build_request(
        method=request.method,
        url=url,
        headers=cleaned,
        content=body,
    )
    upstream = await client.send(req, stream=True)

    elapsed_ms = int((time.monotonic() - started) * 1000)
    log.info(
        "proxy_request",
        extra={
            "caller": caller.email,
            "caller_source": caller.source,
            "method": request.method,
            "path": request.url.path,
            "upstream_host": url.split("/", 3)[2],
            "vertex_region": region,
            "model": model,
            "status_code": upstream.status_code,
            "latency_ms_to_headers": elapsed_ms,
            "betas_stripped": [h for h in stripped if h.startswith("anthropic-beta")],
            "cloud_run_region": _CLOUD_RUN_REGION,
            "project_id": _VERTEX_PROJECT_ID,
            "model_rewritten_to": rewritten_to,
        },
    )

    # --- Relay response ----------------------------------------------------
    # Strip hop-by-hop and framing headers that Starlette recomputes.
    # ``content-encoding`` is intentionally preserved so the client can
    # decode compressed payloads returned by Vertex.
    response_headers = {
        k: v
        for k, v in upstream.headers.items()
        if k.lower() not in {"transfer-encoding", "connection", "content-length"}
    }

    # Use the tee-and-debit iterator only when token-cap is on AND the
    # upstream returned 2xx. Non-2xx responses don't have usage data
    # to debit, and we want to avoid the buffering overhead when the
    # cap is disabled.
    if token_limit.is_enabled() and 200 <= upstream.status_code < 300:
        body_iter = _tee_and_debit(upstream, caller.email or "")
    else:
        body_iter = _iter_upstream(upstream)

    return StreamingResponse(
        body_iter,
        status_code=upstream.status_code,
        headers=response_headers,
        background=_make_close_task(upstream),
    )


def _make_close_task(upstream: httpx.Response):
    """Wrap the upstream close in a Starlette ``BackgroundTask``.

    Starlette's ``StreamingResponse`` accepts a ``BackgroundTask`` that
    runs after the response body has been sent. We use this to close the
    upstream httpx response, releasing the underlying connection back to
    the pool.
    """
    # Imported lazily because starlette is a transitive dependency of
    # fastapi and we don't want to import at module load if something
    # test-time patches the environment.
    from starlette.background import BackgroundTask

    async def _close() -> None:
        await upstream.aclose()

    return BackgroundTask(_close)
