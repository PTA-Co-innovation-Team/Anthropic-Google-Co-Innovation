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
import os
import re
import time
from typing import AsyncIterator, Optional

import httpx
from fastapi import Request
from fastapi.responses import StreamingResponse

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
    model = _extract_model(request.url.path)
    region = _extract_region_from_path(request.url.path)

    # --- Sanitize headers and add gateway auth -----------------------------
    cleaned, stripped = sanitize_request_headers(
        [(k, v) for k, v in request.headers.items()]
    )
    token = await asyncio.to_thread(get_vertex_access_token)
    cleaned["Authorization"] = f"Bearer {token}"

    # --- Build upstream URL ------------------------------------------------
    url = build_upstream_url(request.url.path, request.url.query)

    # --- Read body ---------------------------------------------------------
    # Claude Code requests are JSON and usually small; we read the whole
    # body into memory. If we ever need to handle multi-megabyte uploads
    # we would switch to streaming the request body instead.
    body = await request.body()

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

    return StreamingResponse(
        _iter_upstream(upstream),
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
