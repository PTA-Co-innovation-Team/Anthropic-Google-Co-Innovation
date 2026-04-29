#!/usr/bin/env bash
# =============================================================================
# deploy-observability.sh
#
# Creates the BigQuery dataset, Cloud Logging sink, BigQuery views for
# Looker Studio (if raw log table exists), and deploys the admin dashboard
# Cloud Run service.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

print_help() {
  cat <<'HELP'
Usage: deploy-observability.sh [--help] [--dry-run]
Creates the observability pipeline (BQ dataset + log sink) and deploys
the admin dashboard. Reads PROJECT_ID, FALLBACK_REGION, and PRINCIPALS
from the environment.
HELP
}

parse_common_flags "$@"

: "${PROJECT_ID:?PROJECT_ID must be set}"
: "${FALLBACK_REGION:?FALLBACK_REGION must be set}"
: "${PRINCIPALS:=}"

require_cmd gcloud

REPO_ROOT="$(resolve_repo_root)"

CR_REGION="${FALLBACK_REGION}"
AR_REPO="claude-code-vertex-gcp"
DATASET_ID="claude_code_logs"
SINK_NAME="claude-code-gateway-logs"
SERVICE_NAME="admin-dashboard"
SA_ID="admin-dashboard"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_TAG="$(date -u +%Y%m%d-%H%M%S)"
IMAGE="${CR_REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${IMAGE_TAG}"

# --- BigQuery dataset (idempotent) ------------------------------------------
# Uses the BigQuery REST API directly via gcloud access tokens for
# compatibility with corporate proxies / enterprise certificate setups
# (the bq CLI has known issues with ECP proxies).
log_step "ensure BigQuery dataset ${DATASET_ID}"
_bq_token="$(gcloud auth print-access-token 2>/dev/null)"
_ds_check="$(curl -sS -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${_bq_token}" \
  "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/datasets/${DATASET_ID}" 2>/dev/null)"

if [[ "${_ds_check}" == "200" ]]; then
  log_info "dataset ${DATASET_ID} already exists"
else
  log_info "creating dataset ${DATASET_ID}"
  _ds_payload="$(python3 -c '
import json, os, sys
print(json.dumps({
    "datasetReference": {
        "datasetId": sys.argv[1],
        "projectId": sys.argv[2],
    },
    "location": sys.argv[3],
    "description": "Claude Code gateway logs",
}))
' "${DATASET_ID}" "${PROJECT_ID}" "${CR_REGION}")"
  run_cmd curl -sS -X POST \
    -H "Authorization: Bearer ${_bq_token}" \
    -H "Content-Type: application/json" \
    "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/datasets" \
    -d "${_ds_payload}"
fi

# --- Cloud Logging sink (idempotent) ----------------------------------------
log_step "ensure Cloud Logging sink ${SINK_NAME}"
if gcloud logging sinks describe "${SINK_NAME}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  log_info "sink ${SINK_NAME} already exists"
else
  run_cmd gcloud logging sinks create "${SINK_NAME}" \
    "bigquery.googleapis.com/projects/${PROJECT_ID}/datasets/${DATASET_ID}" \
    --project "${PROJECT_ID}" \
    --log-filter='resource.type="cloud_run_revision" AND resource.labels.service_name=~"^(llm-gateway|mcp-gateway)$"' \
    --use-partitioned-tables \
    --description="Routes gateway request logs into BigQuery for the admin dashboard."
fi

# --- Grant sink writer access to BigQuery -----------------------------------
log_step "grant sink writer identity access to BigQuery"
SINK_SA="$(gcloud logging sinks describe "${SINK_NAME}" \
  --project "${PROJECT_ID}" \
  --format="value(writerIdentity)" 2>/dev/null || echo "")"

if [[ -n "${SINK_SA}" ]]; then
  run_cmd gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="${SINK_SA}" \
    --role="roles/bigquery.dataEditor" \
    --condition=None --quiet
else
  log_warn "could not determine sink writer identity; IAM grant skipped"
fi

