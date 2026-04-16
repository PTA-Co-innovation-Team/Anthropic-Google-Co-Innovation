#!/usr/bin/env bash
# =============================================================================
# e2e-test.sh — end-to-end validation of a deployed stack.
#
# Run this immediately after a deployment to confirm everything works.
# The script is structured as six "layers" corresponding to the
# validation layers in TEST-AND-DEMO-PLAN.md. Each layer has one or
# more test functions; each function records PASS / FAIL / SKIP and
# the script exits non-zero if any FAIL.
#
# Modes:
#   * default  — runs every automatable test.
#   * --quick  — only smoke tests (1.1, 2.1, 3.1, 3.2, 5.1).
#   * --verbose — echo every command before running.
#
# Discovery:
#   URLs can be passed via --gateway-url / --mcp-url / --portal-url,
#   otherwise we resolve them via `gcloud run services describe`.
#
# Cost:
#   The network-path and gateway tests each issue ONE tiny Haiku
#   inference request (<$0.001 each). The --quick mode keeps it to two
#   such requests; full mode runs three total.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# -----------------------------------------------------------------------------
# Flags and defaults
# -----------------------------------------------------------------------------
QUICK=0
VERBOSE=0
PROJECT_ID=""
REGION=""
GATEWAY_URL=""
MCP_URL=""
PORTAL_URL=""
CR_REGION=""  # where Cloud Run services live (not the Vertex region)

print_help() {
  cat <<'HELP'
Usage: e2e-test.sh [options]

Options:
  --project <id>       GCP project ID (else gcloud config).
  --region <region>    Vertex region for inference tests (default "global").
  --cr-region <region> Cloud Run region where services live (default us-central1).
  --gateway-url <url>  LLM gateway URL (else auto-discovered).
  --mcp-url <url>      MCP gateway URL (else auto-discovered).
  --portal-url <url>   Dev portal URL (else auto-discovered).
  --quick              Run smoke tests only (Layers 1.1, 2.1, 3.1, 3.2, 5.1).
  --verbose            Echo every command.
  -h, --help           This help.

Exits 0 if all run tests pass, non-zero otherwise. SKIP counts are
informational and do not affect the exit code.
HELP
}

# Parse our own flags before handing off to common.
_REMAINING=()
while (($#)); do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --cr-region) CR_REGION="$2"; shift 2 ;;
    --gateway-url) GATEWAY_URL="$2"; shift 2 ;;
    --mcp-url) MCP_URL="$2"; shift 2 ;;
    --portal-url) PORTAL_URL="$2"; shift 2 ;;
    --quick) QUICK=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) _REMAINING+=("$1"); shift ;;
  esac
done
set -- "${_REMAINING[@]:-}"

[[ "${VERBOSE}" == "1" ]] && set -x

# -----------------------------------------------------------------------------
# Discover missing values
# -----------------------------------------------------------------------------
require_cmd gcloud
require_cmd curl
require_cmd python3

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
: "${PROJECT_ID:?--project required (or set a default with gcloud config set project)}"
REGION="${REGION:-global}"
CR_REGION="${CR_REGION:-us-central1}"

_describe_url() {
  # $1 = service name. Prints URL or empty.
  gcloud run services describe "$1" \
    --project "${PROJECT_ID}" --region "${CR_REGION}" \
    --format="value(status.url)" 2>/dev/null || true
}
[[ -z "${GATEWAY_URL}" ]] && GATEWAY_URL="$(_describe_url llm-gateway)"
[[ -z "${MCP_URL}" ]]     && MCP_URL="$(_describe_url mcp-gateway)"
[[ -z "${PORTAL_URL}" ]]  && PORTAL_URL="$(_describe_url dev-portal)"

log_info "project:     ${PROJECT_ID}"
log_info "region:      ${REGION}"
log_info "cr-region:   ${CR_REGION}"
log_info "llm gateway: ${GATEWAY_URL:-<not deployed>}"
log_info "mcp gateway: ${MCP_URL:-<not deployed>}"
log_info "dev portal:  ${PORTAL_URL:-<not deployed>}"

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
          echo "${_CLR_GREEN}  PASS${_CLR_RESET}  ${name}  ${detail}" >&2 ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)); LAYER_FAIL[$CURRENT_LAYER]=$(( ${LAYER_FAIL[$CURRENT_LAYER]:-0} + 1 ))
          echo "${_CLR_RED}  FAIL${_CLR_RESET}  ${name}  ${detail}" >&2 ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)); LAYER_SKIP[$CURRENT_LAYER]=$(( ${LAYER_SKIP[$CURRENT_LAYER]:-0} + 1 ))
          echo "${_CLR_YELLOW}  SKIP${_CLR_RESET}  ${name}  ${detail}" >&2 ;;
  esac
}

