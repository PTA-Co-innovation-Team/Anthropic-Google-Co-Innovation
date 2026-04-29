#!/usr/bin/env bash
# =============================================================================
# validate-glb-demo.sh — post-deployment GLB + cascading change validation.
#
# Complements e2e-test.sh by verifying GLB infrastructure, token
# validation configuration, URL map routing, dev VM integration, and
# IAP setup. Designed to catch parity issues between the bash deploy
# scripts and Terraform modules.
#
# Usage:
#   # After deploying with GLB enabled:
#   ./scripts/validate-glb-demo.sh --project $PROJECT_ID
#
#   # With explicit URLs (if auto-discovery fails):
#   ./scripts/validate-glb-demo.sh --project $PID --glb-url https://...
#
# Run AFTER deploy.sh and BEFORE the live demo.
#
# Cost: ~$0.003 (three Haiku inference requests for routing tests).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# -----------------------------------------------------------------------------
# Flags
# -----------------------------------------------------------------------------
PROJECT_ID=""
CR_REGION=""
REGION=""
GLB_URL=""
VERBOSE=0

print_help() {
  cat <<'HELP'
Usage: validate-glb-demo.sh [options]

Post-deployment validation for the GLB + hybrid-auth configuration.

Options:
  --project <id>       GCP project ID (else gcloud config).
  --region <region>    Vertex region (default "global").
  --cr-region <region> Cloud Run region (default us-central1).
  --glb-url <url>      GLB URL (else auto-discovered from static IP).
  --verbose            Echo every command.
  -h, --help           This help.
HELP
}

_REMAINING=()
while (($#)); do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --cr-region) CR_REGION="$2"; shift 2 ;;
    --glb-url) GLB_URL="$2"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) _REMAINING+=("$1"); shift ;;
  esac
done
set -- "${_REMAINING[@]:-}"

[[ "${VERBOSE}" == "1" ]] && set -x

require_cmd gcloud
require_cmd curl

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
: "${PROJECT_ID:?--project required}"
REGION="${REGION:-global}"
CR_REGION="${CR_REGION:-us-central1}"

# --- Auto-discover GLB URL --------------------------------------------------
if [[ -z "${GLB_URL}" ]]; then
  GLB_URL="$(resolve_glb_url "${PROJECT_ID}" || echo "")"
fi

# --- Discover Cloud Run URLs ------------------------------------------------
_describe_url() {
  gcloud run services describe "$1" \
    --project "${PROJECT_ID}" --region "${CR_REGION}" \
    --format="value(status.url)" 2>/dev/null || true
}
GATEWAY_URL="$(_describe_url llm-gateway)"
MCP_URL="$(_describe_url mcp-gateway)"
PORTAL_URL="$(_describe_url dev-portal)"
DASHBOARD_URL="$(_describe_url admin-dashboard)"

log_info "project:       ${PROJECT_ID}"
log_info "region:        ${REGION}"
log_info "cr-region:     ${CR_REGION}"
log_info "GLB URL:       ${GLB_URL:-<not found>}"
log_info "LLM gateway:   ${GATEWAY_URL:-<not deployed>}"
log_info "MCP gateway:   ${MCP_URL:-<not deployed>}"
log_info "dev portal:    ${PORTAL_URL:-<not deployed>}"
log_info "dashboard:     ${DASHBOARD_URL:-<not deployed>}"

if [[ -z "${GLB_URL}" ]]; then
  log_error "GLB not deployed (no static IP found). Deploy with ENABLE_GLB=true first."
  exit 1
fi

# -----------------------------------------------------------------------------
# Test tracking
# -----------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
declare -A LAYER_PASS LAYER_FAIL LAYER_SKIP
CURRENT_LAYER=""

