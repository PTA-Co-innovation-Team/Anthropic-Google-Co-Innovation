#!/usr/bin/env bash
# =============================================================================
# pre-deploy-check.sh — local code consistency checks.
#
# Runs WITHOUT GCP access. Validates that all GLB + hybrid-auth changes
# are internally consistent across deploy scripts, Terraform modules,
# and application code. Run before deploying to catch parity issues.
#
# Exit codes: 0 = all pass, 1 = at least one failure.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

print_help() {
  cat <<'HELP'
Usage: pre-deploy-check.sh [--help] [--verbose]

Local code consistency checks. No GCP access required.
Validates GLB + hybrid-auth parity across all files.
HELP
}

parse_common_flags "$@"
REPO_ROOT="$(resolve_repo_root)"

# --- Colors (reuse from common.sh if available) ----------------------------
_GREEN="${_CLR_GREEN:-\033[32m}"
_RED="${_CLR_RED:-\033[31m}"
_YELLOW="${_CLR_YELLOW:-\033[33m}"
_RESET="${_CLR_RESET:-\033[0m}"

PASS=0
FAIL=0
SKIP=0

_check() {
  local name="$1"; shift
  local output
  set +e
  output="$("$@" 2>&1)"
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    printf "${_GREEN}  PASS${_RESET}  %s\n" "$name" >&2
    PASS=$((PASS + 1))
  elif [[ $rc -eq 2 ]]; then
    printf "${_YELLOW}  SKIP${_RESET}  %s  %s\n" "$name" "$output" >&2
    SKIP=$((SKIP + 1))
  else
    printf "${_RED}  FAIL${_RESET}  %s  %s\n" "$name" "$output" >&2
    FAIL=$((FAIL + 1))
  fi
}

# =============================================================================
# Check 1: Unit tests pass
# =============================================================================
check_unit_tests() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found"; return 2
  fi
  if ! python3 -m pytest --version >/dev/null 2>&1; then
    echo "pytest not installed"; return 2
  fi
  local output
  output=$(cd "${REPO_ROOT}" && python3 -m pytest gateway/tests/ -q --tb=short 2>&1)
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "gateway tests failed: ${output}"
    return 1
  fi
}

# =============================================================================
# Check 2: token_validation.py files in sync
# =============================================================================
check_token_validation_sync() {
  local gw="${REPO_ROOT}/gateway/app/token_validation.py"
  local mcp="${REPO_ROOT}/mcp-gateway/token_validation.py"

  [[ -f "${gw}" ]]  || { echo "gateway token_validation.py not found"; return 1; }
  [[ -f "${mcp}" ]] || { echo "mcp-gateway token_validation.py not found"; return 1; }

  # The MCP copy has a "Keep in sync" comment header (up to 5 extra lines).
  # Compare everything from the first import statement onward.
  local diff_count
  diff_count=$(diff <(sed -n '/^from\|^import/,$p' "${gw}") \
                    <(sed -n '/^from\|^import/,$p' "${mcp}") \
               | grep -c '^[<>]' || true)

  if [[ "${diff_count}" -gt 0 ]]; then
    echo "functional code differs by ${diff_count} lines (comparing from first import onward)"
    return 1
  fi
}

# =============================================================================
# Check 3: Deploy scripts have GLB conditionals
# =============================================================================
check_deploy_scripts_glb() {
  local missing=""
  for script in deploy-llm-gateway.sh deploy-mcp-gateway.sh deploy-dev-portal.sh deploy-observability.sh; do
    if ! grep -q 'ENABLE_GLB' "${REPO_ROOT}/scripts/${script}" 2>/dev/null; then
      missing+="${script} "
    fi
  done
  # deploy-dev-vm.sh must be GLB-aware for URL discovery
  if ! grep -q 'ENABLE_GLB' "${REPO_ROOT}/scripts/deploy-dev-vm.sh" 2>/dev/null; then
    missing+="deploy-dev-vm.sh "
  fi
  [[ -z "${missing}" ]] || { echo "missing ENABLE_GLB handling: ${missing}"; return 1; }
}

