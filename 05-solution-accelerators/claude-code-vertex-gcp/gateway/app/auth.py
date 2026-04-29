"""Caller-identity extraction.

**Important context on who actually enforces auth:**

Cloud Run, when deployed with ``--no-allow-unauthenticated``, enforces
IAM on the caller *before* the request reaches our FastAPI app. If the
caller does not have ``roles/run.invoker`` on the service, Cloud Run
returns 403 and our code never runs. That means this module does NOT
need to validate signatures or check token audiences — the platform did
that already.

What this module *does* do is:

1. Extract the caller's email from the headers that Cloud Run injects on
   authenticated requests so we can include it in logs.
2. Obtain a fresh OAuth 2.0 access token for the gateway's own service
   account via Application Default Credentials — this is the token we
   will use when calling Vertex AI.

When running locally (outside Cloud Run) for dev testing, the caller
headers are absent, so we fall back to a ``local-dev`` label.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass
from typing import Optional

import google.auth
import google.auth.transport.requests
from google.auth.credentials import Credentials


# Vertex AI OAuth scope — required for any call to aiplatform.googleapis.com.
_VERTEX_SCOPE = "https://www.googleapis.com/auth/cloud-platform"


@dataclass(frozen=True)
class CallerIdentity:
    """Who made the inbound request.

    Attributes:
        email: The caller's email. ``None`` if we couldn't determine it
            (e.g., local dev, or the caller is a service account without
            an injected email header).
        source: Which header family the identity came from. One of
            ``"iap"``, ``"cloud_run"``, or ``"unknown"``. Useful for
            debugging auth flows.
    """
    email: Optional[str]
    source: str


def extract_caller_identity(headers: dict[str, str]) -> CallerIdentity:
    """Identify who made the request.

    Cloud Run injects ``X-Goog-Authenticated-User-Email`` on authenticated
    invocations. IAP injects ``X-Goog-Authenticated-User-Email`` too
    (prefixed with ``accounts.google.com:``). Either way, the header's
    value ends with the email, which is what we care about.

    Args:
        headers: Case-insensitive dict of the inbound request headers.
            Call sites should lower-case header names before lookup, or
            use FastAPI's ``request.headers`` which is already
            case-insensitive.

    Returns:
        A ``CallerIdentity``. ``email`` is ``None`` for local-dev calls.
    """
    # Both IAP and Cloud Run use the same header name; values from IAP are
    # of the form "accounts.google.com:[email protected]", while direct
    # Cloud Run invocations produce the raw email. We handle both.
    raw = headers.get("x-goog-authenticated-user-email")
    if not raw:
        return CallerIdentity(email=None, source="unknown")

    # Strip the IAP prefix if present.
    if ":" in raw:
        email = raw.split(":", 1)[1]
        source = "iap"
    else:
        email = raw
        source = "cloud_run"

    return CallerIdentity(email=email, source=source)


# --- Gateway-side credentials for outbound Vertex calls --------------------

# The Cloud Run runtime populates ADC automatically with the service account
# attached to the service. We cache the credentials object module-wide and
# refresh its token on demand, which is cheap and thread-safe thanks to
# google-auth's internal locking.
_credentials_lock = threading.Lock()
_credentials: Optional[Credentials] = None


def _get_credentials() -> Credentials:
    """Fetch (and cache) Application Default Credentials scoped for Vertex.

    Uses a module-level cache protected by a lock. The credentials object
    itself is safe to share across threads and across async tasks.
    """
    global _credentials
    with _credentials_lock:
        if _credentials is None:
            # ``google.auth.default`` picks up the ambient identity:
            #   * On Cloud Run: the service account attached to the service.
            #   * Locally: whoever ran ``gcloud auth application-default login``.
            creds, _project = google.auth.default(scopes=[_VERTEX_SCOPE])
            _credentials = creds
        return _credentials


def get_vertex_access_token() -> str:
    """Return a fresh OAuth access token for calling Vertex AI.

    Refreshes the cached credentials if the token is missing or expired.
    Call this on every outbound request — ``google-auth`` internally
    avoids network traffic when the existing token is still valid.
    """
    creds = _get_credentials()
    # ``creds.valid`` is False if the token is missing or expired.
    if not creds.valid:
        # ``Request`` is a simple httplib-based transport from google-auth
        # used only for the token refresh endpoint call. It's fine to
        # instantiate per call; it does not hold state between calls.
        request = google.auth.transport.requests.Request()
        creds.refresh(request)
    # ``token`` is the bearer string once the credentials are valid.
    return creds.token  # type: ignore[no-any-return]