# --- BigQuery views for Looker Studio (non-fatal) ---------------------------
# Discover the raw log table name, then create/update stable views that
# Looker Studio can connect to as data sources. Failures here are warnings —
# view creation must NEVER block the admin dashboard deployment.
log_step "create BigQuery views for Looker Studio"
LOG_TABLE_NAME=""

_tables_resp="$(curl -sS \
  -H "Authorization: Bearer ${_bq_token}" \
  "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/datasets/${DATASET_ID}/tables" 2>/dev/null || echo "")"

if [[ -n "${_tables_resp}" ]]; then
  LOG_TABLE_NAME="$(echo "${_tables_resp}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    tables = data.get("tables", [])
    for t in tables:
        tid = t.get("tableReference", {}).get("tableId", "")
        if tid.startswith("run_googleapis_com_"):
            print(tid)
            break
except Exception:
    pass
' 2>/dev/null || echo "")"
fi

if [[ -z "${LOG_TABLE_NAME}" ]]; then
  log_warn "no run_googleapis_com_* table found in ${DATASET_ID} — views skipped"
  log_warn "(tables appear ~60s after the first gateway request; re-run to create views)"
else
  log_info "discovered raw table: ${LOG_TABLE_NAME}"

  _create_or_update_view() {
    local view_id="$1" view_sql="$2"
    local payload
    payload="$(python3 -c '
import json, sys
print(json.dumps({
    "tableReference": {
        "projectId": sys.argv[1],
        "datasetId": sys.argv[2],
        "tableId": sys.argv[3],
    },
    "view": {
        "query": sys.argv[4],
        "useLegacySql": False,
    },
}))
' "${PROJECT_ID}" "${DATASET_ID}" "${view_id}" "${view_sql}")"

    local resp http_code
    http_code="$(curl -sS -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${_bq_token}" \
      "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/datasets/${DATASET_ID}/tables/${view_id}" 2>/dev/null)"

    if [[ "${http_code}" == "200" ]]; then
      resp="$(curl -sS -w "\n%{http_code}" -X PUT \
        -H "Authorization: Bearer ${_bq_token}" \
        -H "Content-Type: application/json" \
        "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/datasets/${DATASET_ID}/tables/${view_id}" \
        -d "${payload}" 2>/dev/null)"
    else
      resp="$(curl -sS -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${_bq_token}" \
        -H "Content-Type: application/json" \
        "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/datasets/${DATASET_ID}/tables" \
        -d "${payload}" 2>/dev/null)"
    fi

    local code
    code="$(echo "${resp}" | tail -1)"
    if [[ "${code}" =~ ^2 ]]; then
      log_info "  ${view_id} — OK"
    else
      log_warn "  ${view_id} — failed (HTTP ${code})"
    fi
  }

  _FQ_TABLE="\`${PROJECT_ID}.${DATASET_ID}.${LOG_TABLE_NAME}\`"

  _create_or_update_view "v_requests_summary" \
    "SELECT DATE(timestamp) AS date, jsonPayload.model AS model, jsonPayload.caller AS caller, jsonPayload.vertex_region AS vertex_region, COUNT(*) AS request_count, COUNTIF(CAST(jsonPayload.status_code AS INT64) >= 400) AS error_count FROM ${_FQ_TABLE} WHERE jsonPayload.model IS NOT NULL GROUP BY date, model, caller, vertex_region"

  _create_or_update_view "v_error_analysis" \
    "SELECT DATE(timestamp) AS date, jsonPayload.model AS model, CAST(jsonPayload.status_code AS INT64) AS status_code, jsonPayload.caller AS caller, COUNT(*) AS count FROM ${_FQ_TABLE} WHERE CAST(jsonPayload.status_code AS INT64) >= 400 GROUP BY date, model, status_code, caller"

  _create_or_update_view "v_latency_stats" \
    "SELECT timestamp, DATE(timestamp) AS date, jsonPayload.model AS model, jsonPayload.caller AS caller, CAST(jsonPayload.latency_ms_to_headers AS INT64) AS latency_ms FROM ${_FQ_TABLE} WHERE jsonPayload.latency_ms_to_headers IS NOT NULL"

  _create_or_update_view "v_top_callers" \
    "SELECT jsonPayload.caller AS caller, jsonPayload.model AS model, COUNT(*) AS request_count, COUNTIF(CAST(jsonPayload.status_code AS INT64) >= 400) AS error_count, MIN(timestamp) AS first_seen, MAX(timestamp) AS last_seen FROM ${_FQ_TABLE} WHERE jsonPayload.caller IS NOT NULL GROUP BY caller, model"

  _create_or_update_view "v_recent_requests" \
    "SELECT timestamp, jsonPayload.caller AS caller, jsonPayload.caller_source AS caller_source, jsonPayload.method AS method, jsonPayload.model AS model, CAST(jsonPayload.status_code AS INT64) AS status_code, CAST(jsonPayload.latency_ms_to_headers AS INT64) AS latency_ms, jsonPayload.vertex_region AS vertex_region, jsonPayload.path AS path FROM ${_FQ_TABLE} WHERE jsonPayload.model IS NOT NULL"
