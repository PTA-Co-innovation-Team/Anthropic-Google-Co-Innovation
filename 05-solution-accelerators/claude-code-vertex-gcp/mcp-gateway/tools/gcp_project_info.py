"""Example MCP tool: return metadata about the current GCP project.

This is the tool shipped out-of-the-box so you can verify the MCP
gateway works end-to-end from Claude Code before you add anything of
your own. It's also a template for tools that need to call Google Cloud
APIs using the server's service-account identity.

What it returns:
    * ``project_id``    — the project the Cloud Run container is in.
    * ``project_number``— numeric GCP project number (if available).
    * ``region``        — the Cloud Run region.
    * ``enabled_apis``  — count of APIs enabled in the project.

How it authenticates:
    Application Default Credentials, the same way the LLM gateway does.
    On Cloud Run, ADC resolves to the service account attached to the
    service. Locally, to whoever ran ``gcloud auth application-default
    login``.
"""

from __future__ import annotations

import os
from typing import Any

import google.auth
import google.auth.transport.requests


def get_project_info() -> dict[str, Any]:
    """Collect a small snapshot of metadata about the current GCP project.

    Returns:
        A dict with keys ``project_id``, ``project_number`` (or None),
        ``region``, and ``enabled_apis`` (int count or None on error).

    Raises:
        Nothing that isn't caught and surfaced as a field in the result.
        MCP tools should never raise unexpectedly — they surface errors
        in the return value so the model can react usefully.
    """
    # ``google.auth.default`` returns a credentials object AND the project
    # it resolved for this call. That's the cheapest way to learn the
    # ambient project without a Service Usage API call.
    try:
        creds, project_id = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
    except Exception as exc:  # noqa: BLE001 — surface any auth problem verbatim
        return {
            "error": "credentials_unavailable",
            "detail": str(exc),
        }

    # The region the Cloud Run container is running in. Set by the
    # platform at runtime; falls back to "unknown" for local dev.
    region = os.getenv("GOOGLE_CLOUD_REGION") or os.getenv("K_SERVICE_REGION", "unknown")

    # Count enabled APIs via Service Usage. This requires
    # ``roles/serviceusage.serviceUsageViewer`` on the project; if absent
    # we still return the rest of the info rather than failing hard.
    enabled_apis: int | None = None
    project_number: str | None = None
    try:
        # Lazy-refresh the token. google-auth no-ops if still valid.
        if not creds.valid:
            creds.refresh(google.auth.transport.requests.Request())

        # Hand-rolled HTTP call keeps the dependency set small — no
        # extra google-cloud-* package required.
        import urllib.request
        import json as _json

        # Describe the project to get its numeric project number.
        req = urllib.request.Request(
            f"https://cloudresourcemanager.googleapis.com/v1/projects/{project_id}",
            headers={"Authorization": f"Bearer {creds.token}"},
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = _json.loads(resp.read())
            project_number = data.get("projectNumber")

        # Enumerate enabled services. Paginated; for the
        # "give me a count" use case, one page is enough to prove the
        # connection works — we cap at 500 for readability.
        req = urllib.request.Request(
            f"https://serviceusage.googleapis.com/v1/projects/{project_id}/services"
            "?filter=state:ENABLED&pageSize=500",
            headers={"Authorization": f"Bearer {creds.token}"},
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = _json.loads(resp.read())
            enabled_apis = len(data.get("services", []))
    except Exception as exc:  # noqa: BLE001 — same rationale as above
        return {
            "project_id": project_id,
            "project_number": project_number,
            "region": region,
            "enabled_apis": None,
            "warning": f"could not enumerate APIs: {exc!s}",
        }

    return {
        "project_id": project_id,
        "project_number": project_number,
        "region": region,
        "enabled_apis": enabled_apis,
    }