# =============================================================================
# Check 4: Gateway scripts include dev VM SA in ALLOWED_PRINCIPALS
# =============================================================================
check_dev_vm_sa_in_allowed() {
  local missing=""
  for script in deploy-llm-gateway.sh deploy-mcp-gateway.sh; do
    if ! grep -q 'claude-code-dev-vm' "${REPO_ROOT}/scripts/${script}" 2>/dev/null; then
      missing+="${script} "
    fi
  done
  [[ -z "${missing}" ]] || { echo "dev VM SA not in ALLOWED_PRINCIPALS: ${missing}"; return 1; }
}

# =============================================================================
# Check 5: Terraform modules have enable_glb variable
# =============================================================================
check_terraform_glb_vars() {
  local missing=""
  for mod in llm_gateway mcp_gateway dev_portal; do
    local varfile="${REPO_ROOT}/terraform/modules/${mod}/variables.tf"
    if ! grep -q 'enable_glb' "${varfile}" 2>/dev/null; then
      missing+="${mod} "
    fi
  done
  [[ -z "${missing}" ]] || { echo "missing enable_glb variable: ${missing}"; return 1; }
}

# =============================================================================
# Check 6: Terraform root passes gateway_allowed_principals
# =============================================================================
check_terraform_gateway_principals() {
  local main="${REPO_ROOT}/terraform/main.tf"
  if ! grep -q 'gateway_allowed_principals' "${main}" 2>/dev/null; then
    echo "root main.tf does not use gateway_allowed_principals"
    return 1
  fi
  local vars="${REPO_ROOT}/terraform/variables.tf"
  if ! grep -q 'gateway_allowed_principals' "${vars}" 2>/dev/null; then
    echo "root variables.tf does not define gateway_allowed_principals"
    return 1
  fi
}

# =============================================================================
# Check 7: GLB Terraform module has all 4 backends
# =============================================================================
check_glb_module_backends() {
  local main="${REPO_ROOT}/terraform/modules/glb/main.tf"
  [[ -f "${main}" ]] || { echo "GLB module main.tf not found"; return 1; }

  local missing=""
  for backend in llm_gateway mcp_gateway dev_portal admin_dashboard; do
    if ! grep -q "google_compute_backend_service.*${backend}" "${main}" 2>/dev/null; then
      missing+="${backend} "
    fi
  done
  [[ -z "${missing}" ]] || { echo "missing backend services: ${missing}"; return 1; }
}

# =============================================================================
# Check 8: GLB module has IAP bindings for both portal and dashboard
# =============================================================================
check_glb_iap_bindings() {
  local main="${REPO_ROOT}/terraform/modules/glb/main.tf"
  local missing=""
  if ! grep -q 'portal_access' "${main}" 2>/dev/null; then
    missing+="portal_access "
  fi
  if ! grep -q 'dashboard_access' "${main}" 2>/dev/null; then
    missing+="dashboard_access "
  fi
  [[ -z "${missing}" ]] || { echo "missing IAP bindings: ${missing}"; return 1; }
}

# =============================================================================
# Check 9: Teardown handles all GLB resources
# =============================================================================
check_teardown_glb() {
  local teardown="${REPO_ROOT}/scripts/teardown.sh"
  [[ -f "${teardown}" ]] || { echo "teardown.sh not found"; return 1; }

  local missing=""
  for resource in "claude-code-glb-fwd" "claude-code-glb-https-proxy" \
                  "claude-code-glb-url-map" "claude-code-glb-ip" \
                  "claude-code-glb-cert" "claude-code-glb-self-signed" \
                  "admin-dashboard-backend" "admin-dashboard-neg" \
                  "admin-dashboard"; do
    if ! grep -q "${resource}" "${teardown}" 2>/dev/null; then
      missing+="${resource} "
    fi
  done
  # Teardown must clean up DNS A records before deleting the GLB IP.
  if ! grep -q 'dns record-sets' "${teardown}" 2>/dev/null; then
    missing+="dns-record-cleanup "
  fi
  [[ -z "${missing}" ]] || { echo "teardown missing resources: ${missing}"; return 1; }
}