fi

# --- Service account for admin-dashboard (idempotent) -----------------------
log_step "ensure service account ${SA_ID}"
if gcloud iam service-accounts describe "${SA_EMAIL}" \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
  log_info "SA ${SA_ID} already exists"
else
  run_cmd gcloud iam service-accounts create "${SA_ID}" \
    --project "${PROJECT_ID}" \
    --display-name="Admin Dashboard (observability)"
  wait_for_sa "${SA_EMAIL}"
fi

for role in roles/bigquery.dataViewer roles/bigquery.jobUser roles/logging.logWriter; do
  run_cmd gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None --quiet
done

# --- Build + push dashboard image -------------------------------------------
log_step "build + push ${IMAGE}"
run_cmd gcloud builds submit "${REPO_ROOT}/dashboard" \
  --project "${PROJECT_ID}" \
  --tag "${IMAGE}" \
  --region "${CR_REGION}"

# --- Deploy Cloud Run service -----------------------------------------------
log_step "deploy Cloud Run service ${SERVICE_NAME}"

if [[ "${ENABLE_GLB:-false}" == "true" ]]; then
  INGRESS_FLAG="--ingress internal-and-cloud-load-balancing"
  AUTH_FLAG="--no-allow-unauthenticated"
elif [[ "${ENABLE_VPC_INTERNAL:-false}" == "true" ]]; then
  INGRESS_FLAG="--ingress internal"
  AUTH_FLAG="--no-allow-unauthenticated"
else
  INGRESS_FLAG="--ingress all"
  AUTH_FLAG="--no-allow-unauthenticated"
fi

run_cmd gcloud run deploy "${SERVICE_NAME}" \
  --project "${PROJECT_ID}" \
  --region "${CR_REGION}" \
  --image "${IMAGE}" \
  --service-account "${SA_EMAIL}" \
  ${INGRESS_FLAG} \
  ${AUTH_FLAG} \
  --min-instances 0 --max-instances 2 \
  --cpu 1 --memory 256Mi \
  --port 8080 \
  --set-env-vars "GOOGLE_CLOUD_PROJECT=${PROJECT_ID},BQ_DATASET=${DATASET_ID}" \
  --quiet

# --- Grant invoker to principals -------------------------------------------
grant_run_invoker "${SERVICE_NAME}" "${PROJECT_ID}" "${CR_REGION}" "${PRINCIPALS}"

URL="$(gcloud run services describe "${SERVICE_NAME}" \
        --project "${PROJECT_ID}" --region "${CR_REGION}" \
        --format="value(status.url)" 2>/dev/null || echo "")"
log_info "Admin Dashboard URL: ${URL}"
log_info "Note: BigQuery data appears ~60s after the first gateway request."
if [[ -n "${LOG_TABLE_NAME:-}" ]]; then
  log_info "Looker Studio: run scripts/setup-looker-studio.sh for a pre-configured report URL"
fi
