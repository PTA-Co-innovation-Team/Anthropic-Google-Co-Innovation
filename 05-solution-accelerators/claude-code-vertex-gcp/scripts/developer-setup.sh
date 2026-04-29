#!/usr/bin/env bash
# =============================================================================
# developer-setup.sh — run on a developer's laptop.
#
# What it does:
#   1. Checks gcloud is installed and the user is authenticated.
#   2. Runs `gcloud auth application-default login` (ADC is what
#      Claude Code uses for Vertex auth).
#   3. Installs the Claude Code CLI globally via `npm install -g
#      @anthropic-ai/claude-code` if the `claude` command is missing.
#      Requires Node.js/npm already installed (see the Dev Portal for
#      OS-specific prereqs).
#   4. Writes ~/.claude/settings.json with the right env + MCP config.
#      Asks before overwriting an existing file.
#   5. Tests the connection by hitting /health on the LLM gateway.
#
# Modes:
#   * Interactive (default): prompts for project, gateway URL, region.
#   * Env-driven: set PROJECT_ID / LLM_GATEWAY_URL / MCP_GATEWAY_URL /
#     REGION and run with --yes.
#   * --diagnose: print diagnostics only, don't modify anything.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

print_help() {
  cat <<'HELP'
Usage: developer-setup.sh [--help] [--yes] [--diagnose]

Configure Claude Code on this machine to use the team's Vertex-AI-routed
gateway. Writes ~/.claude/settings.json.

Environment (optional):
  PROJECT_ID         GCP project ID
  REGION             Vertex region (default "global")
  LLM_GATEWAY_URL    Gateway URL (GLB or Cloud Run; auto-discovered if omitted)
  MCP_GATEWAY_URL    MCP gateway URL (auto-discovered if omitted)
  OPUS_MODEL         e.g. claude-opus-4-6
  SONNET_MODEL       e.g. claude-sonnet-4-6
  HAIKU_MODEL        e.g. claude-haiku-4-5@20251001
HELP
}

DIAGNOSE_ONLY=0
for arg in "$@"; do
  [[ "$arg" == "--diagnose" ]] && DIAGNOSE_ONLY=1
done
parse_common_flags "$@"

require_cmd gcloud

# --- Diagnose mode: print environment, don't change anything ----------------
if [[ "${DIAGNOSE_ONLY}" == "1" ]]; then
  log_step "diagnostics"
  gcloud config list 2>/dev/null || true
  gcloud auth list 2>/dev/null || true
  [[ -f "${HOME}/.claude/settings.json" ]] && \
    { log_info "~/.claude/settings.json:"; cat "${HOME}/.claude/settings.json"; } || \
    log_warn "no ~/.claude/settings.json yet"
  exit 0
fi

# --- Prompt for any missing values ------------------------------------------
: "${REGION:=global}"
if [[ -z "${PROJECT_ID:-}" ]]; then
  default_project="$(gcloud config get-value project 2>/dev/null || true)"
  read -rp "GCP project ID [${default_project}]: " PROJECT_ID </dev/tty
  PROJECT_ID="${PROJECT_ID:-${default_project}}"
fi
: "${PROJECT_ID:?project id required}"

if [[ -z "${LLM_GATEWAY_URL:-}" ]]; then
  _discovered="$(resolve_glb_url "${PROJECT_ID}" 2>/dev/null || echo "")"
  if [[ -z "${_discovered}" ]]; then
    for _try_region in "${REGION:-us-central1}" us-central1 us-east5 europe-west1; do
      _discovered="$(gcloud run services describe llm-gateway \
                       --project "${PROJECT_ID}" --region "${_try_region}" \
                       --format="value(status.url)" 2>/dev/null || echo "")"
      [[ -n "${_discovered}" ]] && break
    done
  fi
  read -rp "LLM gateway URL [${_discovered}]: " LLM_GATEWAY_URL </dev/tty
  LLM_GATEWAY_URL="${LLM_GATEWAY_URL:-${_discovered}}"
fi
: "${LLM_GATEWAY_URL:?gateway URL required}"

