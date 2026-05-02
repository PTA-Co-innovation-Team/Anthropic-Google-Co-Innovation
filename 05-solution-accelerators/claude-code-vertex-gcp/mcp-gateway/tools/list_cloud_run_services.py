"""MCP tool: list Cloud Run services in the current GCP project.

Read-only. Useful to a Claude Code session that needs to know what
services are deployed without the user shelling out to ``gcloud``.

What it returns:
    * ``services`` — list of dicts with name, region, url, last_revision,
      ready (bool), last_deployed_at.
    * ``count``    — number of services returned.
    * ``truncated``— True if the result was capped at ``max_results``.

Auth:
    ADC. Requires ``roles/run.viewer`` on the project (or any role that
    grants ``run.services.list``). The deploy script grants this to the
    MCP gateway's SA.
"""

from __future__ import annotations

import json as _json
import os
import urllib.parse
import urllib.request
from typing import Any

import google.auth
import google.auth.transport.requests


_DEFAULT_REGION = os.getenv("CLOUD_RUN_REGION") or os.getenv(
    "GOOGLE_CLOUD_REGION", "us-central1"
)


def list_cloud_run_services(
    region: str | None = None,
    max_results: int = 50,
) -> dict[str, Any]:
    """Return Cloud Run services in the project (and optionally a region).

    Args:
        region: GCE/Cloud Run region. Defaults to the gateway's own
            region (or ``us-central1`` if not set). Pass ``"-"`` to
            list across all regions.
        max_results: Cap on returned services. Default 50.

    Returns:
        Dict with ``services``, ``count``, ``truncated``, and ``region``.
        On error, returns ``{"error": ..., "detail": ...}`` instead.
    """
    region = region or _DEFAULT_REGION

    try:
        creds, project_id = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        if not creds.valid:
            creds.refresh(google.auth.transport.requests.Request())
    except Exception as exc:  # noqa: BLE001
        return {"error": "credentials_unavailable", "detail": str(exc)}

    parent = f"projects/{project_id}/locations/{region}"
    url = (
        "https://run.googleapis.com/v2/"
        f"{parent}/services?pageSize={max_results}"
    )

    try:
        req = urllib.request.Request(
            url, headers={"Authorization": f"Bearer {creds.token}"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = _json.loads(resp.read())
    except Exception as exc:  # noqa: BLE001
        return {
            "error": "list_failed",
            "detail": str(exc),
            "hint": "MCP gateway SA may need roles/run.viewer",
        }

    services = []
    for s in data.get("services", []):
        # Service name comes back as projects/<p>/locations/<r>/services/<name>.
        full = s.get("name", "")
        short = full.rsplit("/", 1)[-1] if full else full
        last_rev = (s.get("latestReadyRevision") or "").rsplit("/", 1)[-1]
        # `conditions` is a list; the "Ready" one tells us status.
        ready = False
        for cond in s.get("conditions", []) or []:
            if cond.get("type") == "Ready":
                ready = cond.get("state") == "CONDITION_SUCCEEDED"
                break
        services.append(
            {
                "name": short,
                "region": region,
                "url": s.get("uri") or s.get("urls", [None])[0],
                "last_revision": last_rev,
                "ready": ready,
                "last_deployed_at": s.get("updateTime"),
            }
        )

    return {
        "services": services,
        "count": len(services),
        "truncated": "nextPageToken" in data,
        "region": region,
    }
