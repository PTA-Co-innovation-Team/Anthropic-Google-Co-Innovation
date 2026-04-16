#!/usr/bin/env bash
# =============================================================================
# seed-demo-data.sh — populate the observability dashboard with traffic.
#
# Why this exists: after a fresh deployment the Looker Studio dashboard
# is empty. Empty charts make for a terrible demo. This script issues a
# controlled volume of realistic-looking Claude Haiku requests through
# the gateway so the dashboard has data to show.
#
# IMPORTANT — attribution caveat:
#   Every request is authenticated with YOUR Google identity (the one
#   running this script). It is not possible to forge other principals
#   from a client. So all entries in the "top callers" panel will be
#   you. If you need multi-user-looking data for a demo, run this
#   script from multiple accounts / service accounts in sequence.
#
# Cost safety:
#   * Hardcoded Haiku model, max 8 output tokens per request.
#   * Hard cap of 200 total requests (override with --i-know-what-im-doing).
#   * Confirmation prompt when total > 50.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# -----------------------------------------------------------------------------
# Flags
# -----------------------------------------------------------------------------
GATEWAY_URL=""
USERS=5
PER_USER=10
DURATION_MIN=30
PROJECT_ID=""
REGION="global"
CR_REGION="us-central1"
OVERRIDE_CAP=0
HARD_CAP=200

print_help() {
  cat <<'HELP'
Usage: seed-demo-data.sh [options]

Populates the deployment's Cloud Logging / BigQuery sink with enough
realistic-looking Haiku traffic to make the Looker Studio dashboard
interesting. All requests are billed to YOUR project and attributed
to YOUR Google identity.

Options:
  --gateway-url <url>        LLM gateway URL. Auto-discovered if omitted.
  --project <id>             GCP project ID. Defaults to gcloud config.
  --region <region>          Vertex region. Default "global".
  --cr-region <region>       Cloud Run region for URL discovery. Default us-central1.
  --users <n>                Number of simulated users. Default 5.
  --requests-per-user <n>    Requests per simulated user. Default 10.
  --duration-minutes <n>     Spread the traffic over N minutes. Default 30.
  --i-know-what-im-doing     Lift the 200-request hard cap.
  -h, --help                 Show this help.

Model: claude-haiku-4-5@20251001 (cheapest, ~$0.0001 per request).

Example:
  ./seed-demo-data.sh --users 5 --requests-per-user 10 --duration-minutes 15
HELP
}

_ARGS=()
while (($#)); do
  case "$1" in
    --gateway-url) GATEWAY_URL="$2"; shift 2 ;;
    --project) PROJECT_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --cr-region) CR_REGION="$2"; shift 2 ;;
    --users) USERS="$2"; shift 2 ;;
    --requests-per-user) PER_USER="$2"; shift 2 ;;
    --duration-minutes) DURATION_MIN="$2"; shift 2 ;;
    --i-know-what-im-doing) OVERRIDE_CAP=1; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) _ARGS+=("$1"); shift ;;
  esac
done
set -- "${_ARGS[@]:-}"

# -----------------------------------------------------------------------------
# Resolve
# -----------------------------------------------------------------------------
require_cmd gcloud
require_cmd curl

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
: "${PROJECT_ID:?--project required}"

if [[ -z "${GATEWAY_URL}" ]]; then
  GATEWAY_URL=$(gcloud run services describe llm-gateway \
                  --project "${PROJECT_ID}" --region "${CR_REGION}" \
                  --format="value(status.url)" 2>/dev/null || true)
fi
[[ -n "${GATEWAY_URL}" ]] || { log_error "could not discover gateway URL — pass --gateway-url"; exit 1; }

# -----------------------------------------------------------------------------
# Budget check
# -----------------------------------------------------------------------------
TOTAL=$((USERS * PER_USER))
if (( TOTAL > HARD_CAP )) && (( OVERRIDE_CAP == 0 )); then
  log_error "requested ${TOTAL} requests exceeds safety cap of ${HARD_CAP}."
  log_error "re-run with --i-know-what-im-doing to override."
  exit 1
fi

# Rough cost estimate. Haiku list price is ~$0.80/M input + ~$4/M output;
# our prompts are ~30 input tokens and max 8 output tokens, so each
# request is under $0.001. We use $0.0001 as a conservative display
# figure with a disclaimer.
COST_DISPLAY=$(awk "BEGIN {printf \"\$%.4f\", ${TOTAL} * 0.0001}")

log_info "project:      ${PROJECT_ID}"
log_info "gateway URL:  ${GATEWAY_URL}"
log_info "model:        claude-haiku-4-5@20251001"
log_info "users:        ${USERS}"
log_info "per user:     ${PER_USER}"
log_info "total reqs:   ${TOTAL}"
log_info "spread over:  ${DURATION_MIN} min"
log_info "cost (est):   ${COST_DISPLAY} (disclaimer: rough; see COSTS.md)"

