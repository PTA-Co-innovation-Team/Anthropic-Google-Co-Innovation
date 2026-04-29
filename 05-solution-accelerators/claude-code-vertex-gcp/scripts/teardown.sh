#!/usr/bin/env bash
# =============================================================================
# teardown.sh — interactive destroyer.
#
# Requires the user to type the project ID to confirm. Deletes:
#   * Cloud Run services (llm-gateway, mcp-gateway, dev-portal,
#     admin-dashboard)
#   * GCE VM (claude-code-dev-shared) if present
#   * Service accounts (llm-gateway, mcp-gateway, claude-code-dev-vm,
#     dev-portal, admin-dashboard)
#   * IAP SSH firewall rule (allow-iap-ssh)
#
# Does NOT:
#   * Delete the Artifact Registry repo (keeps built images in case you
#     re-deploy shortly after).
#   * Delete the BigQuery dataset or its Looker Studio views (may
#     contain historical logs of interest). Use `bq rm -r -f` manually
#     if you want to remove the dataset and views.
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

# --- GLB resources (if deployed) ---------------------------------------------
log_step "delete GLB resources (if present)"
for res_type_cmd in \
  "forwarding-rules:claude-code-glb-fwd:--global" \
  "target-https-proxies:claude-code-glb-https-proxy:--global" \
  "url-maps:claude-code-glb-url-map:--global" \
  "ssl-certificates:claude-code-glb-cert:--global"; do
  IFS=':' read -r res_type res_name res_flag <<< "${res_type_cmd}"
  if gcloud compute ${res_type} describe "${res_name}" ${res_flag} \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
    run_cmd gcloud compute ${res_type} delete "${res_name}" ${res_flag} \
      --project "${PROJECT_ID}" --quiet
  fi
done

for backend in llm-gateway-backend mcp-gateway-backend dev-portal-backend admin-dashboard-backend; do
  if gcloud compute backend-services describe "${backend}" --global \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
    run_cmd gcloud compute backend-services delete "${backend}" --global \
      --project "${PROJECT_ID}" --quiet
  fi
done

for neg in llm-gateway-neg mcp-gateway-neg dev-portal-neg admin-dashboard-neg; do
  if gcloud compute network-endpoint-groups describe "${neg}" \
     --region "${REGION}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
    run_cmd gcloud compute network-endpoint-groups delete "${neg}" \
      --region "${REGION}" --project "${PROJECT_ID}" --quiet
  fi
done

# Clean up DNS A records pointing to the GLB IP before deleting the IP.
_glb_ip="$(gcloud compute addresses describe claude-code-glb-ip --global \
  --project "${PROJECT_ID}" --format="value(address)" 2>/dev/null || echo "")"
if [[ -n "${_glb_ip}" ]]; then
  for _zone_name in $(gcloud dns managed-zones list --project "${PROJECT_ID}" \
    --format="value(name)" 2>/dev/null); do
    for _record in $(gcloud dns record-sets list --zone="${_zone_name}" \
      --project "${PROJECT_ID}" --filter="type=A AND rrdatas=${_glb_ip}" \
      --format="value(name)" 2>/dev/null); do
      log_info "removing DNS A record ${_record} from zone ${_zone_name}"
      run_cmd gcloud dns record-sets delete "${_record}" \
        --zone="${_zone_name}" --type=A --project "${PROJECT_ID}" --quiet
    done
  done
  run_cmd gcloud compute addresses delete claude-code-glb-ip --global \
    --project "${PROJECT_ID}" --quiet
fi

# Also try self-signed cert cleanup.
for cert in $(gcloud compute ssl-certificates list --project "${PROJECT_ID}" \
  --filter="name~claude-code-glb-self-signed" --format="value(name)" 2>/dev/null); do
  run_cmd gcloud compute ssl-certificates delete "${cert}" --global \
    --project "${PROJECT_ID}" --quiet
done

# --- Cloud Run services -----------------------------------------------------
log_step "delete Cloud Run services"
for svc in llm-gateway mcp-gateway dev-portal admin-dashboard; do
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

# --- Cloud NAT + Cloud Router -----------------------------------------------
log_step "delete Cloud NAT and Cloud Router (if present)"
if gcloud compute routers nats describe claude-code-nat \
     --router claude-code-router \
     --project "${PROJECT_ID}" --region "${REGION}" >/dev/null 2>&1; then
  run_cmd gcloud compute routers nats delete claude-code-nat \
    --router claude-code-router \
    --project "${PROJECT_ID}" --region "${REGION}" --quiet
fi
if gcloud compute routers describe claude-code-router \
     --project "${PROJECT_ID}" --region "${REGION}" >/dev/null 2>&1; then
  run_cmd gcloud compute routers delete claude-code-router \
    --project "${PROJECT_ID}" --region "${REGION}" --quiet
fi

# --- Firewall ---------------------------------------------------------------
log_step "delete IAP firewall rule"
if gcloud compute firewall-rules describe allow-iap-ssh --project "${PROJECT_ID}" >/dev/null 2>&1; then
  run_cmd gcloud compute firewall-rules delete allow-iap-ssh \
    --project "${PROJECT_ID}" --quiet
fi

# --- Service accounts -------------------------------------------------------
log_step "delete service accounts"
for sa in llm-gateway mcp-gateway claude-code-dev-vm dev-portal admin-dashboard; do
  email="${sa}@${PROJECT_ID}.iam.gserviceaccount.com"
  if gcloud iam service-accounts describe "${email}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
    run_cmd gcloud iam service-accounts delete "${email}" \
      --project "${PROJECT_ID}" --quiet
  fi
done

log_info "teardown complete."
log_info "not removed (delete manually if desired): Artifact Registry repo, BigQuery dataset, enabled APIs."