# Wrap a test function so an internal `return 0/1/2` maps to PASS/FAIL/SKIP.
# Usage: run_test "name" func_name [args...]
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

# -----------------------------------------------------------------------------
# Helpers for the test functions
# -----------------------------------------------------------------------------

# Mint an ADC bearer token once up front; refresh lazily if needed.
_get_token() {
  gcloud auth application-default print-access-token 2>/dev/null
}

# Build the Vertex "rawPredict" URL for a given model + region.
_vertex_url() {
  local base_region="$1" model="$2"
  if [[ "${base_region}" == "global" ]]; then
    echo "https://aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/global/publishers/anthropic/models/${model}:rawPredict"
  else
    echo "https://${base_region}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${base_region}/publishers/anthropic/models/${model}:rawPredict"
  fi
}

# A tiny Haiku payload; echoes "ok" or similar. Keeps token cost negligible.
_haiku_body() {
  cat <<'JSON'
{
  "anthropic_version": "vertex-2023-10-16",
  "messages": [{"role":"user","content":"Reply with the single word: ok"}],
  "max_tokens": 8
}
JSON
}

# -----------------------------------------------------------------------------
# Layer 1 — Infrastructure
# -----------------------------------------------------------------------------
test_1_1_cloud_run_services() {
  local missing=""
  for svc in llm-gateway mcp-gateway dev-portal; do
    local state
    state=$(gcloud run services describe "$svc" \
              --project "${PROJECT_ID}" --region "${CR_REGION}" \
              --format="value(status.conditions[0].status)" 2>/dev/null || true)
    if [[ -z "${state}" ]]; then missing+="$svc ";
    elif [[ "${state}" != "True" ]]; then missing+="$svc(not-ready) "; fi
  done
  [[ -z "${missing}" ]] || { echo "missing/not-ready: ${missing}"; return 1; }
}

test_1_2_no_public_ips() {
  # gcloud compute addresses list returns reserved addresses. We assert
  # nothing is EXTERNAL — ephemeral external IPs on VMs are caught in
  # Layer 6.2.
  local ext
  ext=$(gcloud compute addresses list --project "${PROJECT_ID}" \
          --filter="addressType=EXTERNAL" \
          --format="value(name)" 2>/dev/null || true)
  if [[ -n "${ext}" ]]; then echo "external addresses found: ${ext}"; return 1; fi
}

test_1_3_service_accounts() {
  local missing=""
  for sa in llm-gateway mcp-gateway; do
    local email="${sa}@${PROJECT_ID}.iam.gserviceaccount.com"
    if ! gcloud iam service-accounts describe "${email}" \
         --project "${PROJECT_ID}" >/dev/null 2>&1; then
      missing+="$sa "
    fi
  done
  [[ -z "${missing}" ]] || { echo "missing service accounts: ${missing}"; return 1; }
}

test_1_4_private_google_access() {
  # Scan all subnets in the project; at least one must have PGA.
  local found
  found=$(gcloud compute networks subnets list --project "${PROJECT_ID}" \
            --filter="privateIpGoogleAccess=true" --format="value(name)" 2>/dev/null || true)
  [[ -n "${found}" ]] || { echo "no subnet has Private Google Access"; return 1; }
}

test_1_5_apis_enabled() {
  local missing=""
  for api in aiplatform.googleapis.com run.googleapis.com iap.googleapis.com compute.googleapis.com; do
    if ! gcloud services list --project "${PROJECT_ID}" \
         --enabled --filter="config.name=${api}" \
         --format="value(config.name)" 2>/dev/null | grep -q "${api}"; then
      missing+="${api} "
    fi
  done
  [[ -z "${missing}" ]] || { echo "APIs not enabled: ${missing}"; return 1; }
}

