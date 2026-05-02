#!/usr/bin/env bash
# =============================================================================
# INSTALL.sh — single-command wrapper for the gateway accelerator.
#
# Phase order:
#   1. preflight.sh          (read-only validation, no GCP writes)
#   2. scripts/deploy.sh     (real GCP resource creation, idempotent)
#   3. scripts/e2e-test.sh   (post-deploy smoke + sanity)
#
# If any phase fails, the wrapper prints the failing phase + the last 50
# lines of its log and exits non-zero so CI / partners can fail fast.
#
# Flags:
#   --dry-run   Run preflight, then run deploy with --dry-run; skip e2e.
#   --glb       Enable Global Load Balancer mode.
#   --yes       Pass through to interactive prompts (auto-yes).
#   --quick     Pass through to e2e-test.sh (5 smoke tests, <30s).
#
# Env (mirror config.yaml; deploy.sh also accepts these):
#   PROJECT_ID, REGION, FALLBACK_REGION, PRINCIPALS, GLB_DOMAIN,
#   IAP_SUPPORT_EMAIL
#
# Idempotent — re-runs are safe.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"

print_help() {
  cat <<'HELP'
Usage: ./INSTALL.sh [--dry-run] [--glb] [--yes] [--quick] [--help]

End-to-end installer:
  preflight (no writes) → deploy (idempotent) → smoke test

Flags:
  --dry-run   Validate + deploy with --dry-run (no resources created).
  --glb       Enable Global Load Balancer (~$18/month). Default: standard mode.
  --yes       Auto-answer "yes" at every prompt.
  --quick     Run e2e in --quick mode (5 smoke checks, <30s).
  --help      This help.

Reads PROJECT_ID, REGION, PRINCIPALS, etc. from environment if set,
otherwise prompts via deploy.sh.

Logs from each phase are written to /tmp/install-<phase>-<ts>.log.
HELP
}

DRY_RUN_FLAG=""
GLB_FLAG=""
YES_FLAG=""
QUICK_FLAG=""

while (($#)); do
  case "${1:-}" in
    -h|--help) print_help; exit 0 ;;
    --dry-run) DRY_RUN_FLAG="--dry-run"; shift ;;
    --glb)     GLB_FLAG="1"; shift ;;
    --yes|-y)  YES_FLAG="--yes"; shift ;;
    --quick)   QUICK_FLAG="--quick"; shift ;;
    *) log_warn "unknown flag: $1"; shift ;;
  esac
done

if [[ -n "${GLB_FLAG}" ]]; then
  export ENABLE_GLB=true
fi

TS="$(date -u +%Y%m%d-%H%M%S)"
LOG_DIR="/tmp"

run_phase() {
  local phase_name="$1"; shift
  local log_file="${LOG_DIR}/install-${phase_name}-${TS}.log"

  log_step "Phase: ${phase_name}"
  log_info "log: ${log_file}"

  # Tee through so the user sees output AND we keep a log.
  if "$@" 2>&1 | tee "${log_file}"; then
    return 0
  fi
  local rc="${PIPESTATUS[0]}"
  log_error "phase '${phase_name}' failed (exit ${rc})"
  log_error "last 50 lines of ${log_file}:"
  echo "----------------------------------------" >&2
  tail -50 "${log_file}" >&2
  echo "----------------------------------------" >&2
  return "${rc}"
}

# -----------------------------------------------------------------------------
# Phase 1 — preflight (read-only)
# -----------------------------------------------------------------------------
PREFLIGHT_ARGS=()
if [[ -n "${GLB_FLAG}" ]]; then
  PREFLIGHT_ARGS+=("--enable-glb")
  [[ -n "${GLB_DOMAIN:-}" ]] && PREFLIGHT_ARGS+=("--glb-domain" "${GLB_DOMAIN}")
fi
[[ -n "${PROJECT_ID:-}" ]] && PREFLIGHT_ARGS+=("--project" "${PROJECT_ID}")
[[ -n "${REGION:-}" ]] && PREFLIGHT_ARGS+=("--region" "${REGION}")
[[ -n "${PRINCIPALS:-}" ]] && PREFLIGHT_ARGS+=("--principals" "${PRINCIPALS}")

if ! run_phase "preflight" bash "${SCRIPT_DIR}/scripts/preflight.sh" "${PREFLIGHT_ARGS[@]}"; then
  log_error "preflight blocked deploy. Address the failures above and re-run."
  exit 1
fi

# -----------------------------------------------------------------------------
# Phase 2 — deploy
# -----------------------------------------------------------------------------
DEPLOY_ARGS=()
[[ -n "${DRY_RUN_FLAG}" ]] && DEPLOY_ARGS+=("${DRY_RUN_FLAG}")
[[ -n "${YES_FLAG}" ]] && DEPLOY_ARGS+=("${YES_FLAG}")

if ! run_phase "deploy" bash "${SCRIPT_DIR}/scripts/deploy.sh" "${DEPLOY_ARGS[@]}"; then
  log_error "deploy phase failed. Re-run is safe (idempotent); fix root cause then retry."
  exit 1
fi

# -----------------------------------------------------------------------------
# Phase 3 — e2e smoke (skip on --dry-run)
# -----------------------------------------------------------------------------
if [[ -n "${DRY_RUN_FLAG}" ]]; then
  log_info "skipping e2e (--dry-run mode)"
else
  E2E_ARGS=()
  [[ -n "${QUICK_FLAG}" ]] && E2E_ARGS+=("${QUICK_FLAG}")
  # default to --quick if user did not specify, to keep INSTALL fast.
  if (( ${#E2E_ARGS[@]} == 0 )); then
    E2E_ARGS+=("--quick")
  fi
  [[ -n "${PROJECT_ID:-}" ]] && E2E_ARGS+=("--project" "${PROJECT_ID}")
  [[ -n "${REGION:-}" ]] && E2E_ARGS+=("--region" "${REGION}")

  if ! run_phase "e2e" bash "${SCRIPT_DIR}/scripts/e2e-test.sh" "${E2E_ARGS[@]}"; then
    log_warn "e2e checks failed (deploy succeeded). Inspect log and re-run e2e separately."
    log_warn "  bash scripts/e2e-test.sh"
    exit 2
  fi
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
log_step "INSTALL succeeded"
echo "" >&2

if [[ -z "${DRY_RUN_FLAG}" ]]; then
  log_info "next step (run on each developer's laptop):"
  echo "    bash scripts/developer-setup.sh" >&2
  echo "" >&2
  log_info "to populate the admin dashboard with realistic-looking traffic:"
  echo "    bash scripts/seed-demo-data.sh --users 5 --requests-per-user 10" >&2
  echo "" >&2
  log_info "to tear everything down:"
  echo "    bash scripts/teardown.sh" >&2
fi
