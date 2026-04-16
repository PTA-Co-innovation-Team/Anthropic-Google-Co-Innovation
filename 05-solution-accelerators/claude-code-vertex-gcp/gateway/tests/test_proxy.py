"""Tests for the pass-through proxy.

These tests do NOT require Google credentials or a network connection.
They mock out:

  * ``get_vertex_access_token`` so the proxy never actually calls the
    token endpoint.
  * The ``httpx.AsyncClient`` the app uses, so we can assert what the
    proxy sent upstream without making a real request.

Run with:
    cd gateway && pytest -q

What we assert:

1. **Happy-path forward.** A valid request is forwarded to the correct
   Vertex regional hostname with the body intact.
2. **Header sanitation.** Inbound ``anthropic-beta`` and ``Authorization``
   headers are stripped; outbound request carries a fresh bearer token.
3. **Auth rejection.** Without Cloud Run's platform-level auth (simulated
   here via an httpx MagicMock that returns 403), the proxy relays the
   403 as-is rather than swallowing it.
"""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any
from unittest.mock import AsyncMock, patch

import httpx
import pytest
from fastapi.testclient import TestClient


# ---------------------------------------------------------------------------
# Helpers: a fake httpx.AsyncClient + Response stack.
# ---------------------------------------------------------------------------


def _make_fake_response(status_code: int, body: bytes = b"", headers: dict[str, str] | None = None):
    """Construct something that quacks like httpx.Response for our uses."""

    # ``aiter_raw`` is how proxy._iter_upstream consumes the body.
    async def _aiter():
        if body:
            yield body

    fake = SimpleNamespace()
    fake.status_code = status_code
    fake.headers = headers or {}
    fake.aiter_raw = _aiter
    fake.aclose = AsyncMock(return_value=None)
    return fake


class _FakeClient:
    """Minimal stand-in for httpx.AsyncClient that records the sent request."""

    def __init__(self, response):
        self._response = response
        self.sent_request: httpx.Request | None = None

    def build_request(self, method: str, url: str, headers: dict[str, str], content: bytes) -> httpx.Request:
        return httpx.Request(method, url, headers=headers, content=content)

    async def send(self, request: httpx.Request, stream: bool = False):  # noqa: ARG002
        self.sent_request = request
        return self._response


@pytest.fixture
def app_with_fake_client():
    """Yields (app, fake_client) — fake_client.sent_request captures forward."""
    from app import main as main_module  # noqa: PLC0415 — local import on purpose

    app = main_module.app
    fake_response = _make_fake_response(200, b'{"content":"ok"}', {"content-type": "application/json"})
    fake_client = _FakeClient(fake_response)

    # Replace the lifespan-managed client with our fake.
    app.state.http_client = fake_client  # type: ignore[attr-defined]

    # Patch out the real token fetch so we don't try to talk to Google.
    with patch("app.proxy.get_vertex_access_token", return_value="fake-token"):
        yield app, fake_client


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_forward_happy_path(app_with_fake_client: tuple[Any, _FakeClient]) -> None:
    """A well-formed request is forwarded to the correct Vertex host."""
    app, fake = app_with_fake_client

    path = "/v1/projects/my-proj/locations/us-east5/publishers/anthropic/models/claude-opus-4-6:rawPredict"
    with TestClient(app) as client:
        resp = client.post(path, json={"contents": []})

    assert resp.status_code == 200
    assert fake.sent_request is not None
    # The regional host must be chosen based on the path.
    assert fake.sent_request.url.host == "us-east5-aiplatform.googleapis.com"
    # The body must be forwarded verbatim (contents-wise).
    assert b'"contents"' in fake.sent_request.content


def test_header_sanitization_strips_beta_and_sets_auth(
    app_with_fake_client: tuple[Any, _FakeClient],
) -> None:
    """Anthropic-beta headers are stripped; Authorization is replaced."""
    app, fake = app_with_fake_client

    path = "/v1/projects/my-proj/locations/global/publishers/anthropic/models/claude-sonnet-4-6:rawPredict"
    with TestClient(app) as client:
        resp = client.post(
            path,
            json={"contents": []},
            headers={
                # The caller's bearer token (from ADC). Must be replaced.
                "Authorization": "Bearer CALLER_TOKEN_SHOULD_BE_REPLACED",
                # Beta header — must be stripped.
                "anthropic-beta": "prompt-caching-2024-07-31",
                # Arbitrary safe header — must pass through.
                "X-Custom-Tag": "keep-me",
            },
        )

    assert resp.status_code == 200
    sent = fake.sent_request
    assert sent is not None

    # Global endpoint means bare hostname, no region prefix.
    assert sent.url.host == "aiplatform.googleapis.com"

    # Normalize header names for comparison (httpx lowercases internally,
    # but we re-create the Request in the fake so we go through our code
    # path).
    lowered = {k.lower(): v for k, v in sent.headers.items()}
    assert lowered["authorization"] == "Bearer fake-token"
    assert "anthropic-beta" not in lowered
    assert lowered["x-custom-tag"] == "keep-me"


def test_upstream_403_is_relayed(app_with_fake_client: tuple[Any, _FakeClient]) -> None:
    """A 403 from Vertex propagates back to the caller unchanged."""
    app, fake = app_with_fake_client

    # Replace the canned response with a 403 before making the request.
    fake._response = _make_fake_response(  # noqa: SLF001 — deliberate
        status_code=403,
        body=b'{"error":{"status":"PERMISSION_DENIED"}}',
        headers={"content-type": "application/json"},
    )

    path = "/v1/projects/my-proj/locations/us-east5/publishers/anthropic/models/claude-haiku-4-5:rawPredict"
    with TestClient(app) as client:
        resp = client.post(path, json={"contents": []})

    assert resp.status_code == 403
    assert b"PERMISSION_DENIED" in resp.content


def test_healthz_does_not_call_upstream(app_with_fake_client: tuple[Any, _FakeClient]) -> None:
    """``/healthz`` returns 200 without triggering an upstream call."""
    app, fake = app_with_fake_client

    with TestClient(app) as client:
        resp = client.get("/healthz")

    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}
    assert fake.sent_request is None
