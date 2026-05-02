#!/usr/bin/env bash
# =============================================================================
# preflight.sh — read-only pre-deployment gate.
#
# Catches the most-common deployment-time failures BEFORE any GCP write.
# Each check prints PASS/FAIL/WARN with a one-line remediation on FAIL.
# Exits non-zero on first FAIL so deploy.sh is gated.
#
# Safe to run repeatedly. Makes no GCP writes.
#
# Reads:
#   PROJECT_ID, REGION, FALLBACK_REGION, ENABLE_GLB, GLB_DOMAIN,
#   IAP_SUPPORT_EMAIL, PRINCIPALS  (the same env that deploy.sh exports)
#
# Or, if invoked standalone, accepts:
#   --project <id>
#   --region <vertex region; default global>
#   --principals <csv>
#   --enable-glb
#   --glb-domain <domain>
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

print_help() {
  cat <<'HELP'
Usage: preflight.sh [--project <id>] [--region <region>] [--principals <csv>]
                    [--enable-glb] [--glb-domain <domain>]

Read-only validator. Runs ~14 checks; prints PASS/WARN/FAIL with a
one-line remediation on FAIL. Exits non-zero on first FAIL.

Safe to run any time. Does NOT modify any GCP resources.
HELP
}

parse_common_flags "$@"
set -- "${_REMAINING_ARGS[@]:-}"

# Local-flag parse.
while (($#)); do
  case "${1:-}" in
    --project)        PROJECT_ID="$2"; shift 2 ;;
    --region)         REGION="$2"; shift 2 ;;
    --principals)     PRINCIPALS="$2"; shift 2 ;;
    --enable-glb)     ENABLE_GLB=true; shift ;;
    --glb-domain)     GLB_DOMAIN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-global}"
ENABLE_GLB="${ENABLE_GLB:-false}"
GLB_DOMAIN="${GLB_DOMAIN:-}"
IAP_SUPPORT_EMAIL="${IAP_SUPPORT_EMAIL:-}"
PRINCIPALS="${PRINCIPALS:-}"

PASS_CT=0
FAIL_CT=0
WARN_CT=0

_pass() { echo "  ${_CLR_GREEN}[PASS]${_CLR_RESET} $*" >&2; PASS_CT=$((PASS_CT+1)); }
_warn() { echo "  ${_CLR_YELLOW}[WARN]${_CLR_RESET} $*" >&2; WARN_CT=$((WARN_CT+1)); }
_fail() {
  echo "  ${_CLR_RED}[FAIL]${_CLR_RESET} $*" >&2
  FAIL_CT=$((FAIL_CT+1))
  if [[ -n "${2:-}" ]]; then
    echo "         ↳ fix: ${2}" >&2
  fi
}
_fail_msg() {
  echo "  ${_CLR_RED}[FAIL]${_CLR_RESET} $1" >&2
  echo "         ↳ fix: $2" >&2
  FAIL_CT=$((FAIL_CT+1))
}

# -----------------------------------------------------------------------------
log_step "Preflight — read-only validation against project: ${PROJECT_ID:-<unset>}"
# -----------------------------------------------------------------------------

# === 1. CLI tools ===========================================================
log_info "[1/14] required CLI tools"
for cmd in gcloud python3 git curl; do
  if command -v "$cmd" >/dev/null 2>&1; then
    _pass "$cmd present ($(command -v "$cmd"))"
  else
    _fail_msg "$cmd not found on PATH" "install $cmd; on macOS: brew install $cmd"
  fi
done

# Optional: terraform (only required if user picks the TF path)
if command -v terraform >/dev/null 2>&1; then
  _tf_ver=$(terraform version -json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || echo "unknown")
  _pass "terraform present (${_tf_ver}) — optional, used by IaC path only"
else
  _warn "terraform not on PATH — only matters if you use the TF deployment path"
fi

# === 2. gcloud version ======================================================
log_info "[2/14] gcloud version"
_gcloud_ver=$(gcloud version --format="value(\"Google Cloud SDK\")" 2>/dev/null | head -1)
if [[ -n "${_gcloud_ver}" ]]; then
  _pass "gcloud SDK ${_gcloud_ver}"
else
  _warn "could not parse gcloud version (non-fatal)"
