#!/usr/bin/env bash
# =============================================================================
# verify-dashboard-traffic.sh — end-to-end observability pipeline verification.
#
# Sends 100 Haiku inference requests through the LLM gateway, then traces
# them through every layer of the observability pipeline:
#
#   LLM Gateway → Cloud Logging → BigQuery → Dashboard API → Dashboard HTML
#
# Self-contained: works on a fresh deployment with zero prior traffic.
# Estimated cost: ~$0.05 (100 Haiku requests, max 70 output tokens each).
#
# Usage:
#   ./scripts/verify-dashboard-traffic.sh [options]
#
# Options:
#   --project <id>           GCP project ID (default: gcloud config)
#   --gateway-url <url>      LLM gateway URL (auto-discovered if omitted)
#   --dashboard-url <url>    Admin dashboard URL (auto-discovered if omitted)
#   --cr-region <region>     Cloud Run region for discovery (default: us-central1)
#   --region <region>        Vertex region (default: global)
#   -h, --help               Show this help
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# -----------------------------------------------------------------------------
# Flags
# -----------------------------------------------------------------------------
PROJECT_ID=""
GATEWAY_URL=""
DASHBOARD_URL=""
CR_REGION="us-central1"
REGION="global"

print_help() {
  cat <<'HELP'
Usage: verify-dashboard-traffic.sh [options]

Sends 100 Haiku inference requests through the LLM gateway, then verifies
they appear in Cloud Logging, BigQuery, and the admin dashboard.

Options:
  --project <id>           GCP project ID (default: gcloud config)
  --gateway-url <url>      LLM gateway URL (auto-discovered if omitted)
  --dashboard-url <url>    Admin dashboard URL (auto-discovered if omitted)
  --cr-region <region>     Cloud Run region for discovery (default: us-central1)
  --region <region>        Vertex region (default: global)
  -h, --help               Show this help

Estimated cost: ~$0.05 (100 Haiku requests, max 70 output tokens each).
HELP
}

_ARGS=()
while (($#)); do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2 ;;
    --gateway-url) GATEWAY_URL="$2"; shift 2 ;;
    --dashboard-url) DASHBOARD_URL="$2"; shift 2 ;;
    --cr-region) CR_REGION="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    -h|--help) print_help; exit 0 ;;
    *) _ARGS+=("$1"); shift ;;
  esac
done
set -- "${_ARGS[@]:-}"

require_cmd gcloud
require_cmd curl
require_cmd python3

# -----------------------------------------------------------------------------
# Test tracking (matches e2e-test.sh pattern)
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
          echo "${_CLR_GREEN}  PASS${_CLR_RESET}  ${name}" >&2
          [[ -n "${detail}" ]] && echo "        ${detail}" >&2 ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)); LAYER_FAIL[$CURRENT_LAYER]=$(( ${LAYER_FAIL[$CURRENT_LAYER]:-0} + 1 ))
          echo "${_CLR_RED}  FAIL${_CLR_RESET}  ${name}" >&2
          [[ -n "${detail}" ]] && echo "        ${detail}" >&2 ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)); LAYER_SKIP[$CURRENT_LAYER]=$(( ${LAYER_SKIP[$CURRENT_LAYER]:-0} + 1 ))
          echo "${_CLR_YELLOW}  SKIP${_CLR_RESET}  ${name}" >&2
          [[ -n "${detail}" ]] && echo "        ${detail}" >&2 ;;
  esac
}

run_test() {
  local name="$1"; shift
  local func="$1"; shift
  local detail=""
  set +e
  detail="$("$func" "$@" 2>&1)"
  local rc=$?
  set -e
  case $rc in
    0) _record PASS "$name" "${detail}" ;;
    2) _record SKIP "$name" "${detail}" ;;
    *) _record FAIL "$name" "${detail}" ;;
  esac
}

_get_token() {
  local audience="${1:-}"
  if [[ -n "${audience}" ]]; then
    gcloud auth print-identity-token --audiences="${audience}" 2>/dev/null \
      || gcloud auth application-default print-access-token 2>/dev/null
  else
    gcloud auth application-default print-access-token 2>/dev/null
  fi
}

# -----------------------------------------------------------------------------
# Resolve project and service URLs
# -----------------------------------------------------------------------------
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
: "${PROJECT_ID:?--project required}"

