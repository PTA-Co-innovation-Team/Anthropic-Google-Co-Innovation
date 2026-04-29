"""Admin Dashboard — observability UI for Claude Code gateway logs.

Serves a Chart.js dashboard that visualizes gateway request logs stored
in BigQuery. Deployed as a Cloud Run service alongside the gateways.

Endpoints:
    GET /            — serves the dashboard HTML
    GET /health      — liveness probe
    GET /api/*       — JSON data endpoints for the charts
"""

from __future__ import annotations

import logging
import os
import sys
import time
from typing import Any

from fastapi import FastAPI, Query
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PROJECT_ID = os.getenv("GOOGLE_CLOUD_PROJECT", "")
BQ_DATASET = os.getenv("BQ_DATASET", "claude_code_logs")

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    stream=sys.stdout,
    format='{"severity":"%(levelname)s","logger":"%(name)s","message":"%(message)s"}',
)
log = logging.getLogger("admin-dashboard")

# ---------------------------------------------------------------------------
# BigQuery client + table discovery
# ---------------------------------------------------------------------------

_bq_client = None
_table_name: str | None = None
_table_discovered_at: float = 0
_TABLE_CACHE_TTL = 300  # 5 minutes

# Query result cache: {cache_key: (timestamp, result)}
_query_cache: dict[str, tuple[float, Any]] = {}
_QUERY_CACHE_TTL = 30  # 30 seconds


def _get_bq_client():
    global _bq_client
    if _bq_client is None:
        from google.cloud import bigquery
        _bq_client = bigquery.Client(project=PROJECT_ID)
    return _bq_client


def _discover_table() -> str | None:
    """Find the log table name in the dataset. Cached for 5 minutes."""
    global _table_name, _table_discovered_at

    now = time.time()
    if _table_name and (now - _table_discovered_at) < _TABLE_CACHE_TTL:
        return _table_name

    try:
        client = _get_bq_client()
        query = f"""
            SELECT table_name
            FROM `{PROJECT_ID}.{BQ_DATASET}.INFORMATION_SCHEMA.TABLES`
            WHERE table_name LIKE 'run_googleapis_com_%'
            ORDER BY table_name
            LIMIT 5
        """
        rows = list(client.query(query).result())
        if rows:
            # Prefer stdout table; fall back to first match
            for row in rows:
                if "stdout" in row.table_name:
                    _table_name = row.table_name
                    break
            else:
                _table_name = rows[0].table_name
            _table_discovered_at = now
            log.info(f"discovered_table table={_table_name}")
            return _table_name
    except Exception as exc:
        log.warning(f"table_discovery_failed error={exc}")

    return None


def _run_query(cache_key: str, sql: str, params: list | None = None) -> list[dict]:
    """Run a BigQuery query with caching and graceful error handling."""
    now = time.time()
    cached = _query_cache.get(cache_key)
    if cached and (now - cached[0]) < _QUERY_CACHE_TTL:
        return cached[1]

    table = _discover_table()
    if not table:
        return []

    full_table = f"`{PROJECT_ID}.{BQ_DATASET}.{table}`"
    sql = sql.replace("{TABLE}", full_table)

    try:
        from google.cloud.bigquery import QueryJobConfig, ScalarQueryParameter
        config = QueryJobConfig()
        if params:
            config.query_parameters = [
                ScalarQueryParameter(p["name"], p["type"], p["value"])
                for p in params
            ]
        client = _get_bq_client()
        rows = [dict(row) for row in client.query(sql, job_config=config).result()]
        _query_cache[cache_key] = (now, rows)
        return rows
    except Exception as exc:
        log.warning(f"query_failed key={cache_key} error={exc}")
        return []


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(
    title="Claude Code Admin Dashboard",
    version="0.1.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/health")
async def health():
    return JSONResponse({"status": "ok", "component": "admin_dashboard"})


@app.get("/")
async def index():
    return FileResponse("static/index.html")


@app.get("/api/requests-per-day")
async def requests_per_day(days: int = Query(default=30, ge=1, le=365)):
    rows = _run_query(
        f"rpd-{days}",
        """
        SELECT
            FORMAT_DATE('%Y-%m-%d', DATE(timestamp)) AS date,
            COUNT(*) AS count
        FROM {TABLE}
        WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL @days DAY)
            AND jsonPayload.model IS NOT NULL
        GROUP BY date ORDER BY date
        """,
        [{"name": "days", "type": "INT64", "value": days}],
    )
    if not rows:
        return JSONResponse({"data": [], "note": "No log data yet. Send a request through the gateway to generate data."})
    return JSONResponse({"data": rows})