fi

# === 3. PROJECT_ID set ======================================================
log_info "[3/14] project id"
if [[ -z "${PROJECT_ID}" ]]; then
  _fail_msg "PROJECT_ID is not set" "pass --project <id> or run: gcloud config set project <id>"
else
  _pass "PROJECT_ID=${PROJECT_ID}"
fi

# === 4. gcloud auth =========================================================
log_info "[4/14] gcloud auth"
_active_acct=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
if [[ -z "${_active_acct}" ]]; then
  _fail_msg "no active gcloud account" "run: gcloud auth login"
else
  _pass "active account: ${_active_acct}"
fi

# === 5. ADC ==================================================================
log_info "[5/14] application default credentials"
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  _pass "ADC works (gcloud auth application-default print-access-token returns a token)"
else
  _fail_msg "ADC is not configured" "run: gcloud auth application-default login"
fi

# === 6. project exists & user has rights =====================================
log_info "[6/14] project access"
if [[ -n "${PROJECT_ID}" ]]; then
  if gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1; then
    _pass "project ${PROJECT_ID} is reachable"
  else
    _fail_msg "cannot describe project ${PROJECT_ID}" "verify the ID and that ${_active_acct:-your account} has roles/viewer or higher; or: gcloud projects list"
  fi
fi

# === 7. billing enabled ======================================================
log_info "[7/14] billing"
if [[ -n "${PROJECT_ID}" ]]; then
  _billing=$(gcloud beta billing projects describe "${PROJECT_ID}" \
              --format="value(billingEnabled)" 2>/dev/null || echo "")
  case "${_billing}" in
    True|true) _pass "billing is enabled" ;;
    False|false) _fail_msg "billing is NOT enabled on ${PROJECT_ID}" "link a billing account: console.cloud.google.com/billing/linkedaccount?project=${PROJECT_ID}" ;;
    *) _warn "could not determine billing status (non-fatal — gcloud beta may need install)" ;;
  esac
fi

# === 8. user has owner/editor ================================================
log_info "[8/14] caller IAM role"
if [[ -n "${PROJECT_ID}" && -n "${_active_acct}" ]]; then
  _roles=$(gcloud projects get-iam-policy "${PROJECT_ID}" \
            --flatten="bindings[].members" \
            --filter="bindings.members:user:${_active_acct} OR bindings.members:serviceAccount:${_active_acct}" \
            --format="value(bindings.role)" 2>/dev/null | tr '\n' ',' || true)
  if echo "${_roles}" | grep -qE "roles/owner|roles/editor"; then
    _pass "${_active_acct} has Owner/Editor"
  else
    _warn "${_active_acct} does not appear to hold roles/owner or roles/editor — deploy may fail when binding IAM"
    _warn "  observed roles: ${_roles:-<none>}"
  fi
fi

# === 9. required APIs enableable ============================================
log_info "[9/14] required APIs enableable"
_apis=(aiplatform.googleapis.com run.googleapis.com compute.googleapis.com
       iap.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com
       logging.googleapis.com monitoring.googleapis.com iamcredentials.googleapis.com
       secretmanager.googleapis.com serviceusage.googleapis.com bigquery.googleapis.com)
