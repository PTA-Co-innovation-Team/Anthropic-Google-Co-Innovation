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

# --- VPC selection (B-mode override) ----------------------------------------
# By default, the dev VM lands on the project's `default` VPC (and the
# script auto-creates one if missing). To use a pre-existing VPC instead,
# export NETWORK_NAME (and optionally SUBNET_NAME) before running. Set
# SKIP_NAT=true if your VPC already has Cloud NAT in the region — the
# script will leave it alone instead of creating a duplicate.
: "${NETWORK_NAME:=default}"
: "${SUBNET_NAME:=}"
: "${SKIP_NAT:=false}"

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

# --- VPC (idempotent) -------------------------------------------------------
# Default behavior: use the project's `default` VPC and auto-create it if
# missing. Override behavior: NETWORK_NAME=my-vpc → use my-vpc, fail loud if
# it doesn't exist. We deliberately don't auto-create a customer-named
# network — that's their territory.
log_step "ensure network ${NETWORK_NAME} exists"
if ! gcloud compute networks describe "${NETWORK_NAME}" \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
  if [[ "${NETWORK_NAME}" == "default" ]]; then
    log_info "default VPC missing — creating in auto-mode"
    run_cmd gcloud compute networks create default \
      --project "${PROJECT_ID}" --subnet-mode=auto
  else
    log_error "network '${NETWORK_NAME}' does not exist in ${PROJECT_ID}"
    log_error "  create it first, or unset NETWORK_NAME to use the default VPC"
    exit 1
  fi
fi

# Validate SUBNET_NAME when given (custom-mode VPCs need an explicit subnet).
if [[ -n "${SUBNET_NAME}" ]]; then
  if ! gcloud compute networks subnets describe "${SUBNET_NAME}" \
       --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" \
       >/dev/null 2>&1; then
    log_error "subnet '${SUBNET_NAME}' not found in ${FALLBACK_REGION}"
    exit 1
  fi
fi

# --- Cloud Router + NAT (idempotent unless SKIP_NAT) ------------------------
# The dev VM is created with --no-address (no public IP). Without NAT, the
# VM cannot reach the public internet, which makes apt and npm fail and the
# startup script bail at exit 100. Provision a Cloud Router + NAT in the
# VM's region on the chosen network. Skip if SKIP_NAT=true.
NAT_ROUTER="claude-code-nat-router"
NAT_NAME="claude-code-nat"
if [[ "${SKIP_NAT}" == "true" ]]; then
  log_info "SKIP_NAT=true — leaving Cloud NAT alone (you must have one already)"
else
  log_step "ensure Cloud Router + NAT for dev VM internet egress (network=${NETWORK_NAME})"
  if ! gcloud compute routers describe "${NAT_ROUTER}" \
       --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" \
       >/dev/null 2>&1; then
    run_cmd gcloud compute routers create "${NAT_ROUTER}" \
      --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" \
      --network "${NETWORK_NAME}"
  fi
  if ! gcloud compute routers nats describe "${NAT_NAME}" \
       --router "${NAT_ROUTER}" \
       --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" \
       >/dev/null 2>&1; then
    run_cmd gcloud compute routers nats create "${NAT_NAME}" \
      --project "${PROJECT_ID}" --region "${FALLBACK_REGION}" \
      --router "${NAT_ROUTER}" \
      --nat-all-subnet-ip-ranges \
      --auto-allocate-nat-external-ips
  fi
fi

# --- IAP firewall rule ------------------------------------------------------
# Firewall name is suffixed with the network when not default, so an
# existing default-network rule on the same project doesn't collide.
FW_NAME="allow-iap-ssh"
if [[ "${NETWORK_NAME}" != "default" ]]; then
  FW_NAME="allow-iap-ssh-${NETWORK_NAME}"
fi
log_step "ensure IAP SSH firewall rule (${FW_NAME} on ${NETWORK_NAME})"
if ! gcloud compute firewall-rules describe "${FW_NAME}" \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
  run_cmd gcloud compute firewall-rules create "${FW_NAME}" \
    --project "${PROJECT_ID}" \
    --network="${NETWORK_NAME}" \
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
log_step "ensure GCE VM ${VM_NAME} on ${NETWORK_NAME}${SUBNET_NAME:+ / ${SUBNET_NAME}}"
# Build network/subnet flags. Default VPC is auto-mode so we only need
# --network. Custom VPCs typically want both --network and --subnet.
_NET_FLAGS=("--network=${NETWORK_NAME}")
if [[ -n "${SUBNET_NAME}" ]]; then
  _NET_FLAGS+=("--subnet=${SUBNET_NAME}")
fi
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
    "${_NET_FLAGS[@]}" \
    --tags claude-code-dev-vm \
    --metadata enable-oslogin=TRUE \
    --metadata-from-file "startup-script=${STARTUP_FILE}" \
    --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring
else
  log_info "VM already exists, leaving alone (re-run teardown.sh to recreate)"
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
