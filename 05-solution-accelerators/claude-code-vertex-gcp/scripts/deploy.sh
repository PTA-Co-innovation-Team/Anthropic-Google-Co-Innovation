#!/usr/bin/env bash
# =============================================================================
# deploy.sh — top-level interactive deployer.
#
# Two entry modes:
#
#   1. Running from a git clone:
#        ./scripts/deploy.sh
#      The script detects this and calls sibling component scripts
#      directly (scripts/deploy-llm-gateway.sh, etc.).
#
#   2. Running via curl-to-bash:
#        curl -fsSL <raw_url>/scripts/deploy.sh | bash
#      The script detects it isn't in a full repo, clones the
#      repository to a temp dir, and re-executes itself from there.
#
# Behavior either way:
#   * Prompts for project_id, region, components, allowed_principals.
#   * Writes config.yaml to the CURRENT working directory and shows it.
#   * Asks for explicit confirmation before creating any resources.
#   * On yes: runs component scripts in order. Idempotent — safe to
#     re-run after partial failures.
#   * On no: exits 0 with config.yaml preserved for editing.
# =============================================================================

# ----- Repo URL (edit before release) ---------------------------------------
# The raw GitHub URL used when we self-bootstrap via curl-to-bash. When
# you fork this repo for your own use, edit REPO_URL here (or export it
# before running) so the bootstrap clones from your fork.
REPO_URL="${REPO_URL:-https://github.com/PTA-Co-innovation-Team/ANT-claude-code-vertex-gcp.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"

# ----- Self-bootstrap when invoked via curl-to-bash -------------------------
# Detect by looking for the sibling lib/ directory. If it's missing, we
# must clone the full repo to a temp dir and re-exec from there.
_self="${BASH_SOURCE[0]:-$0}"
_self_dir="$(cd "$(dirname "${_self}")" 2>/dev/null && pwd || echo "")"

if [[ -z "${_self_dir}" || ! -f "${_self_dir}/lib/common.sh" ]]; then
  # We're probably being piped from curl. The user is calling us without
  # a local repo.
  tmp_dir="$(mktemp -d -t ccvg-XXXXXXXX)"
  echo "[info] Cloning ${REPO_URL} (branch ${REPO_BRANCH}) into ${tmp_dir}" >&2
  if ! command -v git >/dev/null 2>&1; then
    echo "[error] git is required to self-bootstrap. Install git and re-run." >&2
    exit 1
  fi
  git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${tmp_dir}/repo"
  echo "[info] Re-executing from ${tmp_dir}/repo/scripts/deploy.sh" >&2
  exec bash "${tmp_dir}/repo/scripts/deploy.sh" "$@"
fi

# ----- Normal path: we're inside the repo -----------------------------------
# shellcheck source=lib/common.sh
source "${_self_dir}/lib/common.sh"
# shellcheck source=lib/regions.sh
source "${_self_dir}/lib/regions.sh"

print_help() {
  cat <<'HELP'
Usage: deploy.sh [--help|-h] [--dry-run] [--yes|-y]

Interactive deployer for Claude Code on GCP via Vertex AI.

Options:
  -h, --help       Show this help and exit.
      --dry-run    Print what would be run without creating GCP resources.
  -y, --yes        Assume "yes" at every confirmation prompt. Useful for CI.

Environment:
  REPO_URL         Git URL to clone when self-bootstrapping via curl-to-bash.
                   Defaults to the public GitHub URL.
  REPO_BRANCH      Branch to check out. Defaults to "main".

See README.md and config.example.yaml for details.
HELP
}

parse_common_flags "$@"
set -- "${_REMAINING_ARGS[@]:-}"

REPO_ROOT="$(resolve_repo_root)"
log_info "repo root: ${REPO_ROOT}"

# ----- Preflight ------------------------------------------------------------
log_step "preflight"
require_cmd gcloud
require_cmd python3

# Make sure the user is logged in. ADC + user creds are different; we
# check user creds for gcloud-side operations.
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
  log_error "no active gcloud account. Run: gcloud auth login"
  exit 1
fi

# ----- Interactive config ---------------------------------------------------
log_step "gather configuration"

# Project ID.
default_project="$(gcloud config get-value project 2>/dev/null || true)"
read -rp "GCP project ID [${default_project}]: " PROJECT_ID </dev/tty
PROJECT_ID="${PROJECT_ID:-${default_project}}"
if [[ -z "${PROJECT_ID}" ]]; then
  log_error "project_id is required."
  exit 1
fi

# Region.
REGION="$(pick_region)"
log_info "selected region: ${REGION}"
FALLBACK_REGION="$(fallback_region_for "${REGION}")"