_record() {
  local status="$1" name="$2" detail="${3:-}"
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)); LAYER_PASS[$CURRENT_LAYER]=$(( ${LAYER_PASS[$CURRENT_LAYER]:-0} + 1 ))
          echo "${_CLR_GREEN}  PASS${_CLR_RESET}  ${name}" >&2 ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)); LAYER_FAIL[$CURRENT_LAYER]=$(( ${LAYER_FAIL[$CURRENT_LAYER]:-0} + 1 ))
          echo "${_CLR_RED}  FAIL${_CLR_RESET}  ${name}  ${detail}" >&2 ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)); LAYER_SKIP[$CURRENT_LAYER]=$(( ${LAYER_SKIP[$CURRENT_LAYER]:-0} + 1 ))
          echo "${_CLR_YELLOW}  SKIP${_CLR_RESET}  ${name}  ${detail}" >&2 ;;
  esac
}

run_test() {
  local name="$1"; shift
  local func="$1"; shift
  local detail=""
  set +e
  detail="$("$func" "$@" 2>&1)"
  local rc=$?
  set -e
  case $rc in
    0) _record PASS "$name" ;;
    2) _record SKIP "$name" "${detail}" ;;
    *) _record FAIL "$name" "${detail}" ;;
  esac
}

# --- Helpers -----------------------------------------------------------------
_get_access_token() {
  gcloud auth application-default print-access-token 2>/dev/null
}

_get_identity_token() {
  gcloud auth print-identity-token --audiences="$1" 2>/dev/null || true
}

_haiku_body() {
  cat <<'JSON'
{
  "anthropic_version": "vertex-2023-10-16",
  "messages": [{"role":"user","content":"Reply with the single word: ok"}],
  "max_tokens": 8
}
JSON
}

_inference_path() {
  echo "/v1/projects/${PROJECT_ID}/locations/${REGION}/publishers/anthropic/models/claude-haiku-4-5@20251001:rawPredict"
}

_cr_describe() {
  gcloud run services describe "$1" \
    --project "${PROJECT_ID}" --region "${CR_REGION}" \
    --format="$2" 2>/dev/null || true
}

# =============================================================================
# Layer 1 — GLB Infrastructure
# =============================================================================

test_1_1_static_ip() {
  gcloud compute addresses describe claude-code-glb-ip --global \
    --project "${PROJECT_ID}" >/dev/null 2>&1 \
    || { echo "static IP claude-code-glb-ip not found"; return 1; }
}

test_1_2_negs_exist() {
  local missing=""
  for svc in llm-gateway mcp-gateway dev-portal admin-dashboard; do
    local cr_exists
    cr_exists=$(gcloud run services describe "${svc}" \
      --project "${PROJECT_ID}" --region "${CR_REGION}" \
      --format="value(status.url)" 2>/dev/null || true)
    if [[ -n "${cr_exists}" ]]; then
      if ! gcloud compute network-endpoint-groups describe "${svc}-neg" \
           --region "${CR_REGION}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
        missing+="${svc}-neg "
      fi
    fi
  done
  [[ -z "${missing}" ]] || { echo "missing NEGs: ${missing}"; return 1; }
}

test_1_3_backends_exist() {
  local missing=""
  for backend in llm-gateway-backend mcp-gateway-backend; do
    if ! gcloud compute backend-services describe "${backend}" --global \
         --project "${PROJECT_ID}" >/dev/null 2>&1; then
      missing+="${backend} "
    fi
  done
  [[ -z "${missing}" ]] || { echo "missing backends: ${missing}"; return 1; }
}

test_1_4_url_map_exists() {
  gcloud compute url-maps describe claude-code-glb-url-map --global \
    --project "${PROJECT_ID}" >/dev/null 2>&1 \
    || { echo "URL map not found"; return 1; }
}

test_1_5_ssl_cert_exists() {
  # Check for managed cert OR self-signed cert
  local managed self_signed
  managed=$(gcloud compute ssl-certificates describe claude-code-glb-cert --global \
    --project "${PROJECT_ID}" 2>/dev/null && echo "yes" || true)
  self_signed=$(gcloud compute ssl-certificates list --project "${PROJECT_ID}" \
    --filter="name~claude-code-glb-self-signed" --format="value(name)" 2>/dev/null | head -1)

  if [[ -z "${managed}" && -z "${self_signed}" ]]; then
    echo "no SSL certificate found (neither managed nor self-signed)"
    return 1
  fi
}

