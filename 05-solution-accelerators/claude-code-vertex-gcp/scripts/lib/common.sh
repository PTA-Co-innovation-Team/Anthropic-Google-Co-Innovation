#!/usr/bin/env bash
# =============================================================================
# common.sh — shared helpers for all deploy scripts.
#
# Source this from the top of every script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Provides:
#   - Strict error handling (set -euo pipefail, error trap)
#   - Color-coded logging: log_info / log_warn / log_error / log_step
#   - confirm "Proceed?"  -> returns 0 on y/Y, 1 otherwise
#   - require_cmd         -> error out if a CLI tool is missing
#   - DRY_RUN global      -> commands with `run_cmd` echo instead of exec
#   - parse_common_flags  -> handles --help / --dry-run / -h
# =============================================================================

# -----------------------------------------------------------------------------
# Strict mode. Any unset variable, any pipeline failure, any command with
# nonzero exit is fatal.
# -----------------------------------------------------------------------------
set -euo pipefail

# -----------------------------------------------------------------------------
# Color detection. Only use ANSI codes when stdout is a TTY and the user
# hasn't set NO_COLOR=1 (https://no-color.org/).
# -----------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  _CLR_RED=$'\033[31m'
  _CLR_GREEN=$'\033[32m'
  _CLR_YELLOW=$'\033[33m'
  _CLR_BLUE=$'\033[34m'
  _CLR_BOLD=$'\033[1m'
  _CLR_RESET=$'\033[0m'
else
  _CLR_RED=""; _CLR_GREEN=""; _CLR_YELLOW=""; _CLR_BLUE=""; _CLR_BOLD=""; _CLR_RESET=""
fi

# -----------------------------------------------------------------------------
# Logging helpers. All write to stderr so stdout stays clean for
# command output that's meant to be parsed by other tools.
# -----------------------------------------------------------------------------
log_info()  { echo "${_CLR_BLUE}[info]${_CLR_RESET} $*" >&2; }
log_warn()  { echo "${_CLR_YELLOW}[warn]${_CLR_RESET} $*" >&2; }
log_error() { echo "${_CLR_RED}[error]${_CLR_RESET} $*" >&2; }
log_step()  { echo "${_CLR_BOLD}${_CLR_GREEN}==>${_CLR_RESET} ${_CLR_BOLD}$*${_CLR_RESET}" >&2; }

# -----------------------------------------------------------------------------
# Error trap. Prints the failing command + line on nonzero exit so the
# user isn't left staring at a bare "exit 1".
# -----------------------------------------------------------------------------
_on_error() {
  local exit_code=$?
  local line=${1:-?}
  log_error "command failed at line ${line} with exit code ${exit_code}"
  exit "${exit_code}"
}
trap '_on_error $LINENO' ERR

# -----------------------------------------------------------------------------
# confirm "Prompt" — returns 0 if user answers yes, 1 otherwise.
# Treats anything other than y/Y/yes as no. In --yes mode (ASSUME_YES=1)
# always returns 0, for use in CI.
# -----------------------------------------------------------------------------
confirm() {
  local prompt="${1:-Proceed?}"
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    log_info "${prompt} [auto-yes]"
    return 0
  fi
  local reply
  read -rp "${prompt} [y/N] " reply </dev/tty
  [[ "${reply}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# -----------------------------------------------------------------------------
# require_cmd <name> — exits with a clear message if the command isn't on PATH.
# -----------------------------------------------------------------------------
require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "required command not found: ${cmd}"
    log_error "install it and re-run this script."
    exit 127
  fi
}

# -----------------------------------------------------------------------------
# run_cmd <args...> — run a command, or echo it if DRY_RUN is set. Use
# this for any side-effecting operation (gcloud create, docker push) so
# --dry-run is genuinely safe.
# -----------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-0}"
run_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${_CLR_YELLOW}[dry-run]${_CLR_RESET} $*" >&2
    return 0
  fi
  "$@"
}

# -----------------------------------------------------------------------------
# parse_common_flags — intended to be called at the top of every script
# with "$@". Shifts --help / -h / --dry-run out of the args list; leaves
# unknown args in place for the caller to parse further.
#
# Usage in caller:
#   new_args=()
#   parse_common_flags "$@"
#   set -- "${_REMAINING_ARGS[@]}"
# -----------------------------------------------------------------------------
_REMAINING_ARGS=()
parse_common_flags() {
  _REMAINING_ARGS=()
  while (($#)); do
    case "$1" in
      -h|--help)
        if declare -F print_help >/dev/null; then
          print_help
        else
          echo "No help text defined for this script." >&2
        fi
        exit 0
        ;;
      --dry-run)
        DRY_RUN=1
        log_info "DRY_RUN=1 — commands will be printed, not executed"
        ;;
      --yes|-y)
        ASSUME_YES=1
        ;;
      *)
        _REMAINING_ARGS+=("$1")
        ;;
    esac
    shift
  done
}

