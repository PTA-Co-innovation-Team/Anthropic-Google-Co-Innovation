"""MCP tool: summarize gateway usage from the BigQuery log dataset.

Lets a developer ask Claude things like "how much have we used the
gateway today?" or "who's been the heaviest user this week?" without
opening BigQuery. Read-only; one query per call.

What it returns:
    * ``window_hours`` — the time window summarized.
    * ``total_requests`` — count of proxy_request rows in the window.
    * ``by_model`` — list of {model, count}.
    * ``by_caller`` — list of {caller, count} (top 10).
    * ``error_rate_pct`` — % of responses with status >= 400.
    * ``latency_ms`` — {p50, p95, p99} (None if no data).

Auth:
    ADC. Requires ``roles/bigquery.dataViewer`` and
    ``roles/bigquery.jobUser`` on the project. The deploy script grants
    both. Uses parameterized queries; no SQL injection surface.
"""

from __future__ import annotations

import json as _json
import urllib.request
from typing import Any

import google.auth
import google.auth.transport.requests


_DATASET = "claude_code_logs"
_TABLE = "run_googleapis_com_stdout"


def gateway_traffic_summary(hours: int = 24) -> dict[str, Any]:
    """Summarize gateway traffic over the last `hours` hours.

    Args:
        hours: Time window in hours. Default 24, max 720 (30 days).

    Returns:
        Dict with totals, breakdowns, and latency percentiles. On error
        ``{"error": ..., "detail": ...}``.
    """
    hours = max(1, min(int(hours), 720))

    try:
        creds, project_id = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        if not creds.valid:
            creds.refresh(google.auth.transport.requests.Request())
    except Exception as exc:  # noqa: BLE001
        return {"error": "credentials_unavailable", "detail": str(exc)}

    # Single query that returns one row of aggregates plus the
    # by-model / by-caller breakdowns as nested arrays. Cheaper than
    # 5 separate queries and avoids 5 round-trips.
    sql = f"""
        WITH base AS (
            SELECT
                jsonPayload.model       AS model,
                jsonPayload.caller      AS caller,
                SAFE_CAST(jsonPayload.status_code           AS INT64) AS status_code,
                SAFE_CAST(jsonPayload.latency_ms_to_headers AS INT64) AS latency_ms
            FROM `{project_id}.{_DATASET}.{_TABLE}`
            WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL @hours HOUR)
              AND jsonPayload.model IS NOT NULL
        ),
        by_model AS (
            SELECT ARRAY_AGG(STRUCT(model, c) ORDER BY c DESC) AS m
            FROM (SELECT model, COUNT(*) c FROM base GROUP BY model)
        ),
        by_caller AS (
            SELECT ARRAY_AGG(STRUCT(caller, c) ORDER BY c DESC LIMIT 10) AS m
            FROM (SELECT caller, COUNT(*) c FROM base WHERE caller IS NOT NULL GROUP BY caller)
        ),
        latency AS (
            SELECT
                APPROX_QUANTILES(latency_ms, 100)[OFFSET(50)] AS p50,
                APPROX_QUANTILES(latency_ms, 100)[OFFSET(95)] AS p95,
                APPROX_QUANTILES(latency_ms, 100)[OFFSET(99)] AS p99
            FROM base
            WHERE latency_ms IS NOT NULL
        )
        SELECT
            (SELECT COUNT(*) FROM base) AS total,
            (SELECT COUNTIF(status_code >= 400) FROM base) AS errors,
            (SELECT m FROM by_model) AS by_model,
            (SELECT m FROM by_caller) AS by_caller,
            (SELECT AS STRUCT p50, p95, p99 FROM latency) AS latency
    """

    body = _json.dumps(
        {
            "query": sql,
            "useLegacySql": False,
            "queryParameters": [
                {
                    "name": "hours",
                    "parameterType": {"type": "INT64"},
                    "parameterValue": {"value": str(hours)},
                }
            ],
            "useQueryCache": True,
        }
    ).encode("utf-8")

    try:
        req = urllib.request.Request(
            f"https://bigquery.googleapis.com/bigquery/v2/projects/{project_id}/queries",
            data=body,
            headers={
                "Authorization": f"Bearer {creds.token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = _json.loads(resp.read())
    except Exception as exc:  # noqa: BLE001
        return {
            "error": "query_failed",
            "detail": str(exc),
            "hint": "MCP gateway SA may need roles/bigquery.dataViewer + roles/bigquery.jobUser, and the observability module must be deployed",
        }

    rows = data.get("rows", [])
    if not rows:
        return {
            "window_hours": hours,
            "total_requests": 0,
            "by_model": [],
            "by_caller": [],
            "error_rate_pct": 0.0,
            "latency_ms": {"p50": None, "p95": None, "p99": None},
            "note": "no data in window",
        }

    cells = rows[0]["f"]
    total = int(cells[0].get("v") or 0)
    errors = int(cells[1].get("v") or 0)

    def _array_of_struct(slot: dict) -> list[dict]:
        v = slot.get("v")
        if not v or not isinstance(v, list):
            return []
        out: list[dict] = []
        for item in v:
            entry = item.get("v", {}).get("f", []) if isinstance(item, dict) else []
            if len(entry) >= 2:
                out.append({"name": entry[0].get("v"), "count": int(entry[1].get("v") or 0)})
        return out

    by_model = _array_of_struct(cells[2])
    by_caller_raw = _array_of_struct(cells[3])
    by_caller = [
        {"caller": e["name"], "count": e["count"]} for e in by_caller_raw
    ]

    latency_struct = cells[4].get("v", {}).get("f", []) if cells[4].get("v") else []
    latency = {
        "p50": int(latency_struct[0]["v"]) if latency_struct and latency_struct[0].get("v") else None,
        "p95": int(latency_struct[1]["v"]) if len(latency_struct) > 1 and latency_struct[1].get("v") else None,
        "p99": int(latency_struct[2]["v"]) if len(latency_struct) > 2 and latency_struct[2].get("v") else None,
    }

    return {
        "window_hours": hours,
        "total_requests": total,
        "by_model": [{"model": m["name"], "count": m["count"]} for m in by_model],
        "by_caller": by_caller,
        "error_rate_pct": round(errors / total * 100, 2) if total else 0.0,
        "latency_ms": latency,
    }
