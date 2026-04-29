#!/usr/bin/env bash
# =============================================================================
# deploy-dev-portal.sh
#
# Substitutes the __LLM_GATEWAY_URL__ / __MCP_GATEWAY_URL__ / __PROJECT_ID__ /
# __REGION__ placeholders in dev-portal/public/index.html, builds the
# nginx image, and deploys a Cloud Run service.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

print_help() {
  cat <<'HELP'
Usage: deploy-dev-portal.sh [--help] [--dry-run]
Builds + deploys the dev portal. Reads PROJECT_ID, REGION,
FALLBACK_REGION, and PRINCIPALS from the environment.
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
SERVICE_NAME="dev-portal"
IMAGE_TAG="$(date -u +%Y%m%d-%H%M%S)"
IMAGE="${CR_REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${IMAGE_TAG}"

# --- Look up gateway URLs for the substitution ------------------------------
# In GLB mode, the portal should show the GLB URL (single entry point) rather
# than direct Cloud Run URLs (which are unreachable due to ingress restriction).
LLM_URL=""
MCP_URL=""
if [[ "${ENABLE_GLB:-false}" == "true" ]]; then
  GLB_URL="$(resolve_glb_url "${PROJECT_ID}" || echo "")"
  if [[ -n "${GLB_URL}" ]]; then
    LLM_URL="${GLB_URL}"
    MCP_URL="${GLB_URL}"
  else
    log_warn "GLB enabled but no GLB URL found — falling back to direct Cloud Run URLs"
  fi
fi

if [[ -z "${LLM_URL}" ]]; then
  LLM_URL="$(gcloud run services describe llm-gateway \
               --project "${PROJECT_ID}" --region "${CR_REGION}" \
               --format="value(status.url)" 2>/dev/null || echo "")"
fi
if [[ -z "${MCP_URL}" ]]; then
  MCP_URL="$(gcloud run services describe mcp-gateway \
               --project "${PROJECT_ID}" --region "${CR_REGION}" \
               --format="value(status.url)" 2>/dev/null || echo "")"
fi

# --- Prepare a build context with substituted placeholders ------------------
BUILD_DIR="$(mktemp -d -t portal-build-XXXXXX)"
trap 'rm -rf "${BUILD_DIR}"' EXIT
cp -r "${REPO_ROOT}/dev-portal/." "${BUILD_DIR}/"

# In-place substitution of the placeholders. Use sed with a delimiter
# unlikely to appear in URLs.
for f in "${BUILD_DIR}/public/index.html"; do
  sed -i \
    -e "s#__LLM_GATEWAY_URL__#${LLM_URL}#g" \
    -e "s#__MCP_GATEWAY_URL__#${MCP_URL}#g" \
    -e "s#__PROJECT_ID__#${PROJECT_ID}#g" \
    -e "s#__REGION__#${REGION}#g" \
    "${f}"
done

log_step "build + push ${IMAGE}"
run_cmd gcloud builds submit "${BUILD_DIR}" \
  --project "${PROJECT_ID}" \
  --tag "${IMAGE}" \
  --region "${CR_REGION}"

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
  ${INGRESS_FLAG} \
  ${AUTH_FLAG} \
  --min-instances 0 --max-instances 2 \
  --cpu 1 --memory 256Mi \
  --port 8080 \
  --quiet

grant_run_invoker "${SERVICE_NAME}" "${PROJECT_ID}" "${CR_REGION}" "${PRINCIPALS}"

URL="$(gcloud run services describe "${SERVICE_NAME}" \
        --project "${PROJECT_ID}" --region "${CR_REGION}" \
        --format="value(status.url)" 2>/dev/null || echo "")"
log_info "Dev portal URL: ${URL}"