@app.get("/api/requests-by-model")
async def requests_by_model(days: int = Query(default=30, ge=1, le=365)):
    rows = _run_query(
        f"rbm-{days}",
        """
        SELECT
            jsonPayload.model AS model,
            COUNT(*) AS count
        FROM {TABLE}
        WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL @days DAY)
            AND jsonPayload.model IS NOT NULL
        GROUP BY model ORDER BY count DESC
        """,
        [{"name": "days", "type": "INT64", "value": days}],
    )
    if not rows:
        return JSONResponse({"data": [], "note": "No log data yet."})
    return JSONResponse({"data": rows})


@app.get("/api/top-callers")
async def top_callers(
    days: int = Query(default=30, ge=1, le=365),
    limit: int = Query(default=20, ge=1, le=100),
):
    rows = _run_query(
        f"tc-{days}-{limit}",
        """
        SELECT
            jsonPayload.caller AS caller,
            COUNT(*) AS count
        FROM {TABLE}
        WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL @days DAY)
            AND jsonPayload.caller IS NOT NULL
        GROUP BY caller ORDER BY count DESC
        LIMIT @limit
        """,
        [
            {"name": "days", "type": "INT64", "value": days},
            {"name": "limit", "type": "INT64", "value": limit},
        ],
    )
    if not rows:
        return JSONResponse({"data": [], "note": "No log data yet."})
    return JSONResponse({"data": rows})


@app.get("/api/error-rate")
async def error_rate(days: int = Query(default=30, ge=1, le=365)):
    rows = _run_query(
        f"er-{days}",
        """
        SELECT
            FORMAT_DATE('%Y-%m-%d', DATE(timestamp)) AS date,
            COUNT(*) AS total,
            COUNTIF(CAST(jsonPayload.status_code AS INT64) >= 400) AS errors
        FROM {TABLE}
        WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL @days DAY)
            AND jsonPayload.status_code IS NOT NULL
        GROUP BY date ORDER BY date
        """,
        [{"name": "days", "type": "INT64", "value": days}],
    )
    data = [
        {**r, "rate": round(r["errors"] / r["total"] * 100, 1) if r["total"] > 0 else 0}
        for r in rows
    ]
    if not data:
        return JSONResponse({"data": [], "note": "No log data yet."})
    return JSONResponse({"data": data})


@app.get("/api/latency-percentiles")
async def latency_percentiles(days: int = Query(default=7, ge=1, le=365)):
    rows = _run_query(
        f"lp-{days}",
        """
        SELECT
            APPROX_QUANTILES(
                CAST(jsonPayload.latency_ms_to_headers AS INT64), 100
            )[OFFSET(50)] AS p50,
            APPROX_QUANTILES(
                CAST(jsonPayload.latency_ms_to_headers AS INT64), 100
            )[OFFSET(95)] AS p95,
            APPROX_QUANTILES(
                CAST(jsonPayload.latency_ms_to_headers AS INT64), 100
            )[OFFSET(99)] AS p99
        FROM {TABLE}
        WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL @days DAY)
            AND jsonPayload.latency_ms_to_headers IS NOT NULL
        """,
        [{"name": "days", "type": "INT64", "value": days}],
    )
    if not rows:
        return JSONResponse({"p50": None, "p95": None, "p99": None, "note": "No log data yet."})
    return JSONResponse(rows[0])


@app.get("/api/recent-requests")
async def recent_requests(limit: int = Query(default=50, ge=1, le=200)):
    rows = _run_query(
        f"rr-{limit}",
        """
        SELECT
            FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', timestamp) AS timestamp,
            jsonPayload.caller AS caller,
            jsonPayload.model AS model,
            CAST(jsonPayload.status_code AS INT64) AS status_code,
            CAST(jsonPayload.latency_ms_to_headers AS INT64) AS latency_ms,
            jsonPayload.method AS method
        FROM {TABLE}
        WHERE jsonPayload.model IS NOT NULL
        ORDER BY timestamp DESC
        LIMIT @limit
        """,
        [{"name": "limit", "type": "INT64", "value": limit}],
    )
    if not rows:
        return JSONResponse({"data": [], "note": "No log data yet."})
    return JSONResponse({"data": rows})