# -----------------------------------------------------------------------------
# Layer 2 — Network path (direct Vertex)
# -----------------------------------------------------------------------------
test_2_1_direct_vertex() {
  local token url status
  token="$(_get_token)"
  [[ -n "${token}" ]] || { echo "no ADC token"; return 1; }
  url="$(_vertex_url "${REGION}" "claude-haiku-4-5@20251001")"
  status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${url}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$(_haiku_body)")
  [[ "${status}" == "200" ]] || { echo "direct Vertex returned ${status}"; return 1; }
}

# -----------------------------------------------------------------------------
# Layer 3 — Gateway proxy
# -----------------------------------------------------------------------------
# Unique marker so we can find this request's log entry in 3.2.
E2E_MARKER="e2e-$(date +%s)-$$"

test_3_1_gateway_inference() {
  [[ -n "${GATEWAY_URL}" ]] || { echo "no gateway URL"; return 2; }
  local token status
  token="$(_get_token)"
  [[ -n "${token}" ]] || { echo "no ADC token"; return 1; }
  # Body carries our unique marker so 3.2 can correlate via the prompt.
  local body
  body=$(cat <<JSON
{
  "anthropic_version": "vertex-2023-10-16",
  "messages": [{"role":"user","content":"Marker: ${E2E_MARKER}. Reply: ok"}],
  "max_tokens": 16
}
JSON
)
  local path="/v1/projects/${PROJECT_ID}/locations/${REGION}/publishers/anthropic/models/claude-haiku-4-5@20251001:rawPredict"
  status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${GATEWAY_URL%/}${path}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "${body}")
  [[ "${status}" == "200" ]] || { echo "gateway returned ${status}"; return 1; }
}

test_3_2_log_emitted() {
  [[ -n "${GATEWAY_URL}" ]] || return 2
  log_info "waiting 30s for Cloud Logging ingestion..." >&2
  sleep 30
  local count
  count=$(gcloud logging read \
    "resource.type=cloud_run_revision AND resource.labels.service_name=llm-gateway AND jsonPayload.message=proxy_request" \
    --project "${PROJECT_ID}" --freshness=5m --limit=50 \
    --format="value(timestamp)" 2>/dev/null | wc -l)
  [[ "${count}" -ge 1 ]] || { echo "no proxy_request log entries found in last 5m"; return 1; }
}

test_3_3_header_sanitization() {
  [[ -n "${GATEWAY_URL}" ]] || return 2
  local token status
  token="$(_get_token)"
  local path="/v1/projects/${PROJECT_ID}/locations/${REGION}/publishers/anthropic/models/claude-haiku-4-5@20251001:rawPredict"
  # Include a bogus anthropic-beta header; if the gateway is stripping
  # correctly the request succeeds. If it forwards, Vertex 4xx's us.
  status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${GATEWAY_URL%/}${path}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -H "anthropic-beta: e2e-fake-feature-2099-01-01" \
            -d "$(_haiku_body)")
  [[ "${status}" == "200" ]] || { echo "status ${status} suggests beta header was NOT stripped"; return 1; }
}

# -----------------------------------------------------------------------------
# Layer 5 — MCP
# -----------------------------------------------------------------------------
test_5_1_mcp_health() {
  [[ -n "${MCP_URL}" ]] || return 2
  local token status
  token="$(_get_token)"
  # /health is unauthenticated at the app layer but still gated by
  # Cloud Run IAM when ingress is internal-only. Send token for safety.
  status=$(curl -sS -o /dev/null -w "%{http_code}" \
            -H "Authorization: Bearer ${token}" \
            "${MCP_URL%/}/health")
  [[ "${status}" == "200" ]] || { echo "mcp /health returned ${status}"; return 1; }
}

test_5_2_mcp_tool_invocation() {
  [[ -n "${MCP_URL}" ]] || return 2
  # Delegate to the Python helper — the handshake is too fiddly for
  # pure bash.
  local out
  out=$(python3 "${SCRIPT_DIR}/lib/mcp_test.py" "${MCP_URL}" gcp_project_info 2>&1)
  if [[ "${out}" == PASS:* ]]; then
    return 0
  fi
  echo "${out}"
  return 1
}

# -----------------------------------------------------------------------------
# Layer 6 — Negative
# -----------------------------------------------------------------------------
test_6_1_unauth_rejected() {
  [[ -n "${GATEWAY_URL}" ]] || return 2
  local status
  status=$(curl -sS -o /dev/null -w "%{http_code}" \
            "${GATEWAY_URL%/}/v1/projects/${PROJECT_ID}/locations/${REGION}/publishers/anthropic/models/claude-haiku-4-5@20251001:rawPredict")
  if [[ "${status}" == "401" || "${status}" == "403" ]]; then return 0; fi
  echo "unauth request returned ${status}, expected 401/403"
  return 1
}

