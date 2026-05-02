# Handy Cloud Logging queries

Paste these into the
[Cloud Logging Logs Explorer](https://console.cloud.google.com/logs)
advanced-query field. They all filter to just the LLM and MCP gateway
services. Adjust the time range in the UI.

If you prefer SQL, the same data lives in the BigQuery dataset
`claude_code_logs` — use these as templates and translate.

---

## 1. All gateway requests (paged)

```
resource.type="cloud_run_revision"
resource.labels.service_name=~"^(llm-gateway|mcp-gateway)$"
```

Useful as a starting point. Click "View JSON" on an entry to see the
full `jsonPayload` structure.

---

## 2. Errors only

```
resource.type="cloud_run_revision"
resource.labels.service_name=~"^(llm-gateway|mcp-gateway)$"
jsonPayload.status_code >= 400
```

Shows everything the gateway relayed as 4xx or 5xx. For debugging a
failed session, add
`jsonPayload.caller="[email protected]"` to narrow.

---

## 3. Recent 429 (quota) events

```
resource.type="cloud_run_revision"
resource.labels.service_name="llm-gateway"
jsonPayload.status_code=429
```

If this is nonzero you probably need to request a Vertex quota bump —
see `TROUBLESHOOTING.md` → "HTTP 429: quota exceeded".

---

## 4. Requests by a specific user today

```
resource.type="cloud_run_revision"
resource.labels.service_name="llm-gateway"
jsonPayload.caller="[email protected]"
timestamp >= timestamp_sub(@now, INTERVAL 1 DAY)
```

---

## 5. Long-latency requests (>5 s to headers)

```
resource.type="cloud_run_revision"
resource.labels.service_name="llm-gateway"
jsonPayload.latency_ms_to_headers > 5000
```

Useful for catching cold starts + slow regions. Combine with a
`jsonPayload.vertex_region=` filter to compare.

---

## 6. Requests where beta headers were stripped

```
resource.type="cloud_run_revision"
resource.labels.service_name="llm-gateway"
jsonPayload.betas_stripped:*
NOT jsonPayload.betas_stripped = []
```

Should be **empty** in a healthy deployment — developers should have
`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` set client-side. Entries
here point at clients running without that flag.

---

## 7. Top models by request count (BigQuery SQL)

Before running any SQL, **discover the exact table name** — log sinks
name tables after the log stream, and the name varies slightly by GCP
version (`run_googleapis_com_stdout`, `run_googleapis_com_requests`,
etc.). One-liner:

```bash
bq ls --format=prettyjson "$PROJECT_ID:claude_code_logs" \
  | jq -r '.[].tableReference.tableId'
```

Substitute the output into the queries below where you see
`run_googleapis_com_stdout`.

Paste into the BigQuery console against the `claude_code_logs` dataset:

```sql
SELECT
  JSON_VALUE(jsonPayload, '$.model') AS model,
  COUNT(*) AS requests
FROM `PROJECT_ID.claude_code_logs.run_googleapis_com_stdout`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  AND JSON_VALUE(jsonPayload, '$.model') IS NOT NULL
GROUP BY model
ORDER BY requests DESC
```

Replace `PROJECT_ID` and double-check the table name — log sinks name
the table after the log stream (`run_googleapis_com_stdout`,
`run_googleapis_com_requests`, etc.), which varies slightly by GCP
version. Open the dataset in the BigQuery UI to see the exact name.

---

## 8. p95 latency by model, last 24h (BigQuery SQL)

```sql
SELECT
  JSON_VALUE(jsonPayload, '$.model') AS model,
  APPROX_QUANTILES(
    SAFE_CAST(JSON_VALUE(jsonPayload, '$.latency_ms_to_headers') AS INT64),
    100
  )[OFFSET(95)] AS p95_ms,
  COUNT(*) AS n
FROM `PROJECT_ID.claude_code_logs.run_googleapis_com_stdout`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
  AND JSON_VALUE(jsonPayload, '$.latency_ms_to_headers') IS NOT NULL
GROUP BY model
ORDER BY p95_ms DESC
```

---

## 9. Per-user token-consumption proxy, last 7 days (BigQuery SQL)

We don't log Vertex's returned token counts (yet), so the best proxy
is request count weighted by model. Rough heuristic:

```sql
WITH weights AS (
  SELECT 'claude-opus-4-6'   AS model, 10 AS weight UNION ALL
  SELECT 'claude-sonnet-4-6' AS model,  3 AS weight UNION ALL
  SELECT 'claude-haiku-4-5'  AS model,  1 AS weight
)
SELECT
  JSON_VALUE(p.jsonPayload, '$.caller') AS caller,
  SUM(w.weight) AS weighted_requests
FROM `PROJECT_ID.claude_code_logs.run_googleapis_com_stdout` p
LEFT JOIN weights w
  ON w.model = JSON_VALUE(p.jsonPayload, '$.model')
WHERE p.timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
GROUP BY caller
ORDER BY weighted_requests DESC
LIMIT 20
```

Swap in real token counts if / when you extend the gateway to parse
them from the Vertex response (`usage.input_tokens`,
`usage.output_tokens`).

---

## 10. What regions are actually serving traffic?

```
resource.type="cloud_run_revision"
resource.labels.service_name="llm-gateway"
jsonPayload.upstream_host:*
```

Click **Fields** → `jsonPayload.upstream_host` to see a breakdown of
which Vertex hostnames are receiving traffic. Useful for confirming
`CLOUD_ML_REGION=global` is actually load-balancing across regions.

---

## 11. Token-debit entries (per-caller usage, gzip-aware)

Every successful Claude response emits one `token_debit` entry once
the gateway has read Vertex's `usage` field. The gateway decompresses
gzip and parses both rawPredict and streaming SSE shapes, so this
entry is reliable regardless of `Content-Encoding`.

```
resource.type="cloud_run_revision"
resource.labels.service_name="llm-gateway"
jsonPayload.message="token_debit"
```

Each entry carries `caller`, `input_tokens`, `output_tokens`, and
`total_tokens`. Only emitted when `TOKEN_LIMIT_PER_MIN` is set (off
by default). This is the data backing the dashboard's
`tokens-by-caller` and `token-burn-rate` panels.

**BigQuery — top token consumers, last 24h:**

```sql
SELECT
  jsonPayload.caller AS caller,
  SUM(SAFE_CAST(jsonPayload.input_tokens  AS INT64)) AS in_tok,
  SUM(SAFE_CAST(jsonPayload.output_tokens AS INT64)) AS out_tok,
  SUM(SAFE_CAST(jsonPayload.total_tokens  AS INT64)) AS total_tok,
  COUNT(*) AS calls
FROM `<PROJECT>.claude_code_logs.run_googleapis_com_stdout`
WHERE jsonPayload.message = "token_debit"
  AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
GROUP BY caller
ORDER BY total_tok DESC
LIMIT 25
```

---

## 12. Token-cap rejections (429s from the per-caller token bucket)

```
resource.type="cloud_run_revision"
resource.labels.service_name="llm-gateway"
jsonPayload.message="token_limited"
```

Each entry has `caller`, `estimated_input_tokens`, and `retry_after_s`.
Backs the dashboard's `token-limit-rejections` panel. A run of these
from one caller usually means their cap is too tight; from many
callers, the project-wide cap may need raising.

---

## 13. Settings-tab audit trail

Every successful Settings-tab POST emits one `policy_change` WARNING
entry from the dashboard service. Pair with Cloud Run's own
admin-activity log for a two-source audit trail.

```
resource.type="cloud_run_revision"
resource.labels.service_name="admin-dashboard"
jsonPayload.message="policy_change"
```

Fields: `editor` (the IAP-asserted email that made the change) and
`diff` (the env-var keys and new values). For denied attempts:

```
resource.type="cloud_run_revision"
resource.labels.service_name="admin-dashboard"
jsonPayload.message=~"policy_edit_denied|no IAP-authenticated"
```
