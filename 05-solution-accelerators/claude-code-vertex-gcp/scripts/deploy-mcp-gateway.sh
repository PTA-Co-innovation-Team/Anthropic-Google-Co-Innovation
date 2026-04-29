#!/usr/bin/env bash
# =============================================================================
# deploy-mcp-gateway.sh
#
# Same shape as deploy-llm-gateway.sh but for the MCP gateway. Starts
# the service account with only roles/logging.logWriter; tool-specific
# roles are granted separately (see mcp-gateway/ADD_YOUR_OWN_TOOL.md).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

print_help() {
  cat <<'HELP'
Usage: deploy-mcp-gateway.sh [--help] [--dry-run]

Builds + deploys the MCP gateway. Reads PROJECT_ID, REGION (Vertex
region), FALLBACK_REGION (Cloud Run region), and PRINCIPALS from the
environment.
HELP
}

parse_common_flags "$@"

: "${PROJECT_ID:?PROJECT_ID must be set}"
: "${REGION:?REGION must be set}"
: "${FALLBACK_REGION:?FALLBACK_REGION must be set}"
: "${PRINCIPALS:=}"

require_cmd gcloud
REPO_ROOT="$(resolve_repo_root)"

CR_REGION="${FALLBACK_REGION}"
AR_REPO="claude-code-vertex-gcp"
SERVICE_NAME="mcp-gateway"
SA_ID="mcp-gateway"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_TAG="$(date -u +%Y%m%d-%H%M%S)"
IMAGE="${CR_REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${IMAGE_TAG}"

log_step "ensure Artifact Registry repo"
if ! gcloud artifacts repositories describe "${AR_REPO}" \
     --project "${PROJECT_ID}" --location "${CR_REGION}" >/dev/null 2>&1; then
  run_cmd gcloud artifacts repositories create "${AR_REPO}" \
    --project "${PROJECT_ID}" --location "${CR_REGION}" \
    --repository-format=docker \
    --description="Claude Code on Vertex container images"
fi

log_step "ensure service account ${SA_EMAIL}"
if ! gcloud iam service-accounts describe "${SA_EMAIL}" \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
  run_cmd gcloud iam service-accounts create "${SA_ID}" \
    --project "${PROJECT_ID}" \
    --display-name="MCP Gateway (Claude Code tools)"
  wait_for_sa "${SA_EMAIL}"
fi

log_step "grant SA roles/logging.logWriter"
run_cmd gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/logging.logWriter" \
  --condition=None --quiet

log_step "build + push ${IMAGE}"
run_cmd gcloud builds submit "${REPO_ROOT}/mcp-gateway" \
  --project "${PROJECT_ID}" \
  --tag "${IMAGE}" \
  --region "${CR_REGION}"

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
  --min-instances 0 --max-instances 5 \
  --cpu 1 --memory 512Mi \
  --port 8080 \
  --set-env-vars "${ENV_VARS}" \
  --quiet

URL="$(gcloud run services describe "${SERVICE_NAME}" \
        --project "${PROJECT_ID}" --region "${CR_REGION}" \
        --format="value(status.url)" 2>/dev/null || echo "")"
log_info "MCP gateway URL: ${URL}"
