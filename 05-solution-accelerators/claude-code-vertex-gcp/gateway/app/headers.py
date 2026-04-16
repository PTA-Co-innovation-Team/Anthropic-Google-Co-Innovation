"""Header sanitation.

Claude Code occasionally sends ``anthropic-beta`` (and similar) headers to
opt into experimental features. These are supported by Anthropic's direct
API but rejected by Vertex AI, which strict-validates its request headers.
If we forward them as-is, Vertex returns an obscure error and the user's
request fails.

Claude Code exposes ``CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`` to
suppress them client-side. ``developer-setup.sh`` sets that flag. This
module is the belt-and-suspenders server-side equivalent: even if someone
runs Claude Code without the flag, we strip the headers here so requests
still succeed.

Also responsible for:
  * Dropping the inbound ``Authorization`` header (the caller's Google ID
    token) — we re-authenticate to Vertex using the Cloud Run service
    account's ADC, not the caller's token.
  * Dropping hop-by-hop headers per RFC 7230 (Connection, Upgrade, etc.)
    that should not be forwarded by any proxy.
"""

from __future__ import annotations

from typing import Iterable


# Exact-match headers we always drop. Compared case-insensitively.
#
# - Authorization: replaced downstream with the gateway SA's token.
# - Host: uvicorn sets this to the Cloud Run hostname; Vertex needs the
#   Vertex hostname, which httpx sets automatically when we build the URL.
# - Content-Length: httpx recomputes this when we rebuild the request body.
# - x-cloud-trace-context / x-goog-*: GCP-internal, stripping is safer.
_EXACT_DROPS = {
    "authorization",
    "host",
    "content-length",
    "x-cloud-trace-context",
    "x-forwarded-for",
    "x-forwarded-proto",
    "x-forwarded-host",
    "forwarded",
}

# Hop-by-hop headers per RFC 7230 Section 6.1. Proxies MUST NOT forward
# these.
_HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}

# Prefix-match headers to drop. Any inbound header whose name starts with
# one of these prefixes (case-insensitive) is removed.
#
# "anthropic-beta" — the whole point of this module.
# "x-goog-"        — Cloud Run / IAP internal headers that Vertex doesn't
#                    care about and that can leak caller info we'd rather
#                    re-inject deliberately in the proxy layer.
_PREFIX_DROPS = (
    "anthropic-beta",
    "x-goog-",
)


def sanitize_request_headers(
    headers: Iterable[tuple[str, str]],
) -> tuple[dict[str, str], list[str]]:
    """Return a cleaned copy of the headers suitable for forwarding.

    Args:
        headers: Iterable of (name, value) pairs as they arrived. FastAPI's
            ``request.headers.raw`` returns bytes; callers should decode
            before passing in.

    Returns:
        A 2-tuple ``(clean_headers, stripped_names)`` where:
          * ``clean_headers`` is a dict of header name → value, ready to
            pass to httpx.
          * ``stripped_names`` is a list of lowercase header names that
            were removed (for logging).
    """
    clean: dict[str, str] = {}
    stripped: list[str] = []

    for name, value in headers:
        lower = name.lower()

        # Exact-drop set.
        if lower in _EXACT_DROPS or lower in _HOP_BY_HOP:
            stripped.append(lower)
            continue

        # Prefix-drop set.
        if any(lower.startswith(p) for p in _PREFIX_DROPS):
            stripped.append(lower)
            continue

        # Everything else is safe to forward. Use the original-case name so
        # downstream tooling (e.g., httpx debug output) looks normal.
        clean[name] = value

    return clean, stripped