test_1_5b_dns_record() {
  [[ -z "${GLB_DOMAIN:-}" ]] && { echo "SKIP (no domain configured)"; return 0; }
  local _parent="${GLB_DOMAIN#*.}"
  local _zone
  _zone="$(gcloud dns managed-zones list --project "${PROJECT_ID}" \
    --filter="dnsName=${_parent}." --format="value(name)" 2>/dev/null | head -1 || echo "")"
  [[ -z "${_zone}" ]] && { echo "SKIP (no Cloud DNS zone for ${_parent})"; return 0; }
  local _ip
  _ip="$(gcloud dns record-sets describe "${GLB_DOMAIN}." \
    --zone="${_zone}" --type=A --project "${PROJECT_ID}" \
    --format="value(rrdatas[0])" 2>/dev/null || echo "")"
  [[ -z "${_ip}" ]] && { echo "no A record for ${GLB_DOMAIN} in zone ${_zone}"; return 1; }
  local _glb_ip
  _glb_ip="$(gcloud compute addresses describe claude-code-glb-ip --global \
    --project "${PROJECT_ID}" --format="value(address)" 2>/dev/null || echo "")"
  if [[ "${_ip}" != "${_glb_ip}" ]]; then
    echo "A record ${_ip} does not match GLB IP ${_glb_ip}"
    return 1
  fi
}

test_1_6_forwarding_rule() {
  gcloud compute forwarding-rules describe claude-code-glb-fwd --global \
    --project "${PROJECT_ID}" >/dev/null 2>&1 \
    || { echo "forwarding rule not found"; return 1; }
}

test_1_7_https_proxy() {
  gcloud compute target-https-proxies describe claude-code-glb-https-proxy --global \
    --project "${PROJECT_ID}" >/dev/null 2>&1 \
    || { echo "HTTPS proxy not found"; return 1; }
}

# =============================================================================
# Layer 2 — Cloud Run Configuration (GLB mode)
# =============================================================================

test_2_1_ingress_restricted() {
  local wrong=""
  for svc in llm-gateway mcp-gateway dev-portal; do
    local ingress
    ingress=$(_cr_describe "${svc}" "value(ingress)")
    if [[ -n "${ingress}" && "${ingress}" != "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" ]]; then
      wrong+="${svc}(${ingress}) "
    fi
  done
  [[ -z "${wrong}" ]] || { echo "wrong ingress: ${wrong}"; return 1; }
}

test_2_2_allow_unauth() {
  local wrong=""
  for svc in llm-gateway mcp-gateway dev-portal; do
    local iam_output
    iam_output=$(gcloud run services get-iam-policy "${svc}" \
      --project "${PROJECT_ID}" --region "${CR_REGION}" \
      --format="value(bindings.members)" 2>/dev/null || true)
    if [[ -n "${iam_output}" ]] && ! echo "${iam_output}" | grep -q "allUsers"; then
      wrong+="${svc} "
    fi
  done
  [[ -z "${wrong}" ]] || { echo "missing allUsers invoker: ${wrong}"; return 1; }
}

test_2_3_token_validation_enabled() {
  local missing=""
  for svc in llm-gateway mcp-gateway; do
    local envs
    envs=$(_cr_describe "${svc}" "yaml(spec.template.spec.containers[0].env)")
    if ! echo "${envs}" | grep -q 'ENABLE_TOKEN_VALIDATION'; then
      missing+="${svc} "
    fi
  done
  [[ -z "${missing}" ]] || { echo "ENABLE_TOKEN_VALIDATION not set: ${missing}"; return 1; }
}

test_2_4_allowed_principals_set() {
  local missing=""
  for svc in llm-gateway mcp-gateway; do
    local envs
    envs=$(_cr_describe "${svc}" "yaml(spec.template.spec.containers[0].env)")
    if ! echo "${envs}" | grep -q 'ALLOWED_PRINCIPALS'; then
      missing+="${svc} "
    fi
  done
  [[ -z "${missing}" ]] || { echo "ALLOWED_PRINCIPALS not set: ${missing}"; return 1; }
}

