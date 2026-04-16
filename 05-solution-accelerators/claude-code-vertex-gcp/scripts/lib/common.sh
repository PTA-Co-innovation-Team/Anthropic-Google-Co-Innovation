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