if [[ -z "${MCP_GATEWAY_URL:-}" ]]; then
  _mcp_default="$(resolve_glb_url "${PROJECT_ID}" 2>/dev/null || echo "")"
  if [[ -z "${_mcp_default}" ]]; then
    for _try_region in "${REGION:-us-central1}" us-central1 us-east5 europe-west1; do
      _mcp_default="$(gcloud run services describe mcp-gateway \
                        --project "${PROJECT_ID}" --region "${_try_region}" \
                        --format="value(status.url)" 2>/dev/null || echo "")"
      [[ -n "${_mcp_default}" ]] && break
    done
  fi
  read -rp "MCP gateway URL (blank to skip) [${_mcp_default}]: " MCP_GATEWAY_URL </dev/tty
  MCP_GATEWAY_URL="${MCP_GATEWAY_URL:-${_mcp_default}}"
fi

: "${OPUS_MODEL:=claude-opus-4-6}"
: "${SONNET_MODEL:=claude-sonnet-4-6}"
: "${HAIKU_MODEL:=claude-haiku-4-5@20251001}"

# --- ADC login --------------------------------------------------------------
log_step "application default credentials"
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  run_cmd gcloud auth application-default login
else
  log_info "ADC already present; skipping login"
fi

# --- Claude Code CLI --------------------------------------------------------
log_step "Claude Code CLI"
if ! command -v claude >/dev/null 2>&1; then
  if ! command -v npm >/dev/null 2>&1; then
    log_warn "npm not found — install Node.js first (see the Dev Portal for"
    log_warn "OS-specific steps), then re-run this script."
    exit 1
  fi
  log_info "installing @anthropic-ai/claude-code via npm"
  run_cmd npm install -g @anthropic-ai/claude-code
else
  log_info "claude CLI already installed; skipping"
fi

# --- Write ~/.claude/settings.json ------------------------------------------
SETTINGS_DIR="${HOME}/.claude"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
mkdir -p "${SETTINGS_DIR}"

if [[ -f "${SETTINGS_FILE}" ]]; then
  log_warn "existing settings file at ${SETTINGS_FILE}"
  if ! confirm "Overwrite?"; then
    log_info "keeping existing settings; aborting without changes"
    exit 0
  fi
  run_cmd cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.bak.$(date +%s)"
fi

# Build the JSON via python3 to guarantee valid output and correct
# escaping.  Values are passed through env vars (not heredoc
# interpolation) to avoid shell-injection footguns.
require_cmd python3
run_cmd env \
  _REGION="${REGION}" \
  _PROJECT_ID="${PROJECT_ID}" \
  _LLM_GATEWAY_URL="${LLM_GATEWAY_URL}" \
  _MCP_GATEWAY_URL="${MCP_GATEWAY_URL}" \
  _OPUS_MODEL="${OPUS_MODEL}" \
  _SONNET_MODEL="${SONNET_MODEL}" \
  _HAIKU_MODEL="${HAIKU_MODEL}" \
  python3 - "${SETTINGS_FILE}" <<'PY'
import json, os, sys

path = sys.argv[1]