# =============================================================================
# Check 10: deploy.sh orchestration order is correct
# =============================================================================
check_deploy_ordering() {
  local deploy="${REPO_ROOT}/scripts/deploy.sh"
  [[ -f "${deploy}" ]] || { echo "deploy.sh not found"; return 1; }

  # GLB must deploy AFTER gateway services and BEFORE dev VM
  local glb_line mcp_line vm_line
  glb_line=$(grep -n 'deploy-glb.sh' "${deploy}" | head -1 | cut -d: -f1)
  mcp_line=$(grep -n 'deploy-mcp-gateway.sh' "${deploy}" | head -1 | cut -d: -f1)
  vm_line=$(grep -n 'deploy-dev-vm.sh' "${deploy}" | head -1 | cut -d: -f1)

  if [[ -z "${glb_line}" ]]; then
    echo "deploy-glb.sh not called in deploy.sh"
    return 1
  fi
  if [[ "${glb_line}" -lt "${mcp_line}" ]]; then
    echo "deploy-glb.sh runs before deploy-mcp-gateway.sh (wrong order)"
    return 1
  fi
  if [[ -n "${vm_line}" && "${glb_line}" -gt "${vm_line}" ]]; then
    echo "deploy-glb.sh runs after deploy-dev-vm.sh (wrong order)"
    return 1
  fi
}

# =============================================================================
# Check 11: deploy-glb.sh has self-signed cert support
# =============================================================================
check_glb_self_signed_cert() {
  local script="${REPO_ROOT}/scripts/deploy-glb.sh"
  [[ -f "${script}" ]] || { echo "deploy-glb.sh not found"; return 1; }
  if ! grep -q 'openssl' "${script}" 2>/dev/null; then
    echo "deploy-glb.sh missing self-signed cert generation (no openssl reference)"
    return 1
  fi
}

# =============================================================================
# Check 11b: deploy-glb.sh has DNS record creation for managed certs
# =============================================================================
check_glb_dns_record() {
  local script="${REPO_ROOT}/scripts/deploy-glb.sh"
  [[ -f "${script}" ]] || { echo "deploy-glb.sh not found"; return 1; }
  if ! grep -q 'dns record-sets' "${script}" 2>/dev/null; then
    echo "deploy-glb.sh missing DNS record creation for managed certs"
    return 1
  fi
  if ! grep -q 'dns managed-zones' "${script}" 2>/dev/null; then
    echo "deploy-glb.sh missing Cloud DNS zone discovery"
    return 1
  fi
}

# =============================================================================
# Check 12: deploy-glb.sh creates IAP OAuth brand + client
# =============================================================================
check_glb_iap_brand() {
  local script="${REPO_ROOT}/scripts/deploy-glb.sh"
  if ! grep -q 'oauth-brands' "${script}" 2>/dev/null; then
    echo "deploy-glb.sh missing IAP OAuth brand creation"
    return 1
  fi
  if ! grep -q 'oauth-clients' "${script}" 2>/dev/null; then
    echo "deploy-glb.sh missing IAP OAuth client creation"
    return 1
  fi
}

# =============================================================================
# Check 13: deploy-dev-vm.sh discovers GLB URL
# =============================================================================
check_dev_vm_glb_discovery() {
  local script="${REPO_ROOT}/scripts/deploy-dev-vm.sh"
  if ! grep -q 'claude-code-glb-ip\|resolve_glb_url' "${script}" 2>/dev/null; then
    echo "deploy-dev-vm.sh does not discover GLB IP"
    return 1
  fi
  if ! grep -q 'GLB_URL' "${script}" 2>/dev/null; then
    echo "deploy-dev-vm.sh does not use GLB URL"
    return 1
  fi
}

# =============================================================================
# Check 14: Terraform GLB module has admin_dashboard_service_name variable
# =============================================================================
check_glb_admin_dashboard_var() {
  local varfile="${REPO_ROOT}/terraform/modules/glb/variables.tf"
  if ! grep -q 'admin_dashboard_service_name' "${varfile}" 2>/dev/null; then
    echo "GLB module missing admin_dashboard_service_name variable"
    return 1
  fi
  local main="${REPO_ROOT}/terraform/main.tf"
  if ! grep -q 'admin_dashboard_service_name' "${main}" 2>/dev/null; then
    echo "root main.tf does not pass admin_dashboard_service_name to GLB module"
    return 1
  fi
}

