"""Tests for the token-validation middleware.

These tests do NOT require Google credentials or a network connection.
They mock:
  * ``google.oauth2.id_token.verify_oauth2_token`` for OIDC tokens
  * ``httpx.AsyncClient`` for access-token tokeninfo calls

Run with:
    cd gateway && ENABLE_TOKEN_VALIDATION=1 pytest -q tests/test_token_validation.py
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

import app.token_validation as tv

# Build emails via concatenation to avoid tooling normalization.
ADMIN_EMAIL = "admin" + "@" + "corp.dev"
OUTSIDER_EMAIL = "outsider" + "@" + "external.dev"
TESTER_EMAIL = "tester" + "@" + "corp.dev"


@pytest.fixture(autouse=True)
def _clean_module_state():
    """Reset mutable module state between tests."""
    tv._TOKEN_CACHE.clear()
    original = tv._ALLOWED_PRINCIPALS
    yield
    tv._ALLOWED_PRINCIPALS = original
    tv._TOKEN_CACHE.clear()


def _make_app(allowed_principals: frozenset[str] | None = None):
    tv._ALLOWED_PRINCIPALS = allowed_principals

    test_app = FastAPI()
    test_app.middleware("http")(tv.validate_token_middleware)

    @test_app.get("/health")
    async def health():
        return JSONResponse({"status": "ok"})

    @test_app.get("/healthz")
    async def healthz():
        return JSONResponse({"status": "ok"})

    @test_app.get("/v1/test")
    async def protected(request: Request):
        return JSONResponse({
            "caller_email": getattr(request.state, "caller_email", None),
            "caller_source": getattr(request.state, "caller_source", None),
        })

    return test_app


def _mock_httpx_for_email(email: str | None, status: int = 200):
    """Return a mock async httpx client that simulates a tokeninfo response."""
    mock_resp = MagicMock()
    mock_resp.status_code = status
    mock_resp.json.return_value = {"email": email} if email else {"error_description": "Invalid Value"}

    mock_client = AsyncMock()
    mock_client.get = AsyncMock(return_value=mock_resp)
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)
    return mock_client


class TestHealthBypass:
    def test_health_no_token(self):
        app = _make_app()
        with TestClient(app) as client:
            resp = client.get("/health")
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"

    def test_healthz_no_token(self):
        app = _make_app()
        with TestClient(app) as client:
            resp = client.get("/healthz")
        assert resp.status_code == 200


class TestMissingToken:
    def test_no_auth_header(self):
        app = _make_app()
        with TestClient(app) as client:
            resp = client.get("/v1/test")
        assert resp.status_code == 401
        assert resp.json()["error"] == "missing_token"

    def test_malformed_auth_header(self):
        app = _make_app()
        with TestClient(app) as client:
            resp = client.get("/v1/test", headers={"Authorization": "Basic abc"})
        assert resp.status_code == 401


class TestAccessToken:
    @patch("app.token_validation.httpx.AsyncClient")
    def test_valid_access_token(self, mock_client_cls):
        mock_client_cls.return_value = _mock_httpx_for_email(TESTER_EMAIL)

        app = _make_app()
        with TestClient(app) as client:
            resp = client.get(
                "/v1/test",
                headers={"Authorization": "Bearer ya29.fake-access-token"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert body["caller_email"] == TESTER_EMAIL
        assert body["caller_source"] == "access_token"

    @patch("app.token_validation.httpx.AsyncClient")
    def test_invalid_access_token(self, mock_client_cls):
        mock_client_cls.return_value = _mock_httpx_for_email(None, status=400)

        app = _make_app()
        with TestClient(app) as client:
            resp = client.get(
                "/v1/test",
                headers={"Authorization": "Bearer ya29.invalid-token"},
            )
        assert resp.status_code == 401
        assert resp.json()["error"] == "invalid_token"


class TestOIDCToken:
    @patch("app.token_validation.id_token.verify_oauth2_token")
    def test_valid_oidc_token(self, mock_verify):
        mock_verify.return_value = {"email": TESTER_EMAIL, "sub": "12345"}

        app = _make_app()
        fake_jwt = "eyJhbGciOiJSUzI1NiJ9.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20ifQ.signature"
        with TestClient(app) as client:
            resp = client.get(
                "/v1/test",
                headers={"Authorization": f"Bearer {fake_jwt}"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert body["caller_email"] == TESTER_EMAIL
        assert body["caller_source"] == "oidc"

    @patch("app.token_validation.id_token.verify_oauth2_token")
    def test_invalid_oidc_token(self, mock_verify):
        mock_verify.side_effect = ValueError("Invalid token")

        app = _make_app()
        fake_jwt = "bad.jwt.token"
        with TestClient(app) as client:
            resp = client.get(
                "/v1/test",
                headers={"Authorization": f"Bearer {fake_jwt}"},
            )
        assert resp.status_code == 401


class TestAllowedPrincipals:
    @patch("app.token_validation.httpx.AsyncClient")
    def test_allowed_principal_passes(self, mock_client_cls):
        mock_client_cls.return_value = _mock_httpx_for_email(ADMIN_EMAIL)

        app = _make_app(allowed_principals=frozenset({ADMIN_EMAIL}))
        with TestClient(app) as client:
            resp = client.get(
                "/v1/test",
                headers={"Authorization": "Bearer ya29.allowed-token"},
            )
        assert resp.status_code == 200
        assert resp.json()["caller_email"] == ADMIN_EMAIL

    @patch("app.token_validation.httpx.AsyncClient")
    def test_denied_principal_returns_403(self, mock_client_cls):
        mock_client_cls.return_value = _mock_httpx_for_email(OUTSIDER_EMAIL)

        app = _make_app(allowed_principals=frozenset({ADMIN_EMAIL}))
        with TestClient(app) as client:
            resp = client.get(
                "/v1/test",
                headers={"Authorization": "Bearer ya29.denied-token"},
            )
        assert resp.status_code == 403
        assert resp.json()["error"] == "forbidden"