if [[ -n "${PROJECT_ID}" ]]; then
  _api_failures=()
  for api in "${_apis[@]}"; do
    if gcloud services list --available --project "${PROJECT_ID}" \
         --filter="config.name:${api}" --format="value(config.name)" 2>/dev/null | grep -q "${api}"; then
      :
    else
      _api_failures+=("${api}")
    fi
  done
  if (( ${#_api_failures[@]} == 0 )); then
    _pass "all 12 required APIs are listable (deploy.sh will enable them)"
  else
    _warn "could not list ${#_api_failures[@]} APIs (org policy may block — re-check after enabling): ${_api_failures[*]}"
  fi
fi

# === 10. Vertex AI Anthropic models — accessibility test ====================
log_info "[10/14] Vertex AI Claude model access"
if [[ -n "${PROJECT_ID}" ]]; then
  _vertex_region="us-east5"
  if [[ "${REGION}" != "global" && "${REGION}" != "us" && "${REGION}" != "europe" && "${REGION}" != "asia" ]]; then
    _vertex_region="${REGION}"
  fi
  _vertex_host="${_vertex_region}-aiplatform.googleapis.com"
  [[ "${REGION}" == "global" ]] && _vertex_host="aiplatform.googleapis.com"

  _token=$(gcloud auth application-default print-access-token 2>/dev/null || echo "")
  if [[ -z "${_token}" ]]; then
    _warn "skipping Vertex Claude check — no ADC token"
  else
    _model_id="claude-haiku-4-5@20251001"
    _model_safe="claude-haiku-4-5"
    _url="https://${_vertex_host}/v1/projects/${PROJECT_ID}/locations/${_vertex_region}/publishers/anthropic/models/${_model_safe}:rawPredict"
    _payload='{"anthropic_version":"vertex-2023-10-16","messages":[{"role":"user","content":"hi"}],"max_tokens":4}'
    _http=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 \
              -X POST "${_url}" \
              -H "Authorization: Bearer ${_token}" \
              -H "Content-Type: application/json" \
              -d "${_payload}" 2>/dev/null || echo "000")
    case "${_http}" in
      200|429)
        _pass "Vertex AI Claude Haiku is reachable in ${_vertex_region} (HTTP ${_http})" ;;
      404)
        _fail_msg "Claude Haiku 4.5 returned 404 from Vertex" \
                  "enable Anthropic models in Model Garden: console.cloud.google.com/vertex-ai/model-garden?project=${PROJECT_ID} (search 'Claude', click Enable on Haiku 4.5)" ;;
      403)
        _fail_msg "Vertex returned 403" \
                  "grant ${_active_acct} roles/aiplatform.user, or check org policy is not blocking aiplatform.googleapis.com" ;;
      400)
        _warn "Vertex returned 400 — model probably enabled but request format is rejected (non-fatal for preflight)" ;;
      000)
        _warn "could not reach Vertex (network?). Will retry during deploy." ;;
      *)
        _warn "unexpected Vertex HTTP ${_http} from preflight probe — investigate before deploy" ;;
    esac
  fi
fi

# === 11. ALLOWED_PRINCIPALS shape ===========================================
log_info "[11/14] allowed principals"
if [[ -z "${PRINCIPALS}" ]]; then
  _warn "PRINCIPALS not set — deploy will default to: user:\$(gcloud config get-value account)"
else
  IFS=',' read -ra _parts <<<"${PRINCIPALS}"
  _bad=0
  for p in "${_parts[@]}"; do
    p="${p## }"; p="${p%% }"
    [[ -z "${p}" ]] && continue
    if [[ ! "${p}" =~ ^(user|group|serviceAccount):[^[:space:]]+@[^[:space:]]+$ ]]; then
      _fail "principal '${p}' is not a valid IAM member"
      _bad=$((_bad+1))
    fi
  done
  if (( _bad == 0 )); then
    _pass "${#_parts[@]} principal(s) parsed cleanly"
  fi
fi