# Load existing settings so we preserve keys we don't manage.
try:
    with open(path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

# Merge our env vars into the existing env block.
env = settings.setdefault("env", {})
env.update({
    "CLAUDE_CODE_USE_VERTEX": "1",
    "CLOUD_ML_REGION": os.environ["_REGION"],
    "ANTHROPIC_VERTEX_PROJECT_ID": os.environ["_PROJECT_ID"],
    "ANTHROPIC_VERTEX_BASE_URL": os.environ["_LLM_GATEWAY_URL"],
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": os.environ["_OPUS_MODEL"],
    "ANTHROPIC_DEFAULT_SONNET_MODEL": os.environ["_SONNET_MODEL"],
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": os.environ["_HAIKU_MODEL"],
})

import re
gateway_url = os.environ["_LLM_GATEWAY_URL"]
if re.match(r"^https://\d+\.\d+\.\d+\.\d+", gateway_url):
    env["NODE_TLS_REJECT_UNAUTHORIZED"] = "0"
else:
    env.pop("NODE_TLS_REJECT_UNAUTHORIZED", None)

mcp = os.environ.get("_MCP_GATEWAY_URL", "").strip()
if mcp:
    settings.setdefault("mcpServers", {})["gcp-tools"] = {
        "type": "http",
        "url": f"{mcp.rstrip('/')}/mcp",
    }

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
print(f"wrote {path}")
PY

if [[ "${LLM_GATEWAY_URL}" =~ ^https://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  log_info "self-signed cert: added NODE_TLS_REJECT_UNAUTHORIZED=0 to settings.json"
  log_info "to switch to a trusted cert, re-run deploy.sh and choose managed certificate"
else
  log_info "domain-based URL detected — using Google-managed certificate (no TLS workaround needed)"
fi

# --- Connection smoke test --------------------------------------------------
log_step "connection smoke test"

# Quick reachability probe (no auth). Internal-only services return
# connection errors from outside the VPC.
_SKIP_SMOKE=false
_probe="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 \
            "${LLM_GATEWAY_URL%/}/healthz" 2>/dev/null || echo "000")"
if [[ "${_probe}" == "000" ]]; then
  log_warn "cannot reach ${LLM_GATEWAY_URL} — service uses internal-only ingress"
  log_warn ""
  log_warn "This is expected for VPC-internal deployments. Two options:"
  log_warn "  1. If a GLB is deployed, re-run with the GLB URL instead:"
  log_warn "       LLM_GATEWAY_URL=<glb-url> ./scripts/developer-setup.sh"
  _glb_fallback="$(resolve_glb_url "${PROJECT_ID}" 2>/dev/null || echo "")"
  if [[ -n "${_glb_fallback}" && "${_glb_fallback}" != "${LLM_GATEWAY_URL}" ]]; then
    log_info "     GLB detected: ${_glb_fallback}"
  fi
  log_warn "  2. SSH into the dev VM via IAP and run Claude Code from there:"
  log_warn "       gcloud compute ssh --tunnel-through-iap --project=${PROJECT_ID} claude-code-dev-shared"
  log_warn ""
  log_warn "No VPN required — IAP provides secure access."
  log_warn "skipping smoke test (service unreachable from this network)"
  _SKIP_SMOKE=true
fi

if [[ "${_SKIP_SMOKE}" == "false" ]]; then
  # Use an ADC access token — this is the same token type Claude Code sends.
  # Cloud Run's IAM check is disabled (--no-invoker-iam-check); the gateway's
  # app-level token_validation middleware validates the token instead.
  TOKEN="$(gcloud auth application-default print-access-token 2>/dev/null \
           || gcloud auth print-identity-token --audiences="${LLM_GATEWAY_URL%/}" 2>/dev/null \
           || true)"
  # Use -k for IP-based URLs (GLB with self-signed cert).
  _CURL_K=""
  if [[ "${LLM_GATEWAY_URL}" =~ ^https://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    _CURL_K="-k"
  fi
  if [[ -n "${TOKEN}" ]]; then
    status="$(curl -sS ${_CURL_K} -o /dev/null -w '%{http_code}' --connect-timeout 10 \
                -H "Authorization: Bearer ${TOKEN}" \
                "${LLM_GATEWAY_URL%/}/health" || echo "000")"
    case "${status}" in
      200) log_info "smoke test passed — gateway /health returned 200" ;;
      401|403) log_warn "gateway returned ${status} — your identity may not be in ALLOWED_PRINCIPALS."
               log_warn "ask your admin to add your principal to the gateway's allowed list." ;;
      000) log_warn "could not reach gateway (service may use internal-only ingress — access via GLB or dev VM)" ;;
      *) log_warn "unexpected status from gateway: ${status}" ;;
    esac
  else
    log_warn "no credentials available; couldn't smoke-test the gateway"
  fi
fi

log_step "setup complete"
log_info "settings written to ${SETTINGS_FILE}"
if [[ "${_SKIP_SMOKE}" == "true" ]]; then
  log_info "smoke test skipped (gateway unreachable from this network — see guidance above)"
fi
log_info "start Claude Code with: claude"