# -----------------------------------------------------------------------------
# resolve_repo_root — locate the repository root from the currently
# running script. Works whether the script was invoked by path,
# symlink, or via $PATH.
# -----------------------------------------------------------------------------
resolve_repo_root() {
  local self="${BASH_SOURCE[1]:-$0}"
  local script_dir
  script_dir="$(cd "$(dirname "${self}")" && pwd)"
  # From scripts/*.sh, the repo root is one level up.
  # From scripts/lib/*.sh, it's two levels up. We detect by looking for
  # the CLAUDE.md-style marker files.
  local dir="${script_dir}"
  for _ in 1 2 3; do
    if [[ -f "${dir}/LICENSE" && -d "${dir}/terraform" && -d "${dir}/scripts" ]]; then
      echo "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  log_error "could not locate repo root from ${script_dir}"
  return 1
}

# -----------------------------------------------------------------------------
# wait_for_sa <sa_email> — wait for IAM to propagate a newly created SA.
# GCP has eventual consistency between SA creation and IAM; without this
# pause, `add-iam-policy-binding` fails with INVALID_ARGUMENT.
# Only call this right after `gcloud iam service-accounts create`.
# -----------------------------------------------------------------------------
wait_for_sa() {
  local sa_email="$1"
  log_info "waiting for IAM propagation of ${sa_email}..."
  local i
  for i in 1 2 3; do
    if gcloud iam service-accounts describe "${sa_email}" \
         --format="value(email)" >/dev/null 2>&1; then
      sleep 5
      return 0
    fi
    sleep 5
  done
  log_warn "SA ${sa_email} not yet visible after 15s — proceeding anyway"
}

# -----------------------------------------------------------------------------
# grant_run_invoker <service> <project> <region> <principals_csv>
# Used by dev-portal, admin-dashboard, and other services that still use
# Cloud Run IAM for auth. The LLM and MCP gateways use
# --no-invoker-iam-check + app-level token_validation.py instead (so
# they do NOT call this function).
#
# GLB mode: tries allUsers first (ingress is the boundary). If an org policy
# blocks allUsers, falls back to per-principal bindings. The first failure is
# cached in a temp file so subsequent services skip the attempt silently.
# Standard mode: always per-principal.
# -----------------------------------------------------------------------------
grant_run_invoker() {
  local service="$1" project="$2" region="$3" principals="${4:-}"
  local _cache="/tmp/.claude-code-allusers-${project}"

  if [[ "${ENABLE_GLB:-false}" == "true" ]]; then
    log_step "grant Cloud Run invoker on ${service} (GLB mode)"

    if [[ ! -f "${_cache}" ]]; then
      if gcloud run services add-iam-policy-binding "${service}" \
           --project "${project}" --region "${region}" \
           --member="allUsers" --role="roles/run.invoker" --quiet 2>/dev/null; then
        return 0
      fi
      echo "blocked" > "${_cache}"
      log_info "org policy blocks allUsers — using per-principal Cloud Run auth"
    fi
  else
    [[ -z "${principals}" ]] && return 0
    log_step "grant roles/run.invoker to principals on ${service}"
  fi

  if [[ -z "${principals}" ]]; then
    log_warn "no principals configured; callers will need roles/run.invoker granted manually"
    return 0
  fi
  IFS=',' read -ra _principals <<<"${principals}"
  for p in "${_principals[@]}"; do
    p="${p## }"; p="${p%% }"
    [[ -z "${p}" ]] && continue
    run_cmd gcloud run services add-iam-policy-binding "${service}" \
      --project "${project}" --region "${region}" \
      --member="${p}" --role="roles/run.invoker" --quiet
  done
}

# -----------------------------------------------------------------------------
# resolve_glb_url <project_id> — print the best GLB URL to stdout.
# Priority: GLB_DOMAIN env var > claude-code-glb-ip static IP > return 1.
# Callers decide their own fallback (Cloud Run discovery, error, etc.).
# -----------------------------------------------------------------------------
resolve_glb_url() {
  local project_id="${1:?project_id required}"
  if [[ -n "${GLB_DOMAIN:-}" ]]; then
    echo "https://${GLB_DOMAIN}"
    return 0
  fi
  local ip
  ip="$(gcloud compute addresses describe claude-code-glb-ip --global \
    --project "${project_id}" --format="value(address)" 2>/dev/null || echo "")"
  if [[ -n "${ip}" ]]; then
    echo "https://${ip}"
    return 0
  fi
  return 1
}