if [[ -z "${GATEWAY_URL}" ]]; then
  GATEWAY_URL="$(resolve_glb_url "${PROJECT_ID}" 2>/dev/null || echo "")"
  if [[ -z "${GATEWAY_URL}" ]]; then
    for _try in "${CR_REGION}" us-central1 us-east5 europe-west1; do
      GATEWAY_URL="$(gcloud run services describe llm-gateway \
                       --project "${PROJECT_ID}" --region "${_try}" \
                       --format="value(status.url)" 2>/dev/null || echo "")"
      [[ -n "${GATEWAY_URL}" ]] && { CR_REGION="${_try}"; break; }
    done
  fi
fi
[[ -n "${GATEWAY_URL}" ]] || { log_error "could not discover gateway URL — pass --gateway-url"; exit 1; }

if [[ -z "${DASHBOARD_URL}" ]]; then
  for _try in "${CR_REGION}" us-central1 us-east5 europe-west1; do
    DASHBOARD_URL="$(gcloud run services describe admin-dashboard \
                       --project "${PROJECT_ID}" --region "${_try}" \
                       --format="value(status.url)" 2>/dev/null || echo "")"
    [[ -n "${DASHBOARD_URL}" ]] && break
  done
fi

CURL_K=""
if [[ "${GATEWAY_URL}" =~ ^https://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  CURL_K="-k"
fi

log_info "project:       ${PROJECT_ID}"
log_info "gateway URL:   ${GATEWAY_URL}"
log_info "dashboard URL: ${DASHBOARD_URL:-not found}"
log_info "region:        ${REGION}"
log_info "CR region:     ${CR_REGION}"
echo "" >&2

# =============================================================================
# PHASE 0: Pre-flight Infrastructure Checks
# =============================================================================
CURRENT_LAYER="Phase 0: Infrastructure"
log_step "${CURRENT_LAYER}"

test_0_1_discover_urls() {
  [[ -n "${GATEWAY_URL}" ]] || { echo "gateway URL is empty"; return 1; }
  echo "gateway=${GATEWAY_URL}"
}
run_test "0.1 Gateway URL discovered" test_0_1_discover_urls

test_0_2_gateway_reachable() {
  local status
  # Try /healthz first (newer images), fall back to /health.
  status=$(curl -sS ${CURL_K} -o /dev/null -w '%{http_code}' --connect-timeout 5 \
            "${GATEWAY_URL%/}/healthz" 2>/dev/null || echo "000")
  if [[ "${status}" == "404" ]]; then
    status=$(curl -sS ${CURL_K} -o /dev/null -w '%{http_code}' --connect-timeout 5 \
              "${GATEWAY_URL%/}/health" 2>/dev/null || echo "000")
  fi
  if [[ "${status}" == "000" ]]; then
    echo "gateway unreachable — if VPC-internal, SSH via IAP:"
    echo "  gcloud compute ssh claude-code-dev-shared --tunnel-through-iap --project=${PROJECT_ID} --zone=${CR_REGION}-a"
    return 1
  fi
  [[ "${status}" == "200" ]] || { echo "gateway health returned ${status}"; return 1; }
}
run_test "0.2 Gateway reachable (/healthz)" test_0_2_gateway_reachable

# If gateway failed, abort — all subsequent phases need it
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  log_error "gateway unreachable — cannot proceed with traffic tests"
  log_error "if using VPC-internal ingress, SSH into the dev VM via IAP and run from there:"
  log_error "  gcloud compute ssh claude-code-dev-shared --tunnel-through-iap --project=${PROJECT_ID} --zone=${CR_REGION}-a"
  exit 1
fi

test_0_3_dashboard_reachable() {
  [[ -n "${DASHBOARD_URL}" ]] || { echo "dashboard URL not discovered — was observability deployed?"; return 2; }
  local token status
  token="$(_get_token "${DASHBOARD_URL}")"
  status=$(curl -sS ${CURL_K} -o /dev/null -w '%{http_code}' --connect-timeout 10 \
            -H "Authorization: Bearer ${token}" \
            "${DASHBOARD_URL%/}/health" 2>/dev/null || echo "000")
  [[ "${status}" == "200" ]] || { echo "dashboard /health returned ${status}"; return 1; }
}
run_test "0.3 Dashboard reachable (/health)" test_0_3_dashboard_reachable

test_0_4_bigquery_dataset() {
  local token status
  token="$(gcloud auth application-default print-access-token 2>/dev/null)"
  status=$(curl -sS -o /dev/null -w "%{http_code}" \
            -H "Authorization: Bearer ${token}" \
            "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/datasets/claude_code_logs" 2>/dev/null)
  [[ "${status}" == "200" ]] || { echo "BigQuery dataset claude_code_logs not found (${status})"; return 1; }
}
run_test "0.4 BigQuery dataset exists" test_0_4_bigquery_dataset

test_0_5_logging_sink() {
  local dest
  dest="$(gcloud logging sinks describe claude-code-gateway-logs \
            --project "${PROJECT_ID}" \
            --format="value(destination)" 2>/dev/null || echo "")"
  [[ -n "${dest}" ]] || { echo "logging sink claude-code-gateway-logs not found"; return 1; }
  [[ "${dest}" == *"claude_code_logs"* ]] || { echo "sink destination unexpected: ${dest}"; return 1; }
}
run_test "0.5 Logging sink exists" test_0_5_logging_sink

TABLE_NAME=""
test_0_6_bigquery_table() {
  local token result
  token="$(gcloud auth application-default print-access-token 2>/dev/null)"
  result=$(curl -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -X POST "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/queries" \
    -d "{\"query\": \"SELECT table_name FROM \`${PROJECT_ID}.claude_code_logs.INFORMATION_SCHEMA.TABLES\` WHERE table_name LIKE 'run_googleapis_com_%' ORDER BY table_name LIMIT 5\", \"useLegacySql\": false}" 2>/dev/null)

  TABLE_NAME=$(echo "${result}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = data.get('rows', [])
for r in rows:
    name = r['f'][0]['v']
    if 'stdout' in name:
        print(name)
        sys.exit(0)
if rows:
    print(rows[0]['f'][0]['v'])
else:
    print('')
" 2>/dev/null)

  if [[ -n "${TABLE_NAME}" ]]; then
    echo "table=${TABLE_NAME}"
  else
    echo "no BigQuery log table yet — Phase 1 traffic will create it"
    return 2
  fi
}
run_test "0.6 BigQuery table discovery" test_0_6_bigquery_table

echo "" >&2

# =============================================================================
# PHASE 1: Send 100 Inference Requests
# =============================================================================
CURRENT_LAYER="Phase 1: Send Requests"
log_step "${CURRENT_LAYER}"

PROMPTS=(
  "Refactor this function to remove the nested try/except."
  "Explain what this regex matches: ^[0-9]{3}-[0-9]{2}-[0-9]{4}$"
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

TOTAL_REQUESTS=100

test_1_send_requests() {
  local token sent=0 fail=0 status body
  token="$(_get_token "${GATEWAY_URL}")"
  [[ -n "${token}" ]] || { echo "no credentials — run: gcloud auth application-default login"; return 1; }

  local path_url="/v1/projects/${PROJECT_ID}/locations/${REGION}/publishers/anthropic/models/claude-haiku-4-5@20251001:rawPredict"

  for ((i=0; i<TOTAL_REQUESTS; i++)); do
    local prompt="${PROMPTS[$((i % ${#PROMPTS[@]}))]}"
    body=$(python3 -c 'import json,sys; print(json.dumps({"anthropic_version":"vertex-2023-10-16","messages":[{"role":"user","content":sys.argv[1]}],"max_tokens":70}))' "${prompt}")

    status=$(curl -sS ${CURL_K} -o /dev/null -w "%{http_code}" \
              -X POST "${GATEWAY_URL%/}${path_url}" \
              -H "Authorization: Bearer ${token}" \
              -H "Content-Type: application/json" \
              -d "${body}" || echo "000")

    sent=$((sent + 1))
    [[ "${status}" != "200" ]] && fail=$((fail + 1))

    if (( sent % 10 == 0 )); then
      echo "${_CLR_BLUE}[info]${_CLR_RESET} sent ${sent}/${TOTAL_REQUESTS}  fails=${fail}" >/dev/tty 2>/dev/null || true
    fi
  done

  echo "sent=${sent} fails=${fail}"
  if (( fail > 5 )); then
    echo "too many failures (${fail}/${sent}) — check ALLOWED_PRINCIPALS, ADC, or Vertex model enablement"
    return 1
  fi
}
run_test "1.1 Send ${TOTAL_REQUESTS} Haiku requests (max_tokens=70)" test_1_send_requests

SEND_EPOCH=$(date +%s)
echo "" >&2

# =============================================================================
# PHASE 2: Cloud Logging Verification
# =============================================================================
CURRENT_LAYER="Phase 2: Cloud Logging"
log_step "${CURRENT_LAYER}"
log_info "waiting 60s for Cloud Logging ingestion..."
sleep 60

test_2_1_logs_exist() {
  local logs count
  logs=$(gcloud logging read \
    'resource.type="cloud_run_revision" resource.labels.service_name="llm-gateway" jsonPayload.message="proxy_request" jsonPayload.model="claude-haiku-4-5@20251001"' \
    --project "${PROJECT_ID}" \
    --freshness=10m \
    --limit=100 \
    --format=json 2>/dev/null)

  count=$(echo "${logs}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  echo "proxy_request entries found: ${count}"
  (( count >= 50 )) || { echo "expected >= 50 entries, got ${count} — logs may still be ingesting"; return 1; }
}
run_test "2.1 Cloud Logging has proxy_request entries" test_2_1_logs_exist

test_2_2_log_fields_valid() {
  local logs
  logs=$(gcloud logging read \
    'resource.type="cloud_run_revision" resource.labels.service_name="llm-gateway" jsonPayload.message="proxy_request"' \
    --project "${PROJECT_ID}" \
    --freshness=10m \
    --limit=5 \
    --format=json 2>/dev/null)

  echo "${logs}" | python3 -c "
import json, sys
logs = json.load(sys.stdin)
if not logs:
    print('no log entries found')
    sys.exit(1)
entry = logs[0]
jp = entry.get('jsonPayload', {})
required = ['caller', 'model', 'status_code', 'latency_ms_to_headers', 'method', 'path', 'vertex_region']
missing = [f for f in required if f not in jp]
if missing:
    print(f'missing fields: {missing}')
    sys.exit(1)
print(f'caller={jp[\"caller\"]} model={jp[\"model\"]} status={jp[\"status_code\"]} latency={jp[\"latency_ms_to_headers\"]}ms')
"
}
run_test "2.2 Structured log fields present" test_2_2_log_fields_valid

echo "" >&2

# =============================================================================
# PHASE 3: BigQuery Verification
# =============================================================================
CURRENT_LAYER="Phase 3: BigQuery"
log_step "${CURRENT_LAYER}"
log_info "waiting 90s for BigQuery sink flush..."
sleep 90

# Re-discover table if it wasn't found in Phase 0 (fresh deploy creates it after first log)
if [[ -z "${TABLE_NAME}" ]]; then
  log_info "re-discovering BigQuery table..."
  local_token="$(gcloud auth application-default print-access-token 2>/dev/null)"
  TABLE_NAME=$(curl -sS \
    -H "Authorization: Bearer ${local_token}" \
    -H "Content-Type: application/json" \
    -X POST "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/queries" \
    -d "{\"query\": \"SELECT table_name FROM \`${PROJECT_ID}.claude_code_logs.INFORMATION_SCHEMA.TABLES\` WHERE table_name LIKE 'run_googleapis_com_%' ORDER BY table_name LIMIT 5\", \"useLegacySql\": false}" 2>/dev/null \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = data.get('rows', [])
for r in rows:
    name = r['f'][0]['v']
    if 'stdout' in name:
        print(name); sys.exit(0)
if rows: print(rows[0]['f'][0]['v'])
else: print('')
" 2>/dev/null)
  if [[ -n "${TABLE_NAME}" ]]; then
    log_info "discovered table: ${TABLE_NAME}"
  fi
fi

test_3_1_bq_rows_exist() {
  [[ -n "${TABLE_NAME}" ]] || { echo "no BigQuery table found — sink may not have flushed yet"; return 1; }
  local token result row_count
  token="$(gcloud auth application-default print-access-token 2>/dev/null)"

  local query="SELECT jsonPayload.model AS model, jsonPayload.caller AS caller, CAST(jsonPayload.status_code AS INT64) AS status_code FROM \`${PROJECT_ID}.claude_code_logs.${TABLE_NAME}\` WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 MINUTE) AND jsonPayload.message = 'proxy_request' AND jsonPayload.model = 'claude-haiku-4-5@20251001' ORDER BY timestamp DESC LIMIT 100"

  result=$(curl -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -X POST "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/queries" \
    -d "{\"query\": $(python3 -c "import json; print(json.dumps('''${query}'''))"), \"useLegacySql\": false}" 2>/dev/null)

  row_count=$(echo "${result}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = data.get('rows', [])
print(len(rows))
" 2>/dev/null || echo "0")

  echo "BigQuery rows (haiku, last 15min): ${row_count}"
  (( row_count >= 50 )) || { echo "expected >= 50 rows, got ${row_count}"; return 1; }
}
run_test "3.1 BigQuery has proxy_request rows" test_3_1_bq_rows_exist

test_3_2_bq_aggregation() {
  [[ -n "${TABLE_NAME}" ]] || { echo "no table"; return 2; }
  local token result
  token="$(gcloud auth application-default print-access-token 2>/dev/null)"

  local query="SELECT FORMAT_DATE('%Y-%m-%d', DATE(timestamp)) AS date, COUNT(*) AS count FROM \`${PROJECT_ID}.claude_code_logs.${TABLE_NAME}\` WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY) AND jsonPayload.model IS NOT NULL GROUP BY date ORDER BY date"

  result=$(curl -sS \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -X POST "https://bigquery.googleapis.com/bigquery/v2/projects/${PROJECT_ID}/queries" \
    -d "{\"query\": $(python3 -c "import json; print(json.dumps('''${query}'''))"), \"useLegacySql\": false}" 2>/dev/null)

  echo "${result}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = data.get('rows', [])
if not rows:
    print('no aggregation rows')
    sys.exit(1)
total = 0
for r in rows:
    date_val = r['f'][0]['v']
    count_val = int(r['f'][1]['v'])
    total += count_val
    print(f'{date_val}: {count_val} requests')
if total < 50:
    print(f'total={total}, expected >= 50')
    sys.exit(1)
print(f'total={total}')
"
}
run_test "3.2 BigQuery aggregation (requests-per-day pattern)" test_3_2_bq_aggregation

echo "" >&2

# =============================================================================
# PHASE 4: Dashboard API Verification
# =============================================================================
CURRENT_LAYER="Phase 4: Dashboard API"
log_step "${CURRENT_LAYER}"

if [[ -z "${DASHBOARD_URL}" ]]; then
  log_warn "dashboard URL not found — skipping Phase 4"
  for t in "4.1" "4.2" "4.3" "4.4" "4.5" "4.6"; do
    _record SKIP "${t}" "no dashboard URL"
  done
else
  log_info "waiting 35s for dashboard query cache to expire..."
  sleep 35

  DASH_TOKEN="$(_get_token "${DASHBOARD_URL}")"

  test_4_1_recent_requests() {
    local resp
    resp=$(curl -sS ${CURL_K} \
      -H "Authorization: Bearer ${DASH_TOKEN}" \
      "${DASHBOARD_URL%/}/api/recent-requests?limit=20" 2>/dev/null)

    echo "${resp}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = data.get('data', [])
if not rows:
    note = data.get('note', '')
    print(f'empty data. note: {note}')
    sys.exit(1)
haiku = [r for r in rows if 'haiku' in str(r.get('model', ''))]
print(f'{len(rows)} entries, {len(haiku)} haiku')
if not haiku:
    print('no haiku entries visible yet')
    sys.exit(1)
latest = haiku[0]
print(f'latest: ts={latest.get(\"timestamp\")} model={latest.get(\"model\")} status={latest.get(\"status_code\")} latency={latest.get(\"latency_ms\")}ms')
"
  }
  run_test "4.1 /api/recent-requests" test_4_1_recent_requests

  test_4_2_requests_per_day() {
    local resp
    resp=$(curl -sS ${CURL_K} \
      -H "Authorization: Bearer ${DASH_TOKEN}" \
      "${DASHBOARD_URL%/}/api/requests-per-day?days=1" 2>/dev/null)

    echo "${resp}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = data.get('data', [])
if not rows:
    print('empty data')
    sys.exit(1)
total = sum(r.get('count', 0) for r in rows)
print(f'requests today: {total}')
if total < 1:
    sys.exit(1)
"
  }
  run_test "4.2 /api/requests-per-day" test_4_2_requests_per_day

  test_4_3_requests_by_model() {
    local resp
    resp=$(curl -sS ${CURL_K} \
      -H "Authorization: Bearer ${DASH_TOKEN}" \
      "${DASHBOARD_URL%/}/api/requests-by-model?days=1" 2>/dev/null)

    echo "${resp}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = data.get('data', [])
if not rows:
    print('empty data')
    sys.exit(1)
models = {r.get('model'): r.get('count') for r in rows}
haiku = [k for k in models if 'haiku' in str(k)]
if not haiku:
    print(f'no haiku in models: {list(models.keys())}')
    sys.exit(1)
print(f'haiku count: {models[haiku[0]]}')
"
  }
  run_test "4.3 /api/requests-by-model" test_4_3_requests_by_model

  test_4_4_top_callers() {
    local resp
    resp=$(curl -sS ${CURL_K} \
      -H "Authorization: Bearer ${DASH_TOKEN}" \
      "${DASHBOARD_URL%/}/api/top-callers?days=1&limit=10" 2>/dev/null)

    echo "${resp}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = data.get('data', [])
if not rows:
    print('empty data')
    sys.exit(1)
for r in rows:
    print(f'{r.get(\"caller\")}: {r.get(\"count\")} requests')
"
  }
  run_test "4.4 /api/top-callers" test_4_4_top_callers

  test_4_5_latency_percentiles() {
    local resp
    resp=$(curl -sS ${CURL_K} \
      -H "Authorization: Bearer ${DASH_TOKEN}" \
      "${DASHBOARD_URL%/}/api/latency-percentiles?days=1" 2>/dev/null)

    echo "${resp}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
p50 = data.get('p50')
p95 = data.get('p95')
p99 = data.get('p99')
print(f'p50={p50}ms  p95={p95}ms  p99={p99}ms')
if p50 is None:
    print('latency percentiles are null — no data')
    sys.exit(1)
if not (isinstance(p50, (int, float)) and p50 > 0):
    print(f'invalid p50: {p50}')
    sys.exit(1)
"
  }
  run_test "4.5 /api/latency-percentiles" test_4_5_latency_percentiles

  test_4_6_error_rate() {
    local resp
    resp=$(curl -sS ${CURL_K} \
      -H "Authorization: Bearer ${DASH_TOKEN}" \
      "${DASHBOARD_URL%/}/api/error-rate?days=1" 2>/dev/null)

    echo "${resp}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = data.get('data', [])
if not rows:
    print('empty data')
    sys.exit(1)
for r in rows:
    print(f'{r.get(\"date\")}: total={r.get(\"total\")} errors={r.get(\"errors\")} rate={r.get(\"rate\")}%')
    for field in ('total', 'errors', 'rate'):
        if field not in r:
            print(f'missing field: {field}')
            sys.exit(1)
"
  }
  run_test "4.6 /api/error-rate" test_4_6_error_rate
fi

echo "" >&2

# =============================================================================
# PHASE 5: Dashboard Frontend HTML Verification
# =============================================================================
CURRENT_LAYER="Phase 5: Dashboard HTML"
log_step "${CURRENT_LAYER}"

if [[ -z "${DASHBOARD_URL}" ]]; then
  log_warn "dashboard URL not found — skipping Phase 5"
  for t in "5.1" "5.2" "5.3" "5.4"; do
    _record SKIP "${t}" "no dashboard URL"
  done
else
  DASH_TOKEN="${DASH_TOKEN:-$(_get_token "${DASHBOARD_URL}")}"

  test_5_1_html_chartjs() {
    local html
    html=$(curl -sS ${CURL_K} \
      -H "Authorization: Bearer ${DASH_TOKEN}" \
      "${DASHBOARD_URL%/}/" 2>/dev/null)

    echo "${html}" | python3 -c "
import sys
html = sys.stdin.read().lower()
if 'chart.js' not in html and 'chart.min.js' not in html:
    print('Chart.js reference not found')
    sys.exit(1)
print('Chart.js loaded')
"
  }
  run_test "5.1 Chart.js reference in HTML" test_5_1_html_chartjs

  test_5_2_chart_containers() {
    local html
    html=$(curl -sS ${CURL_K} \
      -H "Authorization: Bearer ${DASH_TOKEN}" \
      "${DASHBOARD_URL%/}/" 2>/dev/null)

    echo "${html}" | python3 -c "
import sys
html = sys.stdin.read()
containers = ['chart-rpd', 'chart-rbm', 'chart-er', 'latency-cards', 'table-tc', 'table-rr']
missing = [c for c in containers if c not in html]
if missing:
    print(f'missing containers: {missing}')
    sys.exit(1)
print(f'all {len(containers)} containers present')
"
  }
  run_test "5.2 All 6 chart/table containers" test_5_2_chart_containers

  test_5_3_auto_refresh() {
    local html
    html=$(curl -sS ${CURL_K} \
      -H "Authorization: Bearer ${DASH_TOKEN}" \
      "${DASHBOARD_URL%/}/" 2>/dev/null)

    echo "${html}" | python3 -c "
import sys
html = sys.stdin.read()
if '60000' not in html:
    print('60-second auto-refresh interval not found')
    sys.exit(1)
print('auto-refresh interval set (60s)')
"
  }
  run_test "5.3 Auto-refresh interval (60s)" test_5_3_auto_refresh

  test_5_4_api_calls() {
    local html
    html=$(curl -sS ${CURL_K} \
      -H "Authorization: Bearer ${DASH_TOKEN}" \
      "${DASHBOARD_URL%/}/" 2>/dev/null)

    echo "${html}" | python3 -c "
import sys
html = sys.stdin.read()
endpoints = ['/api/requests-per-day', '/api/requests-by-model', '/api/top-callers',
             '/api/error-rate', '/api/latency-percentiles', '/api/recent-requests']
missing = [e for e in endpoints if e not in html]
if missing:
    print(f'missing API calls: {missing}')
    sys.exit(1)
print(f'all {len(endpoints)} API endpoints referenced')
"
  }
  run_test "5.4 All 6 API endpoint references" test_5_4_api_calls
fi

echo "" >&2

# =============================================================================
# Summary
# =============================================================================
log_step "results"
echo "================================================================" >&2
echo "  Dashboard Traffic Verification Results" >&2
echo "================================================================" >&2
for layer in \
  "Phase 0: Infrastructure" \
  "Phase 1: Send Requests" \
  "Phase 2: Cloud Logging" \
  "Phase 3: BigQuery" \
  "Phase 4: Dashboard API" \
  "Phase 5: Dashboard HTML"; do

  local_pass=${LAYER_PASS[$layer]:-0}
  local_fail=${LAYER_FAIL[$layer]:-0}
  local_skip=${LAYER_SKIP[$layer]:-0}
  total=$((local_pass + local_fail + local_skip))
  [[ "${total}" == "0" ]] && continue
  printf "  %-36s [%d/%d PASS" "${layer}" "${local_pass}" "$((local_pass + local_fail))" >&2
  [[ "${local_fail}" -gt 0 ]] && printf ", ${_CLR_RED}%d FAIL${_CLR_RESET}" "${local_fail}" >&2
  [[ "${local_skip}" -gt 0 ]] && printf ", %d SKIPPED" "${local_skip}" >&2
  printf "]\n" >&2
done
echo "================================================================" >&2
printf "  TOTAL: ${_CLR_GREEN}%d PASS${_CLR_RESET}, " "${PASS_COUNT}" >&2
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  printf "${_CLR_RED}%d FAIL${_CLR_RESET}, " "${FAIL_COUNT}" >&2
else
  printf "%d FAIL, " "${FAIL_COUNT}" >&2
fi
printf "%d SKIPPED\n" "${SKIP_COUNT}" >&2
echo "================================================================" >&2

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo "" >&2
  log_error "some checks failed — review the FAIL entries above for remediation guidance"
  exit 1
else
  echo "" >&2
  log_info "all checks passed — traffic is flowing through the full pipeline to the dashboard"
fi