# =============================================================================
# Check 15: URL map default routes to dev portal
# =============================================================================
check_url_map_default_portal() {
  local tf="${REPO_ROOT}/terraform/modules/glb/main.tf"
  local bash_script="${REPO_ROOT}/scripts/deploy-glb.sh"

  # Terraform: path_matcher default_service should conditionally use dev_portal
  if ! grep -A2 'default_service' "${tf}" | grep -q 'dev_portal'; then
    echo "Terraform URL map path_matcher does not default to dev_portal"
    return 1
  fi

  # Bash: default backend should check dev-portal first
  if ! grep -B2 'DEFAULT_BACKEND=' "${bash_script}" | grep -q 'dev-portal'; then
    echo "Bash URL map does not default to dev-portal"
    return 1
  fi
}

# =============================================================================
# Check 16: Middleware registers conditionally in both gateways
# =============================================================================
check_middleware_registration() {
  local missing=""
  local gw_main="${REPO_ROOT}/gateway/app/main.py"
  local mcp_main="${REPO_ROOT}/mcp-gateway/server.py"

  if ! grep -q 'ENABLE_TOKEN_VALIDATION' "${gw_main}" 2>/dev/null; then
    missing+="gateway/app/main.py "
  fi
  if ! grep -q 'ENABLE_TOKEN_VALIDATION' "${mcp_main}" 2>/dev/null; then
    missing+="mcp-gateway/server.py "
  fi
  [[ -z "${missing}" ]] || { echo "missing middleware registration: ${missing}"; return 1; }
}

# =============================================================================
# Check 17: proxy.py has caller identity fallback to request.state
# =============================================================================
check_proxy_caller_fallback() {
  local proxy="${REPO_ROOT}/gateway/app/proxy.py"
  if ! grep -q 'request.state.*caller_email\|caller_email.*request.state' "${proxy}" 2>/dev/null; then
    echo "proxy.py missing caller identity fallback to request.state"
    return 1
  fi
}

# =============================================================================
# Check 18: MCP Dockerfile copies token_validation.py
# =============================================================================
check_mcp_dockerfile() {
  local dockerfile="${REPO_ROOT}/mcp-gateway/Dockerfile"
  [[ -f "${dockerfile}" ]] || { echo "mcp-gateway/Dockerfile not found"; return 1; }
  if ! grep -q 'token_validation' "${dockerfile}" 2>/dev/null; then
    echo "mcp-gateway/Dockerfile does not COPY token_validation.py"
    return 1
  fi
}

# =============================================================================
# Check 19: versions.tf includes tls provider
# =============================================================================
check_tls_provider() {
  local versions="${REPO_ROOT}/terraform/versions.tf"
  [[ -f "${versions}" ]] || { echo "versions.tf not found"; return 2; }
  if ! grep -q 'tls' "${versions}" 2>/dev/null; then
    echo "versions.tf missing tls provider (needed for self-signed certs)"
    return 1
  fi
}

# =============================================================================
# Check 20: VPC internal ingress — three-way conditional in all deploy scripts
# =============================================================================
check_vpc_internal_deploy_scripts() {
  local missing=""
  for script in deploy-llm-gateway.sh deploy-mcp-gateway.sh deploy-dev-portal.sh deploy-observability.sh; do
    if ! grep -q 'ENABLE_VPC_INTERNAL' "${REPO_ROOT}/scripts/${script}" 2>/dev/null; then
      missing+="${script} "
    fi
  done
  [[ -z "${missing}" ]] || { echo "missing ENABLE_VPC_INTERNAL handling: ${missing}"; return 1; }
}

# =============================================================================
# Check 21: VPC internal — Terraform modules have enable_vpc_internal variable
# =============================================================================
check_terraform_vpc_internal_vars() {
  local missing=""
  for mod in llm_gateway mcp_gateway dev_portal network; do
    local varfile="${REPO_ROOT}/terraform/modules/${mod}/variables.tf"
    if ! grep -q 'enable_vpc_internal' "${varfile}" 2>/dev/null; then
      missing+="${mod} "
    fi
  done
  [[ -z "${missing}" ]] || { echo "missing enable_vpc_internal variable: ${missing}"; return 1; }
}