if (( TOTAL > 50 )); then
  if ! confirm "Send ${TOTAL} requests now?"; then
    log_info "aborted."
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# Prompt corpus — realistic developer asks, Haiku-sized.
# -----------------------------------------------------------------------------
PROMPTS=(
  "Refactor this function to remove the nested try/except."
  "Explain what this regex matches: ^\\d{3}-\\d{2}-\\d{4}\$"
  "Write a unit test for a function that parses ISO-8601 dates."
  "Is this SQL vulnerable to injection? SELECT * FROM u WHERE id='\$id'"
  "What's the difference between asyncio.gather and asyncio.wait?"
  "Add type hints to this Python function signature."
  "Why would os.path.join behave differently on Windows vs Linux?"
  "Suggest a name for a function that retries HTTP GETs with backoff."
  "What does the Rust borrow checker enforce, in one sentence?"
  "Summarize the difference between a generator and an iterator."
  "Write a single-line shell command to count unique lines in a file."
  "Explain the purpose of a Python context manager."
  "Translate this JavaScript Promise chain into async/await."
  "Is JSON Schema 'type': ['string', 'null'] equivalent to nullable?"
  "Give one reason to prefer composition over inheritance."
  "What is tail-call optimization and why does CPython not do it?"
  "Draft a Git commit message for 'fix off-by-one in pagination loop'."
  "What's wrong with using strcpy in C in 2025?"
  "Explain what a sentinel value is, with one example."
  "Write a minimal Dockerfile for a static-site Python server."
)

# -----------------------------------------------------------------------------
# Request loop
# -----------------------------------------------------------------------------
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null)
[[ -n "${TOKEN}" ]] || { log_error "no ADC token. Run: gcloud auth application-default login"; exit 1; }

# Compute per-request sleep. Avoid dividing by zero.
if (( TOTAL > 1 && DURATION_MIN > 0 )); then
  # Total seconds / (total requests - 1). Float via awk.
  SLEEP_PER=$(awk "BEGIN {printf \"%.2f\", (${DURATION_MIN} * 60.0) / (${TOTAL} - 1)}")
else
  SLEEP_PER=0
fi
log_info "pacing: ${SLEEP_PER}s between requests"

PATH_URL="/v1/projects/${PROJECT_ID}/locations/${REGION}/publishers/anthropic/models/claude-haiku-4-5@20251001:rawPredict"
SENT=0
FAIL=0
START_EPOCH=$(date +%s)

log_step "sending ${TOTAL} requests"
for ((u=1; u<=USERS; u++)); do
  for ((r=1; r<=PER_USER; r++)); do
    prompt="${PROMPTS[$(( (SENT) % ${#PROMPTS[@]} ))]}"
    # JSON-escape naively: we know the prompts have no double quotes
    # or backslashes that would break the payload. Hand-curated above.
    body=$(cat <<JSON
{
  "anthropic_version": "vertex-2023-10-16",
  "messages": [{"role":"user","content":"${prompt}"}],
  "max_tokens": 8
}
JSON
)
    status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${GATEWAY_URL%/}${PATH_URL}" \
              -H "Authorization: Bearer ${TOKEN}" \
              -H "Content-Type: application/json" \
              -d "${body}" || echo "000")
    SENT=$((SENT + 1))
    if [[ "${status}" != "200" ]]; then
      FAIL=$((FAIL + 1))
      log_warn "req ${SENT}/${TOTAL} status=${status}"
    fi
    # Progress line every 10 requests (or every request if small).
    if (( SENT % 10 == 0 )) || (( TOTAL <= 20 )); then
      elapsed=$(( $(date +%s) - START_EPOCH ))
      log_info "sent ${SENT}/${TOTAL}  fails=${FAIL}  elapsed=${elapsed}s"
    fi
    # Pace. If SLEEP_PER is small (< 0.05), skip the sleep entirely.
    if (( SENT < TOTAL )); then
      awk "BEGIN { exit (${SLEEP_PER} < 0.05) ? 0 : 1 }" || sleep "${SLEEP_PER}"
    fi
  done
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
elapsed=$(( $(date +%s) - START_EPOCH ))
log_step "done"
log_info "requests sent:     ${SENT}"
log_info "failures:          ${FAIL}"
log_info "elapsed:           ${elapsed}s"
log_info "approximate cost:  ${COST_DISPLAY}  (disclaimer: rough estimate)"
log_info ""
log_info "Give Cloud Logging ~1 min to flush, then open your Looker Studio"
log_info "dashboard — the 'Requests per day' panel should now be populated."
