#!/usr/bin/env bash
# =============================================================================
# teardown.sh — interactive destroyer.
#
# Requires the user to type the project ID to confirm. Deletes:
#   * Cloud Run services (llm-gateway, mcp-gateway, dev-portal)
#   * GCE VM (claude-code-dev-shared) if present
#   * Service accounts (llm-gateway, mcp-gateway, claude-code-dev-vm,
#     dev-portal)
#   * IAP SSH firewall rule (allow-iap-ssh)
#
# Does NOT:
#   * Delete the Artifact Registry repo (keeps built images in case you
#     re-deploy shortly after).
#   * Delete the BigQuery dataset (may contain historical logs of
#     interest). Use `bq rm -r -f` manually if you want to remove it.
#   * Disable APIs.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

print_help() {
  cat <<'HELP'
Usage: teardown.sh [--help] [--dry-run]

Interactive teardown. Prompts for the project ID verbatim before
destroying anything. Safe to re-run.
HELP
}

parse_common_flags "$@"
require_cmd gcloud

default_project="$(gcloud config get-value project 2>/dev/null || true)"
read -rp "GCP project ID [${default_project}]: " PROJECT_ID </dev/tty
PROJECT_ID="${PROJECT_ID:-${default_project}}"
: "${PROJECT_ID:?project id required}"

# Require the user to type the project id AGAIN to confirm.
read -rp "To confirm teardown, type the project ID: " confirm_id </dev/tty
if [[ "${confirm_id}" != "${PROJECT_ID}" ]]; then
  log_error "confirmation did not match. aborted."
  exit 1
fi

# Region for Cloud Run services — ask, default us-central1.
read -rp "Cloud Run region [us-central1]: " REGION </dev/tty
REGION="${REGION:-us-central1}"
ZONE="${REGION}-a"

# --- Cloud Run services -----------------------------------------------------
log_step "delete Cloud Run services"
for svc in llm-gateway mcp-gateway dev-portal; do
  if gcloud run services describe "${svc}" --project "${PROJECT_ID}" --region "${REGION}" >/dev/null 2>&1; then
    run_cmd gcloud run services delete "${svc}" \
      --project "${PROJECT_ID}" --region "${REGION}" --quiet
  else
    log_info "${svc} not present, skipping"
  fi
done

# --- Dev VM -----------------------------------------------------------------
log_step "delete dev VM if present"
if gcloud compute instances describe claude-code-dev-shared \
     --project "${PROJECT_ID}" --zone "${ZONE}" >/dev/null 2>&1; then
  run_cmd gcloud compute instances delete claude-code-dev-shared \
    --project "${PROJECT_ID}" --zone "${ZONE}" --quiet
fi

# --- Firewall ---------------------------------------------------------------
log_step "delete IAP firewall rule"
if gcloud compute firewall-rules describe allow-iap-ssh --project "${PROJECT_ID}" >/dev/null 2>&1; then
  run_cmd gcloud compute firewall-rules delete allow-iap-ssh \
    --project "${PROJECT_ID}" --quiet
fi

# --- Service accounts -------------------------------------------------------
log_step "delete service accounts"
for sa in llm-gateway mcp-gateway claude-code-dev-vm dev-portal; do
  email="${sa}@${PROJECT_ID}.iam.gserviceaccount.com"
  if gcloud iam service-accounts describe "${email}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
    run_cmd gcloud iam service-accounts delete "${email}" \
      --project "${PROJECT_ID}" --quiet
  fi
done

log_info "teardown complete."
log_info "not removed (delete manually if desired): Artifact Registry repo, BigQuery dataset, enabled APIs."