# =============================================================================
# Check 22: VPC internal — reachability pre-checks in developer-facing scripts
# =============================================================================
check_vpc_reachability_checks() {
  local missing=""
  for script in developer-setup.sh e2e-test.sh seed-demo-data.sh; do
    if ! grep -q 'healthz\|_probe' "${REPO_ROOT}/scripts/${script}" 2>/dev/null; then
      missing+="${script} "
    fi
  done
  [[ -z "${missing}" ]] || { echo "missing reachability pre-check: ${missing}"; return 1; }
}

# =============================================================================
# Check 23: VPC internal — deploy.sh exports ENABLE_VPC_INTERNAL
# =============================================================================
check_deploy_exports_vpc() {
  local deploy="${REPO_ROOT}/scripts/deploy.sh"
  if ! grep -q 'export.*ENABLE_VPC_INTERNAL' "${deploy}" 2>/dev/null; then
    echo "deploy.sh does not export ENABLE_VPC_INTERNAL"
    return 1
  fi
  if ! grep -q 'ENABLE_GLB.*ENABLE_VPC_INTERNAL.*mutually exclusive' "${deploy}" 2>/dev/null; then
    echo "deploy.sh missing mutual exclusion guard"
    return 1
  fi
}

# =============================================================================
# Check 25: IAP access model — deploy.sh does NOT say "requires VPN"
# =============================================================================
check_no_vpn_in_prompts() {
  local deploy="${REPO_ROOT}/scripts/deploy.sh"
  if grep -q 'requires VPN' "${deploy}" 2>/dev/null; then
    echo "deploy.sh still mentions 'requires VPN' in interactive prompts"
    return 1
  fi
}

# =============================================================================
# Check 26: Developer-facing scripts guide toward IAP, not VPN
# =============================================================================
check_iap_guidance_not_vpn() {
  local issues=""
  for script in developer-setup.sh e2e-test.sh seed-demo-data.sh; do
    local path="${REPO_ROOT}/scripts/${script}"
    if grep -q 'must be on.*VPN\|network / VPN' "${path}" 2>/dev/null; then
      issues+="${script} "
    fi
  done
  [[ -z "${issues}" ]] || { echo "scripts still guide toward VPN: ${issues}"; return 1; }
}

# =============================================================================
# Check 27: IAP firewall rules defined in network module
# =============================================================================
check_iap_firewall_rules() {
  local netmain="${REPO_ROOT}/terraform/modules/network/main.tf"
  local missing=""
  if ! grep -q 'allow_iap_ssh' "${netmain}" 2>/dev/null; then
    missing+="allow-iap-ssh "
  fi
  if ! grep -q 'allow_iap_web' "${netmain}" 2>/dev/null; then
    missing+="allow-iap-web "
  fi
  [[ -z "${missing}" ]] || { echo "missing IAP firewall rules: ${missing}"; return 1; }
}

# =============================================================================
# Check 29: deploy-dev-vm.sh provisions Cloud NAT before VM creation
# =============================================================================
check_deploy_cloud_nat() {
  local script="${REPO_ROOT}/scripts/deploy-dev-vm.sh"
  local missing=""
  if ! grep -q 'routers create' "${script}" 2>/dev/null; then
    missing+="cloud-router "
  fi
  if ! grep -q 'routers nats create' "${script}" 2>/dev/null; then
    missing+="cloud-nat "
  fi
  if [[ -z "${missing}" ]]; then
    local nat_line vm_line
    nat_line=$(grep -n 'routers nats create' "${script}" | head -1 | cut -d: -f1)
    vm_line=$(grep -n 'instances create' "${script}" | head -1 | cut -d: -f1)
    if [[ -n "${nat_line}" && -n "${vm_line}" && "${nat_line}" -gt "${vm_line}" ]]; then
      missing+="ordering(NAT-after-VM) "
    fi
  fi
  [[ -z "${missing}" ]] || { echo "missing Cloud NAT in deploy-dev-vm.sh: ${missing}"; return 1; }
}