# === 11b. Dev VM prereqs (only when --enable-vm) ============================
log_info "[11b/14] Dev VM prereqs (skipped unless --enable-vm)"
if [[ "${ENABLE_VM:-false}" == "true" ]]; then
  if [[ -n "${PROJECT_ID}" ]]; then
    _net="${NETWORK_NAME:-default}"
    _cr_region="${FALLBACK_REGION:-us-central1}"

    # Network existence — strict for non-default, auto-create-ready for default.
    if gcloud compute networks describe "${_net}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
      _pass "VPC '${_net}' exists"
      # Subnet check when SUBNET_NAME is given.
      if [[ -n "${SUBNET_NAME:-}" ]]; then
        if gcloud compute networks subnets describe "${SUBNET_NAME}" \
             --project "${PROJECT_ID}" --region "${_cr_region}" >/dev/null 2>&1; then
          _pass "subnet '${SUBNET_NAME}' exists in ${_cr_region}"
          # Warn if Private Google Access is off.
          _pga=$(gcloud compute networks subnets describe "${SUBNET_NAME}" \
                   --project "${PROJECT_ID}" --region "${_cr_region}" \
                   --format="value(privateIpGoogleAccess)" 2>/dev/null || echo "")
          if [[ "${_pga}" == "True" ]]; then
            _pass "Private Google Access is ON for subnet '${SUBNET_NAME}'"
          else
            _warn "Private Google Access is OFF on '${SUBNET_NAME}' — Vertex calls will work over public hostname but lose privacy benefit. Toggle: gcloud compute networks subnets update ${SUBNET_NAME} --project ${PROJECT_ID} --region ${_cr_region} --enable-private-ip-google-access"
          fi
        else
          _fail_msg "subnet '${SUBNET_NAME}' not found in ${_cr_region}" \
                    "verify the subnet name and region, or unset SUBNET_NAME to use auto-mode"
        fi
      fi
    elif [[ "${_net}" == "default" ]]; then
      _warn "default VPC missing — deploy will auto-create it (auto-mode subnets, free)"
    else
      _fail_msg "VPC '${_net}' does not exist on ${PROJECT_ID}" \
                "create it first, or unset NETWORK_NAME to fall back to default"
    fi

    # NAT existence — only relevant if SKIP_NAT is not set. Detect any NAT
    # already on this network in the region; warn so the user doesn't end up
    # with a duplicate when SKIP_NAT could have been used.
    if [[ "${SKIP_NAT:-false}" != "true" ]]; then
      _existing_nat_router=$(gcloud compute routers list --project "${PROJECT_ID}" \
                              --regions "${_cr_region}" \
                              --filter="network~/${_net}\$" \
                              --format="value(name)" 2>/dev/null | head -1 || true)
      if [[ -z "${_existing_nat_router}" ]]; then
        _pass "no Cloud Router on '${_net}' in ${_cr_region} — deploy will create one"
      elif [[ "${_existing_nat_router}" == "claude-code-nat-router" ]]; then
        _pass "claude-code-nat-router already exists (idempotent re-deploy)"
      else
        _warn "another Cloud Router '${_existing_nat_router}' exists on '${_net}'/${_cr_region}. If it has NAT configured, set SKIP_NAT=true to avoid duplicates."
      fi
    else
      _pass "SKIP_NAT=true — assuming you have NAT configured already"
    fi
  fi
else
  _pass "skipped (Dev VM not enabled)"
fi

# === 12. GLB-mode prereqs (only when --enable-glb) ==========================
log_info "[12/14] GLB prereqs (skipped unless --enable-glb)"
if [[ "${ENABLE_GLB}" == "true" ]]; then
  if [[ -z "${IAP_SUPPORT_EMAIL}" ]]; then
    _warn "GLB mode enabled but IAP_SUPPORT_EMAIL is empty — IAP setup will be skipped"
  else
    _pass "IAP support email: ${IAP_SUPPORT_EMAIL}"
  fi
  if [[ -n "${GLB_DOMAIN}" ]]; then
    _parent="${GLB_DOMAIN#*.}"
    _zone=$(gcloud dns managed-zones list --project "${PROJECT_ID}" \
              --filter="dnsName=${_parent}." --format="value(name)" 2>/dev/null | head -1 || true)
    if [[ -n "${_zone}" ]]; then
      _pass "Cloud DNS managed zone for ${_parent} found (${_zone}) — deploy will auto-create A record"
    else
      _warn "no Cloud DNS zone for ${_parent} — you'll need to create the A record manually after deploy prints the IP"
    fi
  else
    _warn "GLB mode without --glb-domain — will use self-signed cert (developer-setup.sh handles NODE_TLS_REJECT_UNAUTHORIZED automatically)"
  fi

  # IAP-specific checks when ENABLE_IAP=true.
  if [[ "${ENABLE_IAP:-false}" == "true" ]]; then
    if [[ -z "${IAP_SUPPORT_EMAIL}" ]]; then
      _fail_msg "IAP enabled but IAP_SUPPORT_EMAIL is empty" \
                "set IAP_SUPPORT_EMAIL=<your support email> or answer the deploy.sh prompt"
    else
      _pass "IAP support email: ${IAP_SUPPORT_EMAIL}"
    fi
    # Check the iap.googleapis.com API isn't blocked by org policy.
    if gcloud services list --available --project "${PROJECT_ID}" \
        --filter="config.name:iap.googleapis.com" --format="value(config.name)" 2>/dev/null \
        | grep -q "iap.googleapis.com"; then
      _pass "iap.googleapis.com is enableable on ${PROJECT_ID}"
    else
      _warn "could not list iap.googleapis.com — org policy may be blocking; deploy will surface clearly if so"
    fi
    # Heads-up about consent screen first-time setup.
    _PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || echo "")"
    if [[ -n "${_PROJECT_NUMBER}" ]]; then
      if ! gcloud iap oauth-brands describe "projects/${_PROJECT_NUMBER}/brands/${_PROJECT_NUMBER}" \
          --project "${PROJECT_ID}" >/dev/null 2>&1; then
        _warn "no IAP OAuth brand exists yet — deploy will try to create it; if your org blocks programmatic creation, see remediation in deploy-glb.sh output"
      else
        _pass "IAP OAuth brand already exists in ${PROJECT_ID}"
      fi
    fi
  fi
