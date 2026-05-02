"""Token validation middleware for GLB mode.

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
    """Heuristic test: does this look like a JWT?

    Three segments alone is NOT enough — Google OAuth2 access tokens
    (``ya29.c.c0...``) also have three dot-separated segments but are
    NOT JWTs and must be verified via tokeninfo, not signature
    validation. A real JWT has a base64url-encoded JSON header with at
    minimum an ``alg`` field; we use that as the discriminator.
    """
    parts = token.split(".")
    if len(parts) != 3 or not all(parts):
        return False
    import base64
    import json as _json

    try:
        padded = parts[0] + "=" * (-len(parts[0]) % 4)
        header = _json.loads(base64.urlsafe_b64decode(padded))
        return isinstance(header, dict) and "alg" in header
    except Exception:
        return False


async def _verify_oidc_token(token: str) -> Optional[str]:
    try:
        claims = id_token.verify_oauth2_token(
            token, google_requests.Request()
        )
        return claims.get("email")
    except Exception:
        log.debug("oidc_verification_failed", exc_info=True)
        return None


# SA uniqueId → email cache. SA emails are stable per-uniqueId for the
# life of the SA, so this cache never needs invalidation.
_SA_UNIQUEID_CACHE: cachetools.LRUCache[str, str] = cachetools.LRUCache(maxsize=512)


async def _resolve_sa_email_by_uniqueid(
    unique_id: str, http_client: httpx.AsyncClient
) -> Optional[str]:
    """Look up a service account email by its numeric uniqueId.

    Why this exists: Google's ``oauth2/tokeninfo`` endpoint does NOT
    populate the ``email`` field for service-account access tokens
    (only for user OAuth tokens). It returns ``azp`` instead, which is
    the SA's numeric uniqueId. To enforce ``ALLOWED_PRINCIPALS`` against
    SA tokens we must resolve uniqueId → email via the IAM API.

    Requires the gateway's own service account to have
    ``iam.serviceAccounts.get`` (e.g. ``roles/iam.serviceAccountViewer``)
    on the project that owns the calling SA.
    """
    cached = _SA_UNIQUEID_CACHE.get(unique_id)
    if cached is not None:
        return cached

    try:
        # Lazy import — only needed when SA-token branch is exercised.
        import google.auth
        import google.auth.transport.requests as g_requests

        creds, _ = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        if not creds.valid:
            creds.refresh(g_requests.Request())

        resp = await http_client.get(
            f"https://iam.googleapis.com/v1/projects/-/serviceAccounts/{unique_id}",
            headers={"Authorization": f"Bearer {creds.token}"},
        )
        if resp.status_code == 200:
            email = resp.json().get("email")
            if email:
                _SA_UNIQUEID_CACHE[unique_id] = email
                return email
        else:
            log.warning(
                "sa_lookup_failed status=%s body=%s",
                resp.status_code,
                resp.text[:200],
            )
    except Exception:
        log.warning("sa_lookup_exception", exc_info=True)
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
            # GCE metadata-server SA tokens do not include `email`; they
            # include `azp` (the SA's numeric uniqueId). Resolve it.
            if not email:
                azp = data.get("azp", "")
                if azp.isdigit():
                    email = await _resolve_sa_email_by_uniqueid(azp, client)
        if email:
            _TOKEN_CACHE[token] = email
        return email
    except Exception:
        log.warning("access_token_verification_failed", exc_info=True)
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