# =============================================================================
# Check 30: Terraform network module has Cloud NAT resources
# =============================================================================
check_terraform_cloud_nat() {
  local netmain="${REPO_ROOT}/terraform/modules/network/main.tf"
  local netvars="${REPO_ROOT}/terraform/modules/network/variables.tf"
  local rootmain="${REPO_ROOT}/terraform/main.tf"
  local missing=""
  if ! grep -q 'google_compute_router"' "${netmain}" 2>/dev/null; then
    missing+="google_compute_router "
  fi
  if ! grep -q 'google_compute_router_nat' "${netmain}" 2>/dev/null; then
    missing+="google_compute_router_nat "
  fi
  if ! grep -q 'enable_cloud_nat' "${netvars}" 2>/dev/null; then
    missing+="enable_cloud_nat-variable "
  fi
  if ! grep -q 'enable_cloud_nat' "${rootmain}" 2>/dev/null; then
    missing+="enable_cloud_nat-wiring "
  fi
  [[ -z "${missing}" ]] || { echo "Cloud NAT missing from Terraform: ${missing}"; return 1; }
}

# =============================================================================
# Check 31: Teardown cleans up Cloud NAT and Cloud Router
# =============================================================================
check_teardown_cloud_nat() {
  local teardown="${REPO_ROOT}/scripts/teardown.sh"
  local missing=""
  if ! grep -q 'claude-code-nat' "${teardown}" 2>/dev/null; then
    missing+="cloud-nat "
  fi
  if ! grep -q 'claude-code-router' "${teardown}" 2>/dev/null; then
    missing+="cloud-router "
  fi
  [[ -z "${missing}" ]] || { echo "teardown missing Cloud NAT cleanup: ${missing}"; return 1; }
}

# =============================================================================
# Check 32: BQ view definitions in sync (bash deploy script + Terraform)
# =============================================================================
check_bq_view_definitions() {
  local deploy="${REPO_ROOT}/scripts/deploy-observability.sh"
  local tfmain="${REPO_ROOT}/terraform/modules/observability/main.tf"
  local views=("v_requests_summary" "v_error_analysis" "v_latency_stats" "v_top_callers" "v_recent_requests")
  local missing=""
  for view in "${views[@]}"; do
    if ! grep -q "${view}" "${deploy}" 2>/dev/null; then
      missing+="${view}(bash) "
    fi
    if ! grep -q "${view}" "${tfmain}" 2>/dev/null; then
      missing+="${view}(terraform) "
    fi
  done
  [[ -z "${missing}" ]] || { echo "BQ view definitions out of sync: ${missing}"; return 1; }
}

# =============================================================================
# Check 33: setup-looker-studio.sh exists and references all views
# =============================================================================
check_looker_studio_script() {
  local script="${REPO_ROOT}/scripts/setup-looker-studio.sh"
  local missing=""
  if [[ ! -f "${script}" ]]; then
    echo "scripts/setup-looker-studio.sh does not exist"; return 1
  fi
  local views=("v_requests_summary" "v_error_analysis" "v_latency_stats" "v_top_callers" "v_recent_requests")
  for view in "${views[@]}"; do
    if ! grep -q "${view}" "${script}" 2>/dev/null; then
      missing+="${view} "
    fi
  done
  if ! grep -q 'lookerstudio.google.com' "${script}" 2>/dev/null; then
    missing+="lookerstudio-url "
  fi
  [[ -z "${missing}" ]] || { echo "setup-looker-studio.sh incomplete: ${missing}"; return 1; }
}

# =============================================================================
# Check 34: Dashboard uses raw table discovery (not views)
# =============================================================================
check_dashboard_not_broken_by_views() {
  local dashboard="${REPO_ROOT}/dashboard/app.py"
  local missing=""
  if ! grep -q 'INFORMATION_SCHEMA.TABLES' "${dashboard}" 2>/dev/null; then
    missing+="INFORMATION_SCHEMA-discovery "
  fi
  if ! grep -q 'run_googleapis_com_' "${dashboard}" 2>/dev/null; then
    missing+="raw-table-prefix "
  fi
  [[ -z "${missing}" ]] || { echo "dashboard lost raw table discovery: ${missing}"; return 1; }
}

