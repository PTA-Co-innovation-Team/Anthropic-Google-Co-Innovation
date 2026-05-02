# Looker Studio dashboard setup — optional, advanced

> **You almost certainly do not need this.** The deploy scripts create a
> **built-in Admin Dashboard** (Cloud Run service) that renders the same
> panels real-time, with no manual setup. See
> `CUSTOMER-RUNBOOK.md → Observability — Admin Dashboard`.
>
> Use this guide only if you have a specific reason to maintain a Looker
> Studio variant (e.g., embedding into an existing Looker workspace, or
> sharing with non-technical stakeholders who already use Looker).
> Setup is ~10 minutes of manual clicks; not automated by the deploy
> scripts.

The `observability` Terraform module creates a BigQuery dataset called
**`claude_code_logs`** and a Cloud Logging sink that routes all
`llm-gateway` and `mcp-gateway` Cloud Run logs into it. This page walks
you through pointing a Looker Studio dashboard at that dataset.

Time required: **~10 minutes**. Beginner-friendly.

---

## What the dashboard will show

- Requests per day, per model, per caller
- p50 / p95 / p99 latency to Vertex
- Error rate over time (non-2xx responses)
- Top token consumers (by caller email)
- Which betas are being stripped (debug-only panel)

All of this is powered by the structured fields the LLM gateway emits —
see `gateway/app/logging_config.py` and `gateway/app/proxy.py` for the
exact shape.

---

## Prerequisites

1. The `observability` module has been deployed
   (`enable_observability: true` in `config.yaml` or
   `enable_observability = true` in `terraform.tfvars`).
2. The gateways have received at least one request — otherwise the
   dataset exists but is empty and Looker shows nothing.
   Running `scripts/developer-setup.sh` and asking Claude a quick
   question is the easiest way to generate data.
3. You have **Viewer** on the BigQuery dataset in the deployment
   project.

---

## 1. Confirm the dataset exists

In the Google Cloud Console:

1. Open **BigQuery** (https://console.cloud.google.com/bigquery).
2. Select the deployment project in the top-left picker.
3. Expand the project in the left panel. You should see a dataset
   named **`claude_code_logs`** with a table called **`run_googleapis_com_requests`** (or similar — the log sink names the table after the log name).

If the dataset is missing, the Terraform module probably wasn't
applied. Check `enable_observability` in your config.

---

## 2. Create the Looker Studio data source

1. Open https://lookerstudio.google.com/.
2. Click **Create → Data source**.
3. Choose the **BigQuery** connector.
4. Select your project → dataset `claude_code_logs` → table (the one
   named like `run_googleapis_com_requests`, `run_googleapis_com_stdout`,
   or similar).
5. Click **Connect** (top-right).
6. On the fields-review page, **do not change field types** — the
   defaults are fine. Click **Create Report**.

---

## 3. Build the report panels

Looker Studio drops you into a blank report with the data source
attached. Add these panels one by one.

> Tip: all of these pull from fields inside `jsonPayload` (the parsed
> JSON we emit from the gateway). Looker flattens these to paths like
> `jsonPayload.caller`, `jsonPayload.model`, `jsonPayload.latency_ms_to_headers`.

### Panel A — Requests per day

- Chart type: **Time series**
- Date range: last 30 days
- Date dimension: `timestamp`
- Metric: **Record count** (Looker's built-in)

### Panel B — Requests by model

- Chart type: **Pie chart**
- Dimension: `jsonPayload.model`
- Metric: **Record count**

### Panel C — Top callers

- Chart type: **Table**
- Dimension: `jsonPayload.caller`
- Metric: **Record count**
- Sort: count descending
- Rows: 20

### Panel D — Error rate

- Chart type: **Time series**
- Date dimension: `timestamp`
- Breakdown dimension: *(none)*
- Metric: **calculated field** — paste this formula into a new field:
  ```
  SUM(IF(jsonPayload.status_code >= 400, 1, 0)) / COUNT(jsonPayload.status_code)
  ```
- Format the metric as **Percent**.

### Panel E — Latency percentiles

- Chart type: **Scorecard** (three of them side by side)
- Metric for each:
  - Scorecard 1: **`PERCENTILE(jsonPayload.latency_ms_to_headers, 50)`** labelled "p50 ms"
  - Scorecard 2: **`PERCENTILE(jsonPayload.latency_ms_to_headers, 95)`** labelled "p95 ms"
  - Scorecard 3: **`PERCENTILE(jsonPayload.latency_ms_to_headers, 99)`** labelled "p99 ms"

### Panel F — Experimental betas being stripped

(Useful for catching Claude Code versions with beta features Vertex
rejects — you want this at zero.)

- Chart type: **Table**
- Dimension: `jsonPayload.betas_stripped` (treat as string)
- Metric: **Record count**
- Filter: `jsonPayload.betas_stripped` is not null and not `[]`.

> **Note.** The next three panels surface data the gateway only emits
> when the per-caller token cap is enabled (`TOKEN_LIMIT_PER_MIN` set
> on `llm-gateway`). The Admin Dashboard renders the same three
> panels with no extra setup.

### Panel G — Tokens by caller

- Chart type: **Table**
- Filter (data source level): `jsonPayload.message` = `token_debit`
- Dimension: `jsonPayload.caller`
- Metrics: SUM of `jsonPayload.input_tokens`, `jsonPayload.output_tokens`, `jsonPayload.total_tokens`; COUNT of records (calls).
- Sort: total_tokens descending.

### Panel H — Token burn-rate

- Chart type: **Time series**
- Filter: `jsonPayload.message` = `token_debit`
- Date dimension: `timestamp` (granularity: minute)
- Metric: SUM of `jsonPayload.total_tokens`

### Panel I — Token-limit rejections

- Chart type: **Bar chart**
- Filter: `jsonPayload.message` = `token_limited`
- Dimension: `jsonPayload.caller`
- Metric: **Record count** (label as "rejection_count")
- Sort: rejection_count descending.

### Panel J — Settings-tab audit trail (optional)

(Only relevant if you've enabled the Settings tab on the dashboard.)

- Chart type: **Table**
- Filter: `resource.labels.service_name` = `admin-dashboard` AND `jsonPayload.message` = `policy_change`
- Dimensions: `timestamp`, `jsonPayload.editor`, `jsonPayload.diff`
- Sort: timestamp descending.

---

## 4. Save + share

1. Rename the report (top-left) to something like
   "Claude Code on Vertex — Ops".
2. Click **Share → Add people**, grant Viewer to your team's Google
   group.

---

## 5. Tips for operators

- **Ingestion lag** from Cloud Logging → BigQuery is usually < 1 minute
  but can spike under heavy write load. If the dashboard looks empty,
  check the sink's write activity under the BigQuery → Table Info pane.
- **Cost.** The sink writes partitioned tables; the Terraform module
  sets `default_partition_expiration_ms` from
  `var.log_retention_days` (90 days by default). Shorten it to reduce
  storage cost.
- **Quota alerts.** Consider a Looker alert on Panel D (error rate) so
  you catch 429 spikes the moment they happen.

---

## What the log entries look like

Each Cloud Run log entry emitted by the gateway has a structured
`jsonPayload` containing at least:

| Field | Type | Example |
| --- | --- | --- |
| `message` | string | `proxy_request` |
| `caller` | string | `[email protected]` |
| `caller_source` | string | `cloud_run` / `iap` / `unknown` |
| `method` | string | `POST` |
| `path` | string | `/v1/projects/…/publishers/anthropic/models/claude-opus-4-6:rawPredict` |
| `upstream_host` | string | `us-east5-aiplatform.googleapis.com` |
| `vertex_region` | string | `us-east5` |
| `model` | string | `claude-opus-4-6` |
| `status_code` | int | `200` |
| `latency_ms_to_headers` | int | `812` |
| `betas_stripped` | list | `["anthropic-beta"]` or `[]` |

See `observability/log-queries.md` for raw Cloud Logging queries you
can paste into the Logs Explorer without spinning up Looker.