else
  _pass "skipped (standard mode)"
fi

# === 13. stale resources from previous partial run ==========================
log_info "[13/14] stale GLB / Cloud Run state from previous runs"
if [[ -n "${PROJECT_ID}" ]]; then
  _stale=()
  for res in claude-code-glb-fwd claude-code-glb-https-proxy claude-code-glb-url-map claude-code-glb-cert claude-code-glb-ip; do
    if gcloud compute "${res##*-}s" describe "${res}" --global --project "${PROJECT_ID}" >/dev/null 2>&1; then
      _stale+=("${res}")
    fi
  done
  # Above is loose; better to just check the static IP since that's the common one.
  if gcloud compute addresses describe claude-code-glb-ip --global --project "${PROJECT_ID}" >/dev/null 2>&1; then
    _warn "static IP claude-code-glb-ip already exists — deploy will reuse it (this is normal on re-runs)"
  fi
  for svc in llm-gateway mcp-gateway dev-portal admin-dashboard; do
    if gcloud run services describe "${svc}" --project "${PROJECT_ID}" \
        --region us-central1 >/dev/null 2>&1; then
      _warn "Cloud Run service '${svc}' already exists in us-central1 — deploy will create a new revision (idempotent)"
    fi
  done
  _pass "no blocking stale state detected"
fi

# === 13b. Traffic-policy env-var format (off unless set) ====================
log_info "[13b/14] traffic-policy env vars"
_tp_problems=0
if [[ -n "${RATE_LIMIT_PER_MIN:-}" ]]; then
  if [[ "${RATE_LIMIT_PER_MIN}" =~ ^[0-9]+$ ]] && (( RATE_LIMIT_PER_MIN > 0 )); then
    _pass "RATE_LIMIT_PER_MIN=${RATE_LIMIT_PER_MIN}"
  else
    _fail_msg "RATE_LIMIT_PER_MIN='${RATE_LIMIT_PER_MIN}' is not a positive integer" \
              "set to a positive integer or unset"
    _tp_problems=$((_tp_problems+1))
  fi
fi
if [[ -n "${RATE_LIMIT_BURST:-}" ]]; then
  if [[ "${RATE_LIMIT_BURST}" =~ ^[0-9]+$ ]] && (( RATE_LIMIT_BURST > 0 )); then
    _pass "RATE_LIMIT_BURST=${RATE_LIMIT_BURST}"
  else
    _fail_msg "RATE_LIMIT_BURST='${RATE_LIMIT_BURST}' is not a positive integer" \
              "set to a positive integer or unset"
    _tp_problems=$((_tp_problems+1))
  fi
fi
if [[ -n "${TOKEN_LIMIT_PER_MIN:-}" ]]; then
  if [[ "${TOKEN_LIMIT_PER_MIN}" =~ ^[0-9]+$ ]] && (( TOKEN_LIMIT_PER_MIN > 0 )); then
    _pass "TOKEN_LIMIT_PER_MIN=${TOKEN_LIMIT_PER_MIN}"
  else
    _fail_msg "TOKEN_LIMIT_PER_MIN='${TOKEN_LIMIT_PER_MIN}' is not a positive integer" \
              "set to a positive integer or unset"
    _tp_problems=$((_tp_problems+1))
  fi
