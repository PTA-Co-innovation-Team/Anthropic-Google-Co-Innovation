"""MCP tool: pull recent error log entries for the LLM and MCP gateways.

Read-only. Useful when the developer asks Claude to triage a problem;
Claude can call this and get the actual error lines instead of asking
the user to copy-paste from Cloud Logging.

What it returns:
    * ``errors``  — list of dicts: timestamp, severity, service, summary.
    * ``count``   — number of entries returned.
    * ``window_hours`` — the time window queried.

Auth:
    ADC. Requires ``roles/logging.viewer`` on the project (the
    ``logging.entries.list`` permission). The deploy script grants this.
"""

from __future__ import annotations

import json as _json
import urllib.request
from typing import Any

import google.auth
import google.auth.transport.requests


def recent_gateway_errors(
    hours: int = 1,
    max_results: int = 25,
) -> dict[str, Any]:
    """Return ERROR/WARNING log entries from the gateway services.

    Args:
        hours: Time window. Default 1 hour, max 168 (one week).
        max_results: Cap on returned entries. Default 25.

    Returns:
        Dict with ``errors``, ``count``, and ``window_hours``. On error,
        ``{"error": ..., "detail": ...}``.
    """
    hours = max(1, min(int(hours), 168))
    max_results = max(1, min(int(max_results), 200))

    try:
        creds, project_id = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        if not creds.valid:
            creds.refresh(google.auth.transport.requests.Request())
    except Exception as exc:  # noqa: BLE001
        return {"error": "credentials_unavailable", "detail": str(exc)}

    # Cloud Logging filter — gateway services only, severity >= WARNING,
    # within the requested window. Uses Cloud Logging's relative
    # ``timestamp >= "<rfc3339>"`` syntax via ``%FT%TZ`` in Python.
    from datetime import datetime, timezone, timedelta

    cutoff = (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    filter_str = (
        'resource.type="cloud_run_revision" '
        'resource.labels.service_name=~"^(llm-gateway|mcp-gateway)$" '
        "severity>=WARNING "
        f'timestamp>="{cutoff}"'
    )

    body = _json.dumps(
        {
            "resourceNames": [f"projects/{project_id}"],
            "filter": filter_str,
            "orderBy": "timestamp desc",
            "pageSize": max_results,
        }
    ).encode("utf-8")

    try:
        req = urllib.request.Request(
            "https://logging.googleapis.com/v2/entries:list",
            data=body,
            headers={
                "Authorization": f"Bearer {creds.token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = _json.loads(resp.read())
    except Exception as exc:  # noqa: BLE001
        return {
            "error": "list_failed",
            "detail": str(exc),
            "hint": "MCP gateway SA may need roles/logging.viewer",
        }

    errors = []
    for e in data.get("entries", []):
        # The interesting message lives in jsonPayload.message
        # (structured) or textPayload (plain). We surface whichever
        # exists, truncated to keep the model's context lean.
        msg = ""
        if isinstance(e.get("jsonPayload"), dict):
            msg = e["jsonPayload"].get("message", "") or _json.dumps(
                e["jsonPayload"]
            )[:300]
        elif isinstance(e.get("textPayload"), str):
            msg = e["textPayload"]
        errors.append(
            {
                "timestamp": e.get("timestamp"),
                "severity": e.get("severity"),
                "service": (e.get("resource") or {})
                .get("labels", {})
                .get("service_name"),
                "summary": (msg or "")[:300],
            }
        )

    return {
        "errors": errors,
        "count": len(errors),
        "window_hours": hours,
    }
