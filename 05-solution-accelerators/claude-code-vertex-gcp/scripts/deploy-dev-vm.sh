#!/usr/bin/env bash
# =============================================================================
# deploy-dev-vm.sh
#
# Provisions a no-public-IP GCE VM reached via IAP TCP tunneling.
# Renders the Terraform startup-script template with envsubst and
# passes the result as --metadata-from-file startup-script.
#
# For gcloud-only deployments we do NOT create the VPC connector or
# PSC endpoint — those are Terraform-only. The VM uses the project's
# default VPC. If you need a custom VPC, use the Terraform path.
#
# WARNING — do not mix deployment paths on the same project. Running
# `terraform apply` after this script will propose moving the VM to
# the TF-managed `claude-code-vpc` network, which recreates it (all
# data on the boot disk is lost). To migrate, run `teardown.sh` first,
# then use the Terraform path. See ARCHITECTURE.md →
# "Deployment-path compatibility".
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

print_help() {
  cat <<'HELP'
Usage: deploy-dev-vm.sh [--help] [--dry-run]
Reads PROJECT_ID, REGION, FALLBACK_REGION, PRINCIPALS from the
environment. Creates a single shared VM named claude-code-dev-shared
in zone <FALLBACK_REGION>-a.
HELP
}

parse_common_flags "$@"

: "${PROJECT_ID:?PROJECT_ID must be set}"
: "${REGION:?REGION must be set}"
: "${FALLBACK_REGION:?FALLBACK_REGION must be set}"
: "${PRINCIPALS:=}"

require_cmd gcloud
require_cmd envsubst
REPO_ROOT="$(resolve_repo_root)"

ZONE="${FALLBACK_REGION}-a"
VM_NAME="claude-code-dev-shared"
SA_ID="claude-code-dev-vm"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
MACHINE_TYPE="${MACHINE_TYPE:-e2-small}"
DISK_SIZE_GB="${DISK_SIZE_GB:-30}"
INSTALL_VSCODE="${INSTALL_VSCODE:-true}"
AUTO_SHUTDOWN_HOURS="${AUTO_SHUTDOWN_HOURS:-2}"

# --- Service account --------------------------------------------------------
log_step "ensure service account ${SA_EMAIL}"
if ! gcloud iam service-accounts describe "${SA_EMAIL}" \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
  run_cmd gcloud iam service-accounts create "${SA_ID}" \
    --project "${PROJECT_ID}" \
    --display-name="Claude Code Dev VM"
  wait_for_sa "${SA_EMAIL}"
fi
for role in roles/aiplatform.user roles/logging.logWriter; do
  run_cmd gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" --role="${role}" --condition=None --quiet
done

# --- Private Google Access ---------------------------------------------------
# The VM has no public IP, so the subnet needs PGA enabled for the VM to
# reach Cloud Run services (*.run.app) and Google APIs.
log_step "ensure Private Google Access on default subnet"
_pga="$(gcloud compute networks subnets describe default \
  --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" \
  --format="value(privateIpGoogleAccess)" 2>/dev/null || echo "")"
if [[ "${_pga}" != "True" ]]; then
  run_cmd gcloud compute networks subnets update default \
    --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" \
    --enable-private-ip-google-access
else
  log_info "Private Google Access already enabled"
fi

# --- Cloud NAT (egress to non-Google hosts) ---------------------------------
# The VM has no public IP and PGA only covers Google APIs. Cloud NAT
# provides outbound internet access so the startup script can reach
# deb.debian.org, registry.npmjs.org, deb.nodesource.com, etc.
log_step "ensure Cloud Router + Cloud NAT for dev VM egress"

ROUTER_NAME="claude-code-router"
NAT_NAME="claude-code-nat"

if ! gcloud compute routers describe "${ROUTER_NAME}" \
     --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" >/dev/null 2>&1; then
  run_cmd gcloud compute routers create "${ROUTER_NAME}" \
    --project "${PROJECT_ID}" \
    --region "${FALLBACK_REGION}" \
    --network default
else
  log_info "Cloud Router ${ROUTER_NAME} already exists"
fi

if ! gcloud compute routers nats describe "${NAT_NAME}" \
     --router "${ROUTER_NAME}" \
     --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" >/dev/null 2>&1; then
  run_cmd gcloud compute routers nats create "${NAT_NAME}" \
    --router "${ROUTER_NAME}" \
    --project "${PROJECT_ID}" \
    --region "${FALLBACK_REGION}" \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges
else
  log_info "Cloud NAT ${NAT_NAME} already exists"
fi

