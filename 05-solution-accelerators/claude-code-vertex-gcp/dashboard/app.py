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

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PROJECT_ID = os.getenv("GOOGLE_CLOUD_PROJECT", "")
BQ_DATASET = os.getenv("BQ_DATASET", "claude_code_logs")

# Settings tab configuration. Default empty = nobody can edit (settings
# tab is read-only / hidden). Customers explicitly opt-in editors via
# the EDITORS env var, which is a CSV of email addresses.
EDITORS = frozenset(
    e.strip().lower() for e in os.getenv("EDITORS", "").split(",") if e.strip()
)
LLM_GATEWAY_SERVICE = os.getenv("LLM_GATEWAY_SERVICE", "llm-gateway")
LLM_GATEWAY_REGION = os.getenv("LLM_GATEWAY_REGION", "us-central1")

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
            COUNTIF(SAFE_CAST(jsonPayload.status_code AS INT64) >= 400) AS errors
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
                SAFE_CAST(jsonPayload.latency_ms_to_headers AS INT64), 100
            )[OFFSET(50)] AS p50,
            APPROX_QUANTILES(
                SAFE_CAST(jsonPayload.latency_ms_to_headers AS INT64), 100
            )[OFFSET(95)] AS p95,
            APPROX_QUANTILES(
                SAFE_CAST(jsonPayload.latency_ms_to_headers AS INT64), 100
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
            SAFE_CAST(jsonPayload.status_code AS INT64) AS status_code,
            SAFE_CAST(jsonPayload.latency_ms_to_headers AS INT64) AS latency_ms,
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


# ---------------------------------------------------------------------------
# Token-cap observability panels (introduced with L3)
# ---------------------------------------------------------------------------

@app.get("/api/tokens-by-caller")
async def tokens_by_caller(hours: int = Query(default=24, ge=1, le=720)):
    """Total tokens consumed per caller over the last N hours.

    Reads the token_debit log entries the gateway emits after every
    successful response. Each entry carries input_tokens + output_tokens.
    Aggregated by caller, ordered by total consumption.
    """
    rows = _run_query(
        f"tbc-{hours}",
        """
        SELECT
            jsonPayload.caller AS caller,
            SUM(SAFE_CAST(jsonPayload.input_tokens  AS INT64)) AS input_tokens,
            SUM(SAFE_CAST(jsonPayload.output_tokens AS INT64)) AS output_tokens,
            SUM(SAFE_CAST(jsonPayload.total_tokens  AS INT64)) AS total_tokens,
            COUNT(*) AS request_count
        FROM {TABLE}
        WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL @hours HOUR)
            AND jsonPayload.message = "token_debit"
            AND jsonPayload.caller IS NOT NULL
        GROUP BY caller
        ORDER BY total_tokens DESC
        LIMIT 25
        """,
        [{"name": "hours", "type": "INT64", "value": hours}],
    )
    if not rows:
        return JSONResponse({"data": [], "note": "No token-debit data yet. Token cap may be off (TOKEN_LIMIT_PER_MIN unset) or no requests have flowed through since enabling."})
    return JSONResponse({"data": rows})


@app.get("/api/token-limit-rejections")
async def token_limit_rejections(hours: int = Query(default=24, ge=1, le=720)):
    """Number of requests rejected by the token-cap, per caller, over time.

    Rejected requests emit a `token_limited` warning log. This endpoint
    counts those, broken down by caller. A non-zero count for any caller
    suggests their cap is too tight (or they're a heavy user worth
    talking to).
    """
    rows = _run_query(
        f"tlr-{hours}",
        """
        SELECT
            jsonPayload.caller AS caller,
            COUNT(*) AS rejection_count
        FROM {TABLE}
        WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL @hours HOUR)
            AND jsonPayload.message = "token_limited"
            AND jsonPayload.caller IS NOT NULL
        GROUP BY caller
        ORDER BY rejection_count DESC
        """,
        [{"name": "hours", "type": "INT64", "value": hours}],
    )
    if not rows:
        return JSONResponse({"data": [], "note": "No token-limit rejections in the window — either nobody is hitting the cap or the cap is off."})
    return JSONResponse({"data": rows})


@app.get("/api/token-burn-rate")
async def token_burn_rate(hours: int = Query(default=24, ge=1, le=720)):
    """Rolling token consumption per minute, project-wide.

    Useful for a "are we approaching aggregate quota" view at a glance,
    independent of per-caller caps. Reads the same token_debit entries
    as /api/tokens-by-caller but bins by minute.
    """
    rows = _run_query(
        f"tbr-{hours}",
        """
        SELECT
            FORMAT_TIMESTAMP('%Y-%m-%d %H:%M', timestamp) AS minute,
            SUM(SAFE_CAST(jsonPayload.total_tokens AS INT64)) AS tokens
        FROM {TABLE}
        WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL @hours HOUR)
            AND jsonPayload.message = "token_debit"
        GROUP BY minute
        ORDER BY minute
        """,
        [{"name": "hours", "type": "INT64", "value": hours}],
    )
    if not rows:
        return JSONResponse({"data": [], "note": "No token-debit data yet."})
    return JSONResponse({"data": rows})


# ---------------------------------------------------------------------------
# Settings tab — scoped to the LLM gateway's six traffic-policy env vars
# ---------------------------------------------------------------------------

# The set of env vars the dashboard is allowed to mutate. Anything not on
# this list is rejected at the API layer — even if the caller is on the
# EDITORS list. This is the package's blast-radius guarantee: the dashboard
# can never touch CPU, memory, scaling, IAM, ingress, or anything else
# Cloud-Run-related except these six knobs.
_EDITABLE_VARS = frozenset({
    "RATE_LIMIT_PER_MIN",
    "RATE_LIMIT_BURST",
    "TOKEN_LIMIT_PER_MIN",
    "TOKEN_LIMIT_BURST",
    "ALLOWED_MODELS",
    "MODEL_REWRITE",
})


class PolicyUpdate(BaseModel):
    """Body for POST /api/policy.

    Each field is optional; only present keys are mutated. Pass None
    (or simply omit) to leave a value unchanged. Pass an empty string
    to remove a value (returns the gateway to that variable's default).
    """
    RATE_LIMIT_PER_MIN: str | None = Field(default=None)
    RATE_LIMIT_BURST: str | None = Field(default=None)
    TOKEN_LIMIT_PER_MIN: str | None = Field(default=None)
    TOKEN_LIMIT_BURST: str | None = Field(default=None)
    ALLOWED_MODELS: str | None = Field(default=None)
    MODEL_REWRITE: str | None = Field(default=None)


def _editor_email_from_request(request: Request) -> str | None:
    """Pull the editor's email out of the IAP-injected header.

    IAP injects ``X-Goog-Authenticated-User-Email`` on every authenticated
    request, prefixed with ``accounts.google.com:``. We strip the prefix
    and lower-case for matching against EDITORS.
    """
    raw = request.headers.get("x-goog-authenticated-user-email", "")
    if not raw:
        return None
    return raw.split(":", 1)[1].lower() if ":" in raw else raw.lower()


def _validate_policy_value(name: str, value: str) -> tuple[bool, str]:
    """Same shape checks as preflight.sh, server-side.

    Returns (ok, reason). ``ok=False`` rejects the change with reason
    surfaced to the editor's UI.
    """
    if value == "":
        return True, ""  # empty value = unset = valid
    if name in {"RATE_LIMIT_PER_MIN", "RATE_LIMIT_BURST",
                "TOKEN_LIMIT_PER_MIN", "TOKEN_LIMIT_BURST"}:
        if not value.isdigit() or int(value) <= 0:
            return False, f"{name} must be a positive integer"
    elif name == "ALLOWED_MODELS":
        # CSV of model strings, no spaces
        for entry in value.split(","):
            if not entry.strip() or any(c in entry for c in (" ", "\t")):
                return False, f"ALLOWED_MODELS entries must be comma-separated, no spaces (got {entry!r})"
    elif name == "MODEL_REWRITE":
        for entry in value.split(","):
            entry = entry.strip()
            if "=" not in entry or not all(p.strip() for p in entry.split("=", 1)):
                return False, f"MODEL_REWRITE entries must be from=to (got {entry!r})"
    return True, ""


@app.get("/api/policy")
async def get_policy(request: Request):
    """Return the current values of the six editable env vars on llm-gateway.

    Anyone allowed to reach the dashboard can READ the current policy.
    Editing is gated separately (POST /api/policy).
    """
    try:
        from google.cloud import run_v2
        client = run_v2.ServicesClient()
        name = f"projects/{PROJECT_ID}/locations/{LLM_GATEWAY_REGION}/services/{LLM_GATEWAY_SERVICE}"
        service = client.get_service(name=name)
        env_map: dict[str, str] = {}
        for container in service.template.containers:
            for env in container.env:
                if env.name in _EDITABLE_VARS:
                    env_map[env.name] = env.value
    except Exception as exc:  # noqa: BLE001
        log.warning(f"get_policy failed: {exc}")
        return JSONResponse({"error": "policy_read_failed", "detail": str(exc)}, status_code=502)

    editor_email = _editor_email_from_request(request)
    can_edit = bool(editor_email and editor_email in EDITORS) if EDITORS else False
    return JSONResponse({
        "values": {var: env_map.get(var, "") for var in _EDITABLE_VARS},
        "can_edit": can_edit,
        "editor_email": editor_email,
        "editors_configured": bool(EDITORS),
    })


@app.post("/api/policy")
async def update_policy(request: Request, body: PolicyUpdate):
    """Mutate one or more env vars on llm-gateway. Editor-gated.

    Auth chain:
      1. IAP / Cloud Run already authenticated the caller (header injected).
      2. Editor must be in EDITORS env var.
      3. Each requested change is validated for shape (matches preflight).
      4. If all checks pass, call Cloud Run admin API to update the service.
      5. Emit a structured `policy_change` log entry naming the editor and
         the diff. Cloud Run's own admin-activity log captures the SA-side
         mutation in parallel.
    """
    if not EDITORS:
        raise HTTPException(403, "settings tab disabled (EDITORS env var is empty)")

    editor = _editor_email_from_request(request)
    if not editor:
        raise HTTPException(401, "no IAP-authenticated identity on the request")
    if editor not in EDITORS:
        log.warning(f"policy_edit_denied editor={editor}")
        raise HTTPException(403, f"{editor} is not in the EDITORS allowlist")

    # Build the diff and validate.
    changes = {k: v for k, v in body.model_dump().items() if v is not None}
    if not changes:
        return JSONResponse({"updated": [], "note": "no changes provided"})

    for k, v in changes.items():
        ok, reason = _validate_policy_value(k, v)
        if not ok:
            raise HTTPException(400, reason)

    # Apply by reading current service, mutating env, replacing.
    try:
        from google.cloud import run_v2
        client = run_v2.ServicesClient()
        name = f"projects/{PROJECT_ID}/locations/{LLM_GATEWAY_REGION}/services/{LLM_GATEWAY_SERVICE}"
        service = client.get_service(name=name)

        # Build the new env list: keep everything not editable; replace
        # editable keys per `changes`; remove keys that are explicitly empty.
        for container in service.template.containers:
            existing = list(container.env)
            new_env = []
            applied: set[str] = set()
            for env in existing:
                if env.name in changes:
                    val = changes[env.name]
                    if val:  # non-empty → set/update
                        new_env.append(run_v2.EnvVar(name=env.name, value=val))
                    # empty val → drop this entry (var becomes unset)
                    applied.add(env.name)
                else:
                    new_env.append(env)
            # Add brand-new vars (in changes but not in existing)
            for k, v in changes.items():
                if k not in applied and v:
                    new_env.append(run_v2.EnvVar(name=k, value=v))
            del container.env[:]
            container.env.extend(new_env)

        operation = client.update_service(service=service)
        operation.result(timeout=120)  # block until rollout completes
    except Exception as exc:  # noqa: BLE001
        log.error(f"policy_update_failed editor={editor} error={exc}")
        raise HTTPException(502, f"Cloud Run update failed: {exc}") from exc

    log.warning(  # WARNING so it stands out from chart-data INFO entries
        "policy_change",
        extra={"editor": editor, "diff": changes},
    )
    return JSONResponse({"updated": list(changes.keys()), "editor": editor})
