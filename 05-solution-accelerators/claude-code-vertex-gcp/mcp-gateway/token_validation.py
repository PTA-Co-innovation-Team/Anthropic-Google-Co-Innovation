"""Token validation middleware for GLB mode.

Keep in sync with gateway/app/token_validation.py -- this is a copy
for the MCP gateway's independent container.

When the gateway runs behind a Global HTTP(S) Load Balancer with
Cloud Run ingress set to internal-and-cloud-load-balancing, Cloud Run
IAM is no longer the auth boundary. This middleware validates inbound
tokens at the application layer instead.

Accepts both token types that Google tooling sends:
  * **OIDC identity tokens** (JWTs) -- verified via Google's public keys.
  * **OAuth2 access tokens** -- verified via Google's tokeninfo endpoint,
    with a short TTL cache to avoid per-request latency.

Enable by setting ``ENABLE_TOKEN_VALIDATION=1``.
"""

from __future__ import annotations

import logging
import os
from typing import Optional

import cachetools
import httpx
from fastapi import Request
from fastapi.responses import JSONResponse
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token

log = logging.getLogger(__name__)

_TOKEN_CACHE: cachetools.TTLCache[str, str] = cachetools.TTLCache(
    maxsize=1024, ttl=30
)

_SKIP_PATHS = frozenset({"/health", "/healthz"})


def _load_allowed_principals() -> frozenset[str] | None:
    raw = os.getenv("ALLOWED_PRINCIPALS", "").strip()
    if not raw:
        return None
    principals: set[str] = set()
    for entry in raw.split(","):
        entry = entry.strip()
        if ":" in entry:
            entry = entry.split(":", 1)[1]
        if entry:
            principals.add(entry.lower())
    return frozenset(principals) if principals else None


_ALLOWED_PRINCIPALS = _load_allowed_principals()


def _is_jwt(token: str) -> bool:
    parts = token.split(".")
    return len(parts) == 3 and all(parts)


async def _verify_oidc_token(token: str) -> Optional[str]:
    try:
        claims = id_token.verify_oauth2_token(
            token, google_requests.Request()
        )
        return claims.get("email")
    except Exception:
        log.debug("oidc_verification_failed", exc_info=True)
        return None


async def _verify_access_token(token: str) -> Optional[str]:
    cached = _TOKEN_CACHE.get(token)
    if cached is not None:
        return cached

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                "https://oauth2.googleapis.com/tokeninfo",
                params={"access_token": token},
            )
        if resp.status_code != 200:
            return None
        data = resp.json()
        email = data.get("email")
        if email:
            _TOKEN_CACHE[token] = email
        return email
    except Exception:
        log.debug("access_token_verification_failed", exc_info=True)
        return None


async def validate_token_middleware(request: Request, call_next):
    if request.url.path in _SKIP_PATHS:
        return await call_next(request)

    auth_header = request.headers.get("authorization", "")
    if not auth_header.lower().startswith("bearer "):
        return JSONResponse(
            {"error": "missing_token", "detail": "Authorization: Bearer <token> required"},
            status_code=401,
        )

    token = auth_header[7:]

    if _is_jwt(token):
        email = await _verify_oidc_token(token)
        source = "oidc"
    else:
        email = await _verify_access_token(token)
        source = "access_token"

    if email is None:
        return JSONResponse(
            {"error": "invalid_token", "detail": "Token verification failed"},
            status_code=401,
        )

    if _ALLOWED_PRINCIPALS is not None and email.lower() not in _ALLOWED_PRINCIPALS:
        log.warning("principal_denied", extra={"email": email})
        return JSONResponse(
            {"error": "forbidden", "detail": f"{email} is not in the allowed principals list"},
            status_code=403,
        )

    request.state.caller_email = email
    request.state.caller_source = source

    return await call_next(request)