# --- IAP firewall rule ------------------------------------------------------
log_step "ensure IAP SSH firewall rule"
if ! gcloud compute firewall-rules describe allow-iap-ssh \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
  run_cmd gcloud compute firewall-rules create allow-iap-ssh \
    --project "${PROJECT_ID}" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --target-tags=claude-code-dev-vm
fi

# --- Resolve gateway URLs ---------------------------------------------------
log_step "resolve gateway URLs"
if [[ "${ENABLE_GLB:-false}" == "true" ]]; then
  GLB_URL="$(resolve_glb_url "${PROJECT_ID}" || echo "")"
  if [[ -n "${GLB_URL}" ]]; then
    LLM_URL="${GLB_URL}"
    MCP_URL="${GLB_URL}"
  else
    log_warn "GLB enabled but no GLB IP found — falling back to direct Cloud Run URLs"
  fi
fi

if [[ -z "${LLM_URL:-}" ]]; then
  LLM_URL="$(gcloud run services describe llm-gateway \
               --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" \
               --format="value(status.url)" 2>/dev/null || echo "")"
fi
if [[ -z "${MCP_URL:-}" ]]; then
  MCP_URL="$(gcloud run services describe mcp-gateway \
               --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" \
               --format="value(status.url)" 2>/dev/null || echo "")"
fi

log_info "LLM gateway URL for dev VM: ${LLM_URL}"
log_info "MCP gateway URL for dev VM: ${MCP_URL}"

# --- Render startup script --------------------------------------------------
log_step "render startup script"

STARTUP_FILE="$(mktemp -t startup-XXXXXX.sh)"
trap 'rm -f "${STARTUP_FILE}"' EXIT

# The TF template uses ${var} syntax matching the Terraform templatefile()
# function. For gcloud we reuse the same file but run envsubst on it,
# pre-escaping the $${...} (shell) sequences. sed swaps them back.
sed 's/\$\${/$__SHELL__/g' "${REPO_ROOT}/terraform/modules/dev_vm/startup.sh.tpl" \
  | project_id="${PROJECT_ID}" \
    vertex_region="${REGION}" \
    llm_gateway_url="${LLM_URL}" \
    mcp_gateway_url="${MCP_URL}" \
    install_vscode_server="${INSTALL_VSCODE}" \
    auto_shutdown_idle_hours="${AUTO_SHUTDOWN_HOURS}" \
    envsubst '$project_id $vertex_region $llm_gateway_url $mcp_gateway_url $install_vscode_server $auto_shutdown_idle_hours' \
  | sed 's/\$__SHELL__/${/g' \
  > "${STARTUP_FILE}"

# --- Create the VM (idempotent: skip if it exists) --------------------------
log_step "ensure GCE VM ${VM_NAME}"
if ! gcloud compute instances describe "${VM_NAME}" \
     --project "${PROJECT_ID}" --zone "${ZONE}" >/dev/null 2>&1; then
  run_cmd gcloud compute instances create "${VM_NAME}" \
    --project "${PROJECT_ID}" \
    --zone "${ZONE}" \
    --machine-type "${MACHINE_TYPE}" \
    --image-family debian-12 --image-project debian-cloud \
    --boot-disk-size "${DISK_SIZE_GB}GB" \
    --service-account "${SA_EMAIL}" \
    --scopes cloud-platform \
    --no-address \
    --tags claude-code-dev-vm \
    --metadata enable-oslogin=TRUE \
    --metadata-from-file "startup-script=${STARTUP_FILE}" \
    --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring
else
  log_info "VM already exists, leaving alone (re-run teardown.sh to recreate)"
fi

# --- Grant VM SA run.invoker on dashboard (if deployed) --------------------
if gcloud run services describe admin-dashboard \
     --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" >/dev/null 2>&1; then
  log_step "grant VM SA invoker on admin-dashboard"
  run_cmd gcloud run services add-iam-policy-binding admin-dashboard \
    --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" \
    --member="serviceAccount:${SA_EMAIL}" --role="roles/run.invoker" --quiet
fi

# --- Grant IAP tunnel + OS Login to each principal --------------------------
if [[ -n "${PRINCIPALS}" ]]; then
  log_step "grant IAP tunnel + OS Login"
  IFS=',' read -ra _principals <<<"${PRINCIPALS}"
  for p in "${_principals[@]}"; do
    p="${p## }"; p="${p%% }"
    [[ -z "${p}" ]] && continue
    for role in roles/iap.tunnelResourceAccessor roles/compute.osLogin; do
      run_cmd gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="${p}" --role="${role}" --condition=None --quiet
    done
  done
fi

log_info "VM ready. SSH with:"
log_info "  gcloud compute ssh --tunnel-through-iap --project=${PROJECT_ID} --zone=${ZONE} ${VM_NAME}"
