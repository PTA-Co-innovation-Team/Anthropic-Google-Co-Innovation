#!/usr/bin/env python3
"""MCP Streamable HTTP test helper.

Performs the full MCP handshake against a deployed MCP gateway and
invokes a named tool. Exits 0 on success, 1 on failure, and prints a
single-line diagnostic for the bash e2e script to consume.

The handshake is painful to do in pure bash because:
  * ``initialize`` returns an ``Mcp-Session-Id`` header we must echo
    back on every subsequent call.
  * After ``initialize`` we must send the ``notifications/initialized``
    notification before calling any tool.
  * Servers may stream responses as SSE framing over the same HTTP
    connection even though the transport is called "Streamable HTTP".

Usage:
    mcp_test.py <base-url> <tool-name> [json-args]

Example:
    mcp_test.py https://mcp-gateway-xxx-uc.a.run.app gcp_project_info
    mcp_test.py https://... add '{"x":1,"y":2}'

Auth: mints an OIDC identity token or falls back to an ADC access token.
The MCP gateway's token_validation.py middleware accepts both token types.
"""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from typing import Any

import google.auth
import google.auth.transport.requests


# Required by the MCP Streamable HTTP spec. Both content types listed
# because the server may reply with either JSON or SSE-framed JSON.
_ACCEPT = "application/json, text/event-stream"


def _token(audience: str) -> str:
    """Return a bearer token for calling the MCP gateway.

    Prefers an OIDC identity token; falls back to an ADC access token.
    The gateway's token_validation.py middleware accepts both.
    """
    try:
        import google.oauth2.id_token  # noqa: PLC0415
        return google.oauth2.id_token.fetch_id_token(
            google.auth.transport.requests.Request(), audience
        )
    except Exception:  # noqa: BLE001
        creds, _ = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        creds.refresh(google.auth.transport.requests.Request())
        return creds.token


def _post(url: str, token: str, session_id: str | None, body: dict) -> tuple[int, dict, str | None]:
    """POST a JSON-RPC body; return (status, parsed_json, session_id).

    Handles both ``application/json`` and ``text/event-stream`` replies.
    SSE framing is decoded by concatenating the ``data:`` lines in
    order and parsing them as JSON.
    """
    headers = {
        "Content-Type": "application/json",
        "Accept": _ACCEPT,
        "Authorization": f"Bearer {token}",
    }
    if session_id:
        headers["Mcp-Session-Id"] = session_id

    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode(errors="replace")}, None

    status = resp.status
    sid = resp.headers.get("Mcp-Session-Id")
    raw = resp.read().decode()
    content_type = resp.headers.get("Content-Type", "")

    if "text/event-stream" in content_type:
        # Reassemble SSE frames. We only care about the final ``data:``
        # line's content, which carries the JSON-RPC reply.
        data_lines = [
            line[len("data:"):].strip()
            for line in raw.splitlines()
            if line.startswith("data:")
        ]
        payload_str = data_lines[-1] if data_lines else "{}"
    else:
        payload_str = raw or "{}"

    try:
        payload: dict[str, Any] = json.loads(payload_str)
    except json.JSONDecodeError:
        payload = {"raw": payload_str}
    return status, payload, sid


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: mcp_test.py <base-url> <tool-name> [json-args]", file=sys.stderr)
        return 2

    base_url = sys.argv[1].rstrip("/")
    tool_name = sys.argv[2]
    tool_args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}

    # FastMCP mounts Streamable HTTP at /mcp/ (trailing slash). POST to
    # /mcp returns a 307 redirect that urllib won't follow, so we use
    # the canonical path with trailing slash.
    mcp_url = f"{base_url}/mcp/"

    try:
        token = _token(base_url)
    except Exception as e:  # noqa: BLE001
        print(f"FAIL: credentials unavailable: {e}")
        return 1

    # --- 1. initialize -----------------------------------------------------
    status, init_resp, session_id = _post(
        mcp_url, token, None,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {"name": "e2e-test", "version": "0.1.0"},
            },
        },
    )
    if status != 200 or "error" in init_resp and "result" not in init_resp:
        print(f"FAIL: initialize returned {status}: {init_resp}")
        return 1
    if not session_id:
        # Some servers put it in the body. Fall back to that.
        session_id = init_resp.get("result", {}).get("sessionId")
    if not session_id:
        print(f"FAIL: no Mcp-Session-Id in initialize response")
        return 1

    # --- 2. notifications/initialized -------------------------------------
    _post(
        mcp_url, token, session_id,
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
    )

    # --- 3. tools/call ----------------------------------------------------
    status, call_resp, _ = _post(
        mcp_url, token, session_id,
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": tool_args},
        },
    )
    if status != 200:
        print(f"FAIL: tools/call returned HTTP {status}: {call_resp}")
        return 1
    if "error" in call_resp:
        print(f"FAIL: tools/call JSON-RPC error: {call_resp['error']}")
        return 1
    result = call_resp.get("result", {})
    # The result has a ``content`` array of typed items. We just confirm
    # we got *something* back and echo a short summary.
    content = result.get("content", [])
    if not content:
        print(f"FAIL: tools/call returned empty content: {result}")
        return 1

    print(f"PASS: tool {tool_name} returned {len(content)} content item(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
