#!/usr/bin/env bash
# =============================================================================
# deploy-llm-gateway.sh
#
# Builds the LLM gateway container, pushes to Artifact Registry, and
# deploys a Cloud Run service with the right flags:
#   * ingress = internal-and-cloud-load-balancing
#   * --no-allow-unauthenticated  (IAM enforces invoker)
#   * dedicated service account with roles/aiplatform.user
#   * per-principal roles/run.invoker
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
run_cmd gcloud run deploy "${SERVICE_NAME}" \
  --project "${PROJECT_ID}" \
  --region "${CR_REGION}" \
  --image "${IMAGE}" \
  --service-account "${SA_EMAIL}" \
  --ingress internal-and-cloud-load-balancing \
  --no-allow-unauthenticated \
  --min-instances 0 --max-instances 10 \
  --cpu 1 --memory 512Mi \
  --port 8080 \
  --set-env-vars "GOOGLE_CLOUD_PROJECT=${PROJECT_ID},VERTEX_DEFAULT_REGION=${REGION}" \
  --quiet

# --- Grant invoker to each principal ----------------------------------------
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

# --- Print the URL ----------------------------------------------------------
URL="$(gcloud run services describe "${SERVICE_NAME}" \
        --project "${PROJECT_ID}" --region "${CR_REGION}" \
        --format="value(status.url)" 2>/dev/null || echo "")"
log_info "LLM gateway URL: ${URL}"
