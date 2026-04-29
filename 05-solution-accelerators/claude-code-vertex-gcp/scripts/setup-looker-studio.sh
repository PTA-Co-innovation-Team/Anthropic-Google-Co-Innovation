#!/usr/bin/env bash
# =============================================================================
# setup-looker-studio.sh
#
# Generates Looker Studio Linking API URLs for the BigQuery views created
# by deploy-observability.sh. The primary URL creates a report with
# v_recent_requests; the remaining four views are added manually inside
# the report editor (Looker Studio only supports one data source per URL
# when creating a new report).
#
# Prerequisites:
#   * BigQuery views must exist (created by deploy-observability.sh or
#     Terraform with enable_looker_views=true).
#   * The user opening the URL must have bigquery.tables.getData on the
#     views (roles/bigquery.dataViewer on the dataset is sufficient).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

print_help() {
  cat <<'HELP'
Usage: setup-looker-studio.sh [--help] [--dry-run] [--project <id>]

Generates Looker Studio report URLs for the five BigQuery views. The
primary URL creates a report with v_recent_requests; add the remaining
views inside the editor (Resource > Manage added data sources).

Options:
  --project <id>    GCP project ID. Auto-detected if omitted.
  --dry-run         Print the URL without verifying views exist.
  --help            Show this help message.
HELP
}

parse_common_flags "$@"

# Parse --project flag
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Resolve project ID
if [[ -z "${PROJECT_ID:-}" ]]; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || echo "")"
fi
: "${PROJECT_ID:?PROJECT_ID must be set (pass --project or set gcloud default)}"

DATASET_ID="claude_code_logs"
VIEWS=(
  "v_requests_summary"
  "v_error_analysis"
  "v_latency_stats"
  "v_top_callers"
  "v_recent_requests"
)

# --- Verify views exist (unless --dry-run) ----------------------------------
if [[ "${DRY_RUN:-false}" != "true" ]]; then
  require_cmd gcloud
  log_step "verifying BigQuery views exist"
  _bq_token="$(gcloud auth print-access-token 2>/dev/null)"
  _missing=0
  for view in "${VIEWS[@]}"; do
    _code="$(curl -sS -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${_bq_token}" \
      "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/datasets/${DATASET_ID}/tables/${view}" 2>/dev/null)"
    if [[ "${_code}" == "200" ]]; then
      log_info "  ${view} — found"
    else
      log_warn "  ${view} — not found (HTTP ${_code})"
      _missing=$((_missing + 1))
    fi
  done

  if [[ "${_missing}" -gt 0 ]]; then
    log_error "${_missing} view(s) missing. Run deploy-observability.sh first (requires at least one gateway request for the raw log table to exist)."
    exit 1
  fi
fi

# --- Build Looker Studio report URLs ----------------------------------------
# The Linking API supports one data source per URL (indexed aliases like
# ds.ds0 only work when cloning an existing template report). We generate
# one URL per view so every view gets its own report, plus a primary URL
# using v_recent_requests (the most complete view) for a single all-in-one
# starting point. Additional data sources can be added inside the editor.
log_step "generating Looker Studio report URLs"

_looker_url() {
  local view="$1"
  echo "https://lookerstudio.google.com/reporting/create?c.mode=edit&ds.connector=bigQuery&ds.type=TABLE&ds.projectId=${PROJECT_ID}&ds.datasetId=${DATASET_ID}&ds.tableId=${view}"
}

PRIMARY_VIEW="v_recent_requests"
PRIMARY_URL="$(_looker_url "${PRIMARY_VIEW}")"

echo ""
log_info "Primary report URL (v_recent_requests — all request fields):"
echo ""
echo "  ${PRIMARY_URL}"
echo ""
log_info "Open this URL in your browser to create a Looker Studio report."
log_info "The report starts with v_recent_requests as the data source."
echo ""
log_info "To add the other views as additional data sources inside your report:"
log_info "  1. In the report editor, click Resource > Manage added data sources"
log_info "  2. Click Add a data source > BigQuery"
log_info "  3. Select project: ${PROJECT_ID} > dataset: ${DATASET_ID}"
log_info "  4. Add each view: v_requests_summary, v_error_analysis,"
log_info "     v_latency_stats, v_top_callers"
echo ""
log_info "Or create separate reports per view:"
for view in "${VIEWS[@]}"; do
  log_info "  ${view}:"
  log_info "    $(_looker_url "${view}")"
done