fi
if [[ -n "${TOKEN_LIMIT_BURST:-}" ]]; then
  if [[ "${TOKEN_LIMIT_BURST}" =~ ^[0-9]+$ ]] && (( TOKEN_LIMIT_BURST > 0 )); then
    _pass "TOKEN_LIMIT_BURST=${TOKEN_LIMIT_BURST}"
  else
    _fail_msg "TOKEN_LIMIT_BURST='${TOKEN_LIMIT_BURST}' is not a positive integer" \
              "set to a positive integer or unset"
    _tp_problems=$((_tp_problems+1))
  fi
fi
if [[ -n "${EDITORS:-}" ]]; then
  IFS=',' read -ra _editors <<<"${EDITORS}"
  _ed_bad=0
  for e in "${_editors[@]}"; do
    e="${e## }"; e="${e%% }"
    [[ -z "${e}" ]] && continue
    if [[ ! "${e}" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then
      _fail "EDITORS entry '${e}' is not a valid email"
      _ed_bad=$((_ed_bad+1))
    fi
  done
  if (( _ed_bad == 0 )); then
    _pass "EDITORS configured (${#_editors[@]} email(s)) — settings tab will be enabled for these users"
  fi
fi
if [[ -n "${ALLOWED_MODELS:-}" ]]; then
  # Loose validation — at least one comma-or-no-comma list of non-space chars.
  if [[ "${ALLOWED_MODELS}" =~ ^[^[:space:]]+(,[^[:space:]]+)*$ ]]; then
    _pass "ALLOWED_MODELS configured ($(echo "${ALLOWED_MODELS}" | tr ',' '\n' | wc -l) entries)"
  else
    _fail_msg "ALLOWED_MODELS contains whitespace or is malformed" \
              "use comma-separated model names with no spaces, e.g. ALLOWED_MODELS=claude-haiku-4-5,claude-sonnet-4-6"
    _tp_problems=$((_tp_problems+1))
  fi
fi
if [[ -n "${MODEL_REWRITE:-}" ]]; then
  # Each entry must be from=to with non-empty sides.
  IFS=',' read -ra _rules <<<"${MODEL_REWRITE}"
  _rw_bad=0
  for r in "${_rules[@]}"; do
    if [[ ! "${r}" =~ ^[^[:space:]=]+=[^[:space:]=]+$ ]]; then
      _fail "MODEL_REWRITE entry '${r}' is malformed (expected from=to)"
      _rw_bad=$((_rw_bad+1))
    fi
  done
  if (( _rw_bad == 0 )); then
    _pass "MODEL_REWRITE configured (${#_rules[@]} rules)"
  fi
fi
if [[ "${_tp_problems}" -eq 0 && -z "${RATE_LIMIT_PER_MIN:-}${ALLOWED_MODELS:-}${MODEL_REWRITE:-}" ]]; then
  _pass "no traffic-policy env vars set — gateway runs in pure pass-through mode"
fi

# === 14. token_validation parity (static, no GCP) ===========================
log_info "[14/14] gateway/mcp token_validation parity"
REPO_ROOT="$(resolve_repo_root)"
if [[ -f "${REPO_ROOT}/gateway/app/token_validation.py" && \
      -f "${REPO_ROOT}/mcp-gateway/token_validation.py" ]]; then
  if diff <(awk '/^import/{found=1} found' "${REPO_ROOT}/gateway/app/token_validation.py") \
          <(awk '/^import/{found=1} found' "${REPO_ROOT}/mcp-gateway/token_validation.py") \
          >/dev/null 2>&1; then
    _pass "token_validation.py is in sync between gateway and mcp-gateway"
  else
    _fail_msg "token_validation.py diverges between gateway and mcp-gateway" \
              "diff gateway/app/token_validation.py mcp-gateway/token_validation.py — copy one into the other"
  fi
else
  _warn "could not find both token_validation.py copies"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo "" >&2
echo "${_CLR_BOLD}Preflight summary:${_CLR_RESET} ${PASS_CT} pass · ${WARN_CT} warn · ${FAIL_CT} fail" >&2
if (( FAIL_CT > 0 )); then
  echo "${_CLR_RED}preflight FAILED${_CLR_RESET} — fix the items above and re-run." >&2
  exit 1
fi
if (( WARN_CT > 0 )); then
  echo "${_CLR_YELLOW}preflight passed with warnings.${_CLR_RESET} Review them before continuing." >&2
fi
exit 0