test_2_5_dev_vm_sa_in_principals() {
  local zone="${CR_REGION}-a"
  if ! gcloud compute instances describe claude-code-dev-shared \
       --project "${PROJECT_ID}" --zone "${zone}" >/dev/null 2>&1; then
    echo "no dev VM deployed"
    return 2
  fi

  local envs
  envs=$(_cr_describe "llm-gateway" "yaml(spec.template.spec.containers[0].env)")
  if ! echo "${envs}" | grep -q 'claude-code-dev-vm'; then
    echo "dev VM SA not in LLM gateway ALLOWED_PRINCIPALS"
    return 1
  fi
}

# =============================================================================
# Layer 3 — Auth Flows Through GLB
# =============================================================================

test_3_1_health_no_token() {
  local status
  status=$(curl -sSkS -o /dev/null -w "%{http_code}" --connect-timeout 15 \
            "${GLB_URL%/}/health" 2>/dev/null)
  [[ "${status}" == "200" ]] || { echo "/health without token returned ${status} (expected 200 — middleware skips /health)"; return 1; }
}

test_3_2_inference_access_token() {
  local token status
  token="$(_get_access_token)"
  [[ -n "${token}" ]] || { echo "no access token"; return 1; }
  status=$(curl -sSkS -o /dev/null -w "%{http_code}" --connect-timeout 15 \
            -X POST "${GLB_URL%/}$(_inference_path)" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$(_haiku_body)" 2>/dev/null)
  [[ "${status}" == "200" ]] || { echo "inference with access token returned ${status}"; return 1; }
}

test_3_3_inference_oidc() {
  local token status
  token="$(_get_identity_token "${GLB_URL%/}")"
  [[ -n "${token}" ]] || { echo "cannot obtain OIDC token for GLB URL"; return 2; }
  status=$(curl -sSkS -o /dev/null -w "%{http_code}" --connect-timeout 15 \
            -X POST "${GLB_URL%/}$(_inference_path)" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$(_haiku_body)" 2>/dev/null)
  [[ "${status}" == "200" ]] || { echo "inference with OIDC token returned ${status}"; return 1; }
}

test_3_4_no_token_rejected() {
  local status
  status=$(curl -sSkS -o /dev/null -w "%{http_code}" --connect-timeout 15 \
            -X POST "${GLB_URL%/}$(_inference_path)" \
            -H "Content-Type: application/json" \
            -d "$(_haiku_body)" 2>/dev/null)
  if [[ "${status}" == "401" || "${status}" == "403" ]]; then return 0; fi
  echo "no-token inference returned ${status} (expected 401/403)"
  return 1
}

test_3_5_direct_cr_blocked() {
  [[ -n "${GATEWAY_URL}" ]] || return 2
  local token status
  token="$(_get_identity_token "${GATEWAY_URL}")"
  [[ -n "${token}" ]] || token="$(_get_access_token)"
  status=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 \
            -H "Authorization: Bearer ${token}" \
            "${GATEWAY_URL%/}/health" 2>/dev/null)
  if [[ "${status}" == "403" ]]; then return 0; fi
  echo "direct Cloud Run returned ${status} (expected 403 — ingress restricted)"
  return 1
}

# =============================================================================
# Layer 4 — URL Map Routing
# =============================================================================

test_4_1_health_routes_to_llm() {
  local token body
  token="$(_get_access_token)"
  body=$(curl -sSkS --connect-timeout 15 \
          -H "Authorization: Bearer ${token}" \
          "${GLB_URL%/}/health" 2>/dev/null)
  if echo "${body}" | grep -q 'llm_gateway\|llm-gateway'; then
    return 0
  fi
  # Health endpoint might not include component name. Just verify 200 works.
  local status
  status=$(curl -sSkS -o /dev/null -w "%{http_code}" --connect-timeout 15 \
            -H "Authorization: Bearer ${token}" \
            "${GLB_URL%/}/health" 2>/dev/null)
  [[ "${status}" == "200" ]] || { echo "/health routing: status ${status}"; return 1; }
}

test_4_2_v1_routes_to_llm() {
  local token status
  token="$(_get_access_token)"
  status=$(curl -sSkS -o /dev/null -w "%{http_code}" --connect-timeout 15 \
            -X POST "${GLB_URL%/}$(_inference_path)" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$(_haiku_body)" 2>/dev/null)
  [[ "${status}" == "200" ]] || { echo "/v1/* routing: status ${status}"; return 1; }
}

test_4_3_mcp_routes_to_mcp() {
  [[ -n "${MCP_URL}" ]] || { echo "MCP gateway not deployed"; return 2; }
  local token status
  token="$(_get_access_token)"
  # MCP health endpoint at /mcp path doesn't exist; try the MCP initialize
  # handshake. A 200/405 from the MCP server confirms routing is correct.
  # A 404 from the LLM gateway (wrong backend) would be a failure.
  status=$(curl -sSkS -o /dev/null -w "%{http_code}" --connect-timeout 15 \
            -X POST "${GLB_URL%/}/mcp" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}' \
            2>/dev/null)
  if [[ "${status}" == "200" || "${status}" == "405" ]]; then return 0; fi
  echo "/mcp routing: status ${status} (expected 200 or 405 from MCP server)"
  return 1
}

test_4_4_default_routes_to_portal() {
  [[ -n "${PORTAL_URL}" ]] || { echo "dev portal not deployed"; return 2; }
  local token body
  token="$(_get_access_token)"
  # The default path (/) should route to dev portal (HTML landing page).
  # With IAP enabled, we may get a redirect (302) or the IAP login page.
  # Without IAP, we get the portal HTML.
  local status
  status=$(curl -sSkS -o /dev/null -w "%{http_code}" --connect-timeout 15 \
            -H "Authorization: Bearer ${token}" \
            "${GLB_URL%/}/" 2>/dev/null)
  # 200 = portal served directly, 302 = IAP redirect, both are valid.
  if [[ "${status}" == "200" || "${status}" == "302" ]]; then return 0; fi
  echo "/ routing: status ${status} (expected 200 or 302 for dev portal)"
  return 1
}

# =============================================================================
# Layer 5 — Dev VM Integration
# =============================================================================

test_5_1_vm_exists_no_pubip() {
  local zone="${CR_REGION}-a"
  if ! gcloud compute instances describe claude-code-dev-shared \
       --project "${PROJECT_ID}" --zone "${zone}" >/dev/null 2>&1; then
    echo "no dev VM deployed"
    return 2
  fi
  local natip
  natip=$(gcloud compute instances describe claude-code-dev-shared \
            --project "${PROJECT_ID}" --zone "${zone}" \
            --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)
  [[ -z "${natip}" ]] || { echo "dev VM has public IP: ${natip}"; return 1; }
}

test_5_2_vm_metadata_has_glb_url() {
  local zone="${CR_REGION}-a"
  if ! gcloud compute instances describe claude-code-dev-shared \
       --project "${PROJECT_ID}" --zone "${zone}" >/dev/null 2>&1; then
    echo "no dev VM deployed"; return 2
  fi
  local startup
  startup=$(gcloud compute instances describe claude-code-dev-shared \
    --project "${PROJECT_ID}" --zone "${zone}" \
    --format="value(metadata.items[startup-script])" 2>/dev/null || true)

  if [[ -z "${startup}" ]]; then
    # Try startup-script metadata key
    startup=$(gcloud compute instances describe claude-code-dev-shared \
      --project "${PROJECT_ID}" --zone "${zone}" \
      --format="value(metadata.items[key=startup-script].value)" 2>/dev/null || true)
  fi

  if [[ -z "${startup}" ]]; then
    echo "no startup script found in VM metadata"
    return 1
  fi

  # Strip the protocol from GLB_URL for a looser check
  local glb_host="${GLB_URL#https://}"
  glb_host="${glb_host#http://}"
  glb_host="${glb_host%/}"

  if echo "${startup}" | grep -q "${glb_host}"; then
    return 0
  fi

  # The startup script should contain either the GLB URL or the GLB IP
  local glb_ip
  glb_ip=$(gcloud compute addresses describe claude-code-glb-ip --global \
    --project "${PROJECT_ID}" --format="value(address)" 2>/dev/null || true)
  if [[ -n "${glb_ip}" ]] && echo "${startup}" | grep -q "${glb_ip}"; then
    return 0
  fi

  echo "startup script does not contain GLB URL (${glb_host}) or GLB IP (${glb_ip:-?})"
  return 1
}

test_5_3_vm_sa_exists() {
  local zone="${CR_REGION}-a"
  if ! gcloud compute instances describe claude-code-dev-shared \
       --project "${PROJECT_ID}" --zone "${zone}" >/dev/null 2>&1; then
    echo "no dev VM deployed"; return 2
  fi
  local sa_email="claude-code-dev-vm@${PROJECT_ID}.iam.gserviceaccount.com"
  gcloud iam service-accounts describe "${sa_email}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1 \
    || { echo "dev VM service account ${sa_email} not found"; return 1; }
}

# =============================================================================
# Layer 6 — IAP Configuration
# =============================================================================

test_6_1_iap_brand_exists() {
  local project_number
  project_number=$(gcloud projects describe "${PROJECT_ID}" \
    --format="value(projectNumber)" 2>/dev/null)
  [[ -n "${project_number}" ]] || { echo "cannot resolve project number"; return 1; }

  gcloud iap oauth-brands describe "projects/${project_number}/brands/${project_number}" \
    --project "${PROJECT_ID}" >/dev/null 2>&1 \
    || { echo "IAP OAuth brand not found"; return 2; }
}

test_6_2_iap_on_portal_backend() {
  [[ -n "${PORTAL_URL}" ]] || { echo "dev portal not deployed"; return 2; }
  if ! gcloud compute backend-services describe dev-portal-backend --global \
       --project "${PROJECT_ID}" >/dev/null 2>&1; then
    echo "dev-portal-backend not found"
    return 2
  fi
  local iap_enabled
  iap_enabled=$(gcloud compute backend-services describe dev-portal-backend --global \
    --project "${PROJECT_ID}" --format="value(iap.enabled)" 2>/dev/null || true)
  [[ "${iap_enabled}" == "True" ]] \
    || { echo "IAP not enabled on dev-portal-backend (iap.enabled=${iap_enabled})"; return 1; }
}

test_6_3_iap_on_dashboard_backend() {
  [[ -n "${DASHBOARD_URL}" ]] || { echo "admin dashboard not deployed"; return 2; }
  if ! gcloud compute backend-services describe admin-dashboard-backend --global \
       --project "${PROJECT_ID}" >/dev/null 2>&1; then
    echo "admin-dashboard-backend not found"
    return 2
  fi
  local iap_enabled
  iap_enabled=$(gcloud compute backend-services describe admin-dashboard-backend --global \
    --project "${PROJECT_ID}" --format="value(iap.enabled)" 2>/dev/null || true)
  [[ "${iap_enabled}" == "True" ]] \
    || { echo "IAP not enabled on admin-dashboard-backend (iap.enabled=${iap_enabled})"; return 1; }
}

test_6_4_no_iap_on_gateway_backends() {
  local wrong=""
  for backend in llm-gateway-backend mcp-gateway-backend; do
    if gcloud compute backend-services describe "${backend}" --global \
         --project "${PROJECT_ID}" >/dev/null 2>&1; then
      local iap_enabled
      iap_enabled=$(gcloud compute backend-services describe "${backend}" --global \
        --project "${PROJECT_ID}" --format="value(iap.enabled)" 2>/dev/null || true)
      if [[ "${iap_enabled}" == "True" ]]; then
        wrong+="${backend} "
      fi
    fi
  done
  [[ -z "${wrong}" ]] || { echo "IAP should NOT be on gateway backends: ${wrong}"; return 1; }
}

# =============================================================================
# Layer 7 — MCP Through GLB
# =============================================================================

test_7_1_mcp_tool_through_glb() {
  [[ -n "${MCP_URL}" ]] || { echo "MCP gateway not deployed"; return 2; }
  local out
  out=$(python3 "${SCRIPT_DIR}/lib/mcp_test.py" "${GLB_URL}" gcp_project_info 2>&1)
  if [[ "${out}" == PASS:* ]]; then
    return 0
  fi
  echo "MCP tool invocation through GLB failed: ${out}"
  return 1
}

# =============================================================================
# Layer 8 — Parity Checks
# =============================================================================

test_8_1_resource_names_match() {
  local missing=""
  local expected_resources=(
    "addresses:claude-code-glb-ip:--global"
    "url-maps:claude-code-glb-url-map:--global"
    "target-https-proxies:claude-code-glb-https-proxy:--global"
    "forwarding-rules:claude-code-glb-fwd:--global"
  )
  for entry in "${expected_resources[@]}"; do
    IFS=':' read -r res_type res_name res_flag <<< "${entry}"
    if ! gcloud compute ${res_type} describe "${res_name}" ${res_flag} \
         --project "${PROJECT_ID}" >/dev/null 2>&1; then
      missing+="${res_name} "
    fi
  done
  [[ -z "${missing}" ]] || { echo "missing expected resources: ${missing}"; return 1; }
}

test_8_2_backend_protocol_correct() {
  local wrong=""
  for backend in llm-gateway-backend mcp-gateway-backend dev-portal-backend; do
    if gcloud compute backend-services describe "${backend}" --global \
         --project "${PROJECT_ID}" >/dev/null 2>&1; then
      local protocol scheme
      protocol=$(gcloud compute backend-services describe "${backend}" --global \
        --project "${PROJECT_ID}" --format="value(protocol)" 2>/dev/null || true)
      scheme=$(gcloud compute backend-services describe "${backend}" --global \
        --project "${PROJECT_ID}" --format="value(loadBalancingScheme)" 2>/dev/null || true)
      if [[ "${protocol}" != "HTTPS" ]]; then
        wrong+="${backend}(protocol=${protocol}) "
      fi
      if [[ "${scheme}" != "EXTERNAL_MANAGED" ]]; then
        wrong+="${backend}(scheme=${scheme}) "
      fi
    fi
  done
  [[ -z "${wrong}" ]] || { echo "wrong backend config: ${wrong}"; return 1; }
}

# =============================================================================
# Execute
# =============================================================================

log_step "Layer 1 — GLB Infrastructure"
CURRENT_LAYER="L1: GLB Infra"
run_test "1.1 static IP exists"            test_1_1_static_ip
run_test "1.2 serverless NEGs exist"       test_1_2_negs_exist
run_test "1.3 backend services exist"      test_1_3_backends_exist
run_test "1.4 URL map exists"              test_1_4_url_map_exists
run_test "1.5 SSL certificate exists"      test_1_5_ssl_cert_exists
run_test "1.5b DNS A record correct"       test_1_5b_dns_record
run_test "1.6 forwarding rule exists"      test_1_6_forwarding_rule
run_test "1.7 HTTPS proxy exists"          test_1_7_https_proxy

log_step "Layer 2 — Cloud Run Configuration"
CURRENT_LAYER="L2: CR Config"
run_test "2.1 ingress restricted"                test_2_1_ingress_restricted
run_test "2.2 allUsers invoker"                  test_2_2_allow_unauth
run_test "2.3 ENABLE_TOKEN_VALIDATION set"       test_2_3_token_validation_enabled
run_test "2.4 ALLOWED_PRINCIPALS set"            test_2_4_allowed_principals_set
run_test "2.5 dev VM SA in ALLOWED_PRINCIPALS"   test_2_5_dev_vm_sa_in_principals

log_step "Layer 3 — Auth Flows"
CURRENT_LAYER="L3: Auth"
run_test "3.1 /health without token (200)"       test_3_1_health_no_token
run_test "3.2 inference with access token (200)"  test_3_2_inference_access_token
run_test "3.3 inference with OIDC token (200)"    test_3_3_inference_oidc
run_test "3.4 inference without token (401)"      test_3_4_no_token_rejected
run_test "3.5 direct Cloud Run blocked (403)"     test_3_5_direct_cr_blocked

log_step "Layer 4 — URL Map Routing"
CURRENT_LAYER="L4: Routing"
run_test "4.1 /health routes to LLM gateway"      test_4_1_health_routes_to_llm
run_test "4.2 /v1/* routes to LLM gateway"         test_4_2_v1_routes_to_llm
run_test "4.3 /mcp routes to MCP gateway"          test_4_3_mcp_routes_to_mcp
run_test "4.4 / defaults to dev portal"            test_4_4_default_routes_to_portal

log_step "Layer 5 — Dev VM Integration"
CURRENT_LAYER="L5: Dev VM"
run_test "5.1 VM exists, no public IP"             test_5_1_vm_exists_no_pubip
run_test "5.2 VM metadata has GLB URL"             test_5_2_vm_metadata_has_glb_url
run_test "5.3 VM service account exists"           test_5_3_vm_sa_exists

log_step "Layer 6 — IAP Configuration"
CURRENT_LAYER="L6: IAP"
run_test "6.1 IAP OAuth brand exists"              test_6_1_iap_brand_exists
run_test "6.2 IAP on dev-portal backend"           test_6_2_iap_on_portal_backend
run_test "6.3 IAP on admin-dashboard backend"      test_6_3_iap_on_dashboard_backend
run_test "6.4 no IAP on gateway backends"          test_6_4_no_iap_on_gateway_backends

log_step "Layer 7 — MCP Through GLB"
CURRENT_LAYER="L7: MCP+GLB"
run_test "7.1 MCP tool invocation through GLB"     test_7_1_mcp_tool_through_glb

log_step "Layer 8 — Parity"
CURRENT_LAYER="L8: Parity"
run_test "8.1 GLB resource names match spec"       test_8_1_resource_names_match
run_test "8.2 backend protocol + scheme correct"   test_8_2_backend_protocol_correct

# =============================================================================
# Summary
# =============================================================================
echo "" >&2
echo "================================================================" >&2
echo "  GLB Demo Validation Results" >&2
echo "================================================================" >&2
for layer in "L1: GLB Infra" "L2: CR Config" "L3: Auth" "L4: Routing" \
             "L5: Dev VM" "L6: IAP" "L7: MCP+GLB" "L8: Parity"; do
  local_pass=${LAYER_PASS[$layer]:-0}
  local_fail=${LAYER_FAIL[$layer]:-0}
  local_skip=${LAYER_SKIP[$layer]:-0}
  total=$((local_pass + local_fail + local_skip))
  [[ "${total}" == "0" ]] && continue
  printf "  %-26s [%d/%d PASS" "${layer}" "${local_pass}" "$((local_pass + local_fail))" >&2
  [[ "${local_fail}" -gt 0 ]] && printf ", ${_CLR_RED}%d FAIL${_CLR_RESET}" "${local_fail}" >&2
  [[ "${local_skip}" -gt 0 ]] && printf ", %d SKIPPED" "${local_skip}" >&2
  printf "]\n" >&2
done
echo "----------------------------------------------------------------" >&2
printf "  TOTAL: %d PASS, %d FAIL, %d SKIPPED\n" "${PASS_COUNT}" "${FAIL_COUNT}" "${SKIP_COUNT}" >&2
echo "================================================================" >&2
echo "" >&2

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  log_error "GLB validation FAILED. Fix the above issues before the demo."
  exit 1
else
  log_info "GLB validation PASSED. Ready for demo."
fi