# =============================================================================
# Run all checks
# =============================================================================
log_step "Pre-deploy code consistency checks"

echo "" >&2
log_info "--- Unit Tests ---"
_check "1. Gateway unit tests pass" check_unit_tests

echo "" >&2
log_info "--- Token Validation Middleware ---"
_check "2.  token_validation.py files in sync" check_token_validation_sync
_check "3.  Middleware registered conditionally" check_middleware_registration
_check "4.  proxy.py caller identity fallback" check_proxy_caller_fallback
_check "5.  MCP Dockerfile copies middleware" check_mcp_dockerfile

echo "" >&2
log_info "--- Deploy Script GLB Handling ---"
_check "6.  Deploy scripts have GLB conditionals" check_deploy_scripts_glb
_check "7.  Gateway scripts include dev VM SA" check_dev_vm_sa_in_allowed
_check "8.  deploy.sh orchestration order" check_deploy_ordering
_check "9.  deploy-glb.sh self-signed cert" check_glb_self_signed_cert
_check "9b. deploy-glb.sh DNS record creation" check_glb_dns_record
_check "10. deploy-glb.sh IAP brand + client" check_glb_iap_brand
_check "11. deploy-dev-vm.sh GLB URL discovery" check_dev_vm_glb_discovery
_check "12. URL map defaults to dev portal" check_url_map_default_portal

echo "" >&2
log_info "--- Terraform Module Consistency ---"
_check "13. Cloud Run modules have enable_glb" check_terraform_glb_vars
_check "14. Root uses gateway_allowed_principals" check_terraform_gateway_principals
_check "15. GLB module has all 4 backends" check_glb_module_backends
_check "16. GLB module has IAP bindings" check_glb_iap_bindings
_check "17. GLB module admin_dashboard wired" check_glb_admin_dashboard_var
_check "18. versions.tf has tls provider" check_tls_provider

echo "" >&2
log_info "--- VPC Internal Ingress ---"
_check "20. Deploy scripts have VPC internal conditionals" check_vpc_internal_deploy_scripts
_check "21. Terraform modules have enable_vpc_internal" check_terraform_vpc_internal_vars
_check "22. Reachability pre-checks in user scripts" check_vpc_reachability_checks
_check "23. deploy.sh exports + guards VPC internal" check_deploy_exports_vpc

echo "" >&2
log_info "--- IAP Access Model ---"
_check "25. deploy.sh prompts do not mention VPN" check_no_vpn_in_prompts
_check "26. Developer scripts guide toward IAP" check_iap_guidance_not_vpn
_check "27. IAP firewall rules in network module" check_iap_firewall_rules

echo "" >&2
log_info "--- Cloud NAT ---"
_check "29. deploy-dev-vm.sh provisions Cloud NAT" check_deploy_cloud_nat
_check "30. Terraform network module has Cloud NAT" check_terraform_cloud_nat
_check "31. Teardown cleans up Cloud NAT + Router" check_teardown_cloud_nat

echo "" >&2
log_info "--- Teardown Coverage ---"
_check "28. Teardown handles all GLB resources" check_teardown_glb

echo "" >&2
log_info "--- Looker Studio ---"
_check "32. BQ view definitions in sync (bash + TF)" check_bq_view_definitions
_check "33. setup-looker-studio.sh exists and complete" check_looker_studio_script
_check "34. Dashboard uses raw table discovery (not views)" check_dashboard_not_broken_by_views

# --- Summary ---------------------------------------------------------------
echo "" >&2
echo "================================================================" >&2
echo "  Pre-deploy Check Results" >&2
echo "================================================================" >&2
printf "  TOTAL: %d PASS, %d FAIL, %d SKIPPED\n" "${PASS}" "${FAIL}" "${SKIP}" >&2
echo "================================================================" >&2

[[ "${FAIL}" -eq 0 ]] || exit 1
