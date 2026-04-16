#!/usr/bin/env bash
# =============================================================================
# deploy-observability.sh
#
# Creates the BigQuery dataset, Cloud Logging sink, and deploys the admin
# dashboard Cloud Run service.
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
  run_cmd curl -sS -X POST \
    -H "Authorization: Bearer ${_bq_token}" \
    -H "Content-Type: application/json" \
    "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/datasets" \
    -d "{\"datasetReference\":{\"datasetId\":\"${DATASET_ID}\",\"projectId\":\"${PROJECT_ID}\"},\"location\":\"${CR_REGION}\",\"description\":\"Claude Code gateway logs\"}"
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

# --- Service account for admin-dashboard (idempotent) -----------------------
log_step "ensure service account ${SA_ID}"
if gcloud iam service-accounts describe "${SA_EMAIL}" \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
  log_info "SA ${SA_ID} already exists"
else
  run_cmd gcloud iam service-accounts create "${SA_ID}" \
    --project "${PROJECT_ID}" \
    --display-name="Admin Dashboard (observability)"
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
run_cmd gcloud run deploy "${SERVICE_NAME}" \
  --project "${PROJECT_ID}" \
  --region "${CR_REGION}" \
  --image "${IMAGE}" \
  --service-account "${SA_EMAIL}" \
  --ingress internal-and-cloud-load-balancing \
  --no-allow-unauthenticated \
  --min-instances 0 --max-instances 2 \
  --cpu 1 --memory 256Mi \
  --port 8080 \
  --set-env-vars "GOOGLE_CLOUD_PROJECT=${PROJECT_ID},BQ_DATASET=${DATASET_ID}" \
  --quiet

# --- Grant invoker to principals -------------------------------------------
if [[ -n "${PRINCIPALS}" ]]; then
  log_step "grant roles/run.invoker to principals"
  IFS=',' read -ra _principals <<<"${PRINCIPALS}"
  for p in "${_principals[@]}"; do
    p="${p## }"; p="${p%% }"
    [[ -z "${p}" ]] && continue
    run_cmd gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
      --project "${PROJECT_ID}" --region "${CR_REGION}" \
      --member="${p}" --role="roles/run.invoker" --quiet
  done
fi

URL="$(gcloud run services describe "${SERVICE_NAME}" \
        --project "${PROJECT_ID}" --region "${CR_REGION}" \
        --format="value(status.url)" 2>/dev/null || echo "")"
log_info "Admin Dashboard URL: ${URL}"
log_info "Note: BigQuery data appears ~60s after the first gateway request."
