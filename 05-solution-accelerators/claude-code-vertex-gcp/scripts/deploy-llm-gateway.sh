#!/usr/bin/env bash
# =============================================================================
# deploy-llm-gateway.sh
#
# Builds the LLM gateway container, pushes to Artifact Registry, and
# deploys a Cloud Run service with the right flags:
#   * --no-invoker-iam-check (Cloud Run IAM rejects ADC access tokens;
#     app-level token_validation.py middleware handles auth instead)
#   * ENABLE_TOKEN_VALIDATION=1 with ALLOWED_PRINCIPALS
#   * dedicated service account with roles/aiplatform.user
#
# Idempotent: re-running rebuilds + redeploys, which Cloud Run handles
# with a new revision.
#
# Reads from environment (populated by deploy.sh):
#   PROJECT_ID, REGION, FALLBACK_REGION, PRINCIPALS (comma-separated)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

print_help() {
  cat <<'HELP'
Usage: deploy-llm-gateway.sh [--help] [--dry-run]

Builds + deploys the LLM gateway. Reads PROJECT_ID, REGION,
FALLBACK_REGION, and PRINCIPALS from the environment (deploy.sh sets
them). Safe to re-run.
HELP
}

parse_common_flags "$@"

: "${PROJECT_ID:?PROJECT_ID must be set}"
: "${REGION:?REGION must be set}"
: "${FALLBACK_REGION:?FALLBACK_REGION must be set}"
: "${PRINCIPALS:=}"

require_cmd gcloud
REPO_ROOT="$(resolve_repo_root)"

# GCE/Cloud Run region. We pass the fallback for multi-region Vertex
# values like "global".
CR_REGION="${FALLBACK_REGION}"
AR_REPO="claude-code-vertex-gcp"
SERVICE_NAME="llm-gateway"
SA_ID="llm-gateway"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_TAG="$(date -u +%Y%m%d-%H%M%S)"
IMAGE="${CR_REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${IMAGE_TAG}"

# --- Artifact Registry repo (idempotent) ------------------------------------
log_step "ensure Artifact Registry repo"
if ! gcloud artifacts repositories describe "${AR_REPO}" \
     --project "${PROJECT_ID}" --location "${CR_REGION}" >/dev/null 2>&1; then
  run_cmd gcloud artifacts repositories create "${AR_REPO}" \
    --project "${PROJECT_ID}" --location "${CR_REGION}" \
    --repository-format=docker \
    --description="Claude Code on Vertex container images"
fi

# --- Dedicated service account ----------------------------------------------
log_step "ensure service account ${SA_EMAIL}"
if ! gcloud iam service-accounts describe "${SA_EMAIL}" \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
  run_cmd gcloud iam service-accounts create "${SA_ID}" \
    --project "${PROJECT_ID}" \
    --display-name="LLM Gateway (Claude Code → Vertex)"
  wait_for_sa "${SA_EMAIL}"
fi

# --- SA IAM: Vertex caller + log writer -------------------------------------
log_step "grant SA roles/aiplatform.user and roles/logging.logWriter"
for role in roles/aiplatform.user roles/logging.logWriter; do
  run_cmd gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" --role="${role}" --condition=None --quiet
done

# --- Build + push image ------------------------------------------------------
log_step "build + push ${IMAGE}"
run_cmd gcloud builds submit "${REPO_ROOT}/gateway" \
  --project "${PROJECT_ID}" \
  --tag "${IMAGE}" \
  --region "${CR_REGION}"

# --- Deploy Cloud Run service -----------------------------------------------
log_step "deploy Cloud Run service ${SERVICE_NAME}"

ALLOWED="${PRINCIPALS}"
if [[ "${ENABLE_VM:-false}" == "true" ]]; then
  ALLOWED="${ALLOWED},serviceAccount:claude-code-dev-vm@${PROJECT_ID}.iam.gserviceaccount.com"
fi

if [[ "${ENABLE_GLB:-false}" == "true" ]]; then
  INGRESS_FLAG="--ingress internal-and-cloud-load-balancing"
elif [[ "${ENABLE_VPC_INTERNAL:-false}" == "true" ]]; then
  INGRESS_FLAG="--ingress internal"
else
  INGRESS_FLAG="--ingress all"
fi

ENV_VARS="^;^GOOGLE_CLOUD_PROJECT=${PROJECT_ID};VERTEX_DEFAULT_REGION=${REGION};ENABLE_TOKEN_VALIDATION=1;ALLOWED_PRINCIPALS=${ALLOWED}"

run_cmd gcloud run deploy "${SERVICE_NAME}" \
  --project "${PROJECT_ID}" \
  --region "${CR_REGION}" \
  --image "${IMAGE}" \
  --service-account "${SA_EMAIL}" \
  ${INGRESS_FLAG} \
  --no-allow-unauthenticated \
  --no-invoker-iam-check \
  --min-instances 0 --max-instances 10 \
  --cpu 1 --memory 512Mi \
  --port 8080 \
  --set-env-vars "${ENV_VARS}" \
  --quiet

# --- Print the URL ----------------------------------------------------------
URL="$(gcloud run services describe "${SERVICE_NAME}" \
        --project "${PROJECT_ID}" --region "${CR_REGION}" \
        --format="value(status.url)" 2>/dev/null || echo "")"
log_info "LLM gateway URL: ${URL}"