# Components.
_ask_bool() {
  local prompt="$1" default="$2" reply
  read -rp "${prompt} [$([[ ${default} == "true" ]] && echo Y/n || echo y/N)]: " reply </dev/tty
  reply="${reply:-${default}}"
  [[ "${reply,,}" =~ ^(y|yes|true|1)$ ]] && echo "true" || echo "false"
}
ENABLE_LLM="$(_ask_bool "Deploy LLM gateway?" true)"
ENABLE_MCP="$(_ask_bool "Deploy MCP gateway?" true)"
ENABLE_PORTAL="$(_ask_bool "Deploy dev portal?" true)"
ENABLE_VM="$(_ask_bool "Deploy dev VM (costs money)?" false)"
ENABLE_OBS="$(_ask_bool "Install observability (log sink + BQ)?" true)"

# Principals.
echo "" >&2
echo "Google identities to grant access (comma-separated)." >&2
echo "Format: user:[email protected], group:[email protected]" >&2
default_me="user:$(gcloud config get-value account 2>/dev/null || echo [email protected])"
read -rp "Allowed principals [${default_me}]: " PRINCIPALS_INPUT </dev/tty
PRINCIPALS_INPUT="${PRINCIPALS_INPUT:-${default_me}}"

# ----- Write config.yaml ----------------------------------------------------
CONFIG_OUT="${PWD}/config.yaml"
log_step "writing ${CONFIG_OUT}"

# Build the YAML list of principals.
principals_yaml=""
IFS=',' read -ra _parts <<<"${PRINCIPALS_INPUT}"
for p in "${_parts[@]}"; do
  p="${p## }"; p="${p%% }"
  [[ -z "${p}" ]] && continue
  principals_yaml+="    - \"${p}\"
"
done

cat >"${CONFIG_OUT}" <<YAML
# Generated by deploy.sh on $(date -u +%FT%TZ).
# Safe to edit — re-run deploy.sh to re-apply.

project_id: "${PROJECT_ID}"
region: "${REGION}"
fallback_region: "${FALLBACK_REGION}"

components:
  llm_gateway: ${ENABLE_LLM}
  mcp_gateway: ${ENABLE_MCP}
  dev_vm: ${ENABLE_VM}
  dev_portal: ${ENABLE_PORTAL}
  observability: ${ENABLE_OBS}

access:
  allowed_principals:
${principals_yaml}
models:
  pin_versions: true
  opus: "claude-opus-4-6"
  sonnet: "claude-sonnet-4-6"
  haiku: "claude-haiku-4-5@20251001"
YAML

echo "" >&2
cat "${CONFIG_OUT}" >&2
echo "" >&2

# ----- Confirm --------------------------------------------------------------
if ! confirm "Proceed with this configuration?"; then
  log_info "aborted. config.yaml preserved at ${CONFIG_OUT}"
  exit 0
fi

# ----- Export env for component scripts -------------------------------------
export PROJECT_ID REGION FALLBACK_REGION
export ENABLE_LLM ENABLE_MCP ENABLE_PORTAL ENABLE_VM ENABLE_OBS
export PRINCIPALS="${PRINCIPALS_INPUT}"

# ----- Run component scripts ------------------------------------------------
log_step "setting gcloud project"
run_cmd gcloud config set project "${PROJECT_ID}"

log_step "enabling required APIs (idempotent)"
REQUIRED_APIS=(
  aiplatform.googleapis.com run.googleapis.com compute.googleapis.com
  iap.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com
  logging.googleapis.com monitoring.googleapis.com iamcredentials.googleapis.com
  secretmanager.googleapis.com serviceusage.googleapis.com bigquery.googleapis.com
)
run_cmd gcloud services enable "${REQUIRED_APIS[@]}" --project "${PROJECT_ID}"

if [[ "${ENABLE_LLM}" == "true" ]]; then
  log_step "deploy-llm-gateway.sh"
  bash "${REPO_ROOT}/scripts/deploy-llm-gateway.sh"
fi

if [[ "${ENABLE_MCP}" == "true" ]]; then
  log_step "deploy-mcp-gateway.sh"
  bash "${REPO_ROOT}/scripts/deploy-mcp-gateway.sh"
fi

if [[ "${ENABLE_PORTAL}" == "true" ]]; then
  log_step "deploy-dev-portal.sh"
  bash "${REPO_ROOT}/scripts/deploy-dev-portal.sh"
fi

if [[ "${ENABLE_OBS}" == "true" ]]; then
  log_step "deploy-observability.sh"
  bash "${REPO_ROOT}/scripts/deploy-observability.sh"
fi

if [[ "${ENABLE_VM}" == "true" ]]; then
  log_step "deploy-dev-vm.sh"
  bash "${REPO_ROOT}/scripts/deploy-dev-vm.sh"
fi

log_step "done"
log_info "next: run scripts/developer-setup.sh on each developer's laptop."