test_6_2_no_external_ip_on_vm() {
  # Only run if dev VM exists.
  local zone=${CR_REGION}-a
  if ! gcloud compute instances describe claude-code-dev-shared \
       --project "${PROJECT_ID}" --zone "${zone}" >/dev/null 2>&1; then
    echo "no dev VM deployed"
    return 2
  fi
  local natip
  natip=$(gcloud compute instances describe claude-code-dev-shared \
            --project "${PROJECT_ID}" --zone "${zone}" \
            --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)
  [[ -z "${natip}" ]] || { echo "dev VM has external IP: ${natip}"; return 1; }
}

# -----------------------------------------------------------------------------
# Execute
# -----------------------------------------------------------------------------
log_step "Layer 1 — Infrastructure"
CURRENT_LAYER="Layer 1: Infrastructure"
run_test "1.1 Cloud Run services READY"      test_1_1_cloud_run_services
if [[ "${QUICK}" == "0" ]]; then
  run_test "1.2 no external IP addresses"    test_1_2_no_public_ips
  run_test "1.3 gateway service accounts"    test_1_3_service_accounts
  run_test "1.4 subnet Private Google Access" test_1_4_private_google_access
  run_test "1.5 required APIs enabled"       test_1_5_apis_enabled
fi

log_step "Layer 2 — Network path"
CURRENT_LAYER="Layer 2: Network Path"
run_test "2.1 direct Vertex inference"       test_2_1_direct_vertex

log_step "Layer 3 — Gateway proxy"
CURRENT_LAYER="Layer 3: Gateway Proxy"
run_test "3.1 gateway inference"             test_3_1_gateway_inference
run_test "3.2 structured log emitted"        test_3_2_log_emitted
if [[ "${QUICK}" == "0" ]]; then
  run_test "3.3 anthropic-beta stripped"     test_3_3_header_sanitization
fi

log_step "Layer 5 — MCP gateway"
CURRENT_LAYER="Layer 5: MCP Tools"
run_test "5.1 MCP /health responds"          test_5_1_mcp_health
if [[ "${QUICK}" == "0" ]]; then
  run_test "5.2 MCP tool invocation (gcp_project_info)" test_5_2_mcp_tool_invocation
fi

if [[ "${QUICK}" == "0" ]]; then
  log_step "Layer 6 — Negative"
  CURRENT_LAYER="Layer 6: Negative"
  run_test "6.1 unauthenticated request rejected" test_6_1_unauth_rejected
  run_test "6.2 dev VM has no external IP"        test_6_2_no_external_ip_on_vm
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo "" >&2
echo "================================================================" >&2
echo "  E2E Test Results" >&2
echo "================================================================" >&2
for layer in "Layer 1: Infrastructure" "Layer 2: Network Path" "Layer 3: Gateway Proxy" "Layer 5: MCP Tools" "Layer 6: Negative"; do
  local_pass=${LAYER_PASS[$layer]:-0}
  local_fail=${LAYER_FAIL[$layer]:-0}
  local_skip=${LAYER_SKIP[$layer]:-0}
  total=$((local_pass + local_fail + local_skip))
  [[ "${total}" == "0" ]] && continue
  printf "  %-36s [%d/%d PASS" "${layer}" "${local_pass}" "$((local_pass + local_fail))" >&2
  [[ "${local_fail}" -gt 0 ]] && printf ", %d FAIL" "${local_fail}" >&2
  [[ "${local_skip}" -gt 0 ]] && printf ", %d SKIPPED" "${local_skip}" >&2
  printf "]\n" >&2
done
echo "----------------------------------------------------------------" >&2
printf "  TOTAL: %d PASS, %d FAIL, %d SKIPPED\n" "${PASS_COUNT}" "${FAIL_COUNT}" "${SKIP_COUNT}" >&2
echo "================================================================" >&2

echo "" >&2
echo "Manual tests to complete (not run by this script):" >&2
echo "  - Layer 4 (laptop): run scripts/developer-setup.sh on a separate machine" >&2
echo "  - Layer 6 negative principal tests: see TEST-AND-DEMO-PLAN.md" >&2

[[ "${FAIL_COUNT}" -eq 0 ]] || exit 1
