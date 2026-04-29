# Looker Studio dashboard setup (optional)

> **Note:** The deploy scripts create a **built-in Admin Dashboard**
> (Cloud Run service) that provides real-time charts out of the box — no
> Looker Studio setup required. This guide is for teams that want a
> **custom** Looker Studio dashboard with their own panels and sharing
> permissions.

---

## Quick start

The deploy script (`scripts/deploy-observability.sh`) automatically
creates five BigQuery views that serve as stable data sources for
Looker Studio. To generate a report URL:

```bash
scripts/setup-looker-studio.sh --project YOUR_PROJECT_ID
```

Open the primary URL in your browser — Looker Studio creates a new
report with `v_recent_requests` as the initial data source. Then add
the remaining four views inside the editor via **Resource > Manage
added data sources > Add a data source > BigQuery** (select
project > `claude_code_logs` dataset > view name).

> **Why not all five at once?** The Looker Studio Linking API only
> supports one data source per URL when creating a new report.
> Multiple data sources require a template report (see
> "Template-based cloning" below).

---

## What the views provide

| View | Purpose | Key columns |
|------|---------|-------------|
| `v_requests_summary` | Daily aggregated counts | `date`, `model`, `caller`, `vertex_region`, `request_count`, `error_count` |
| `v_error_analysis` | Error breakdown by status code | `date`, `model`, `status_code`, `caller`, `count` |
| `v_latency_stats` | Per-request latency for percentile charts | `date`, `model`, `caller`, `latency_ms` |
| `v_top_callers` | Caller activity with model breakdown | `caller`, `model`, `request_count`, `error_count`, `first_seen`, `last_seen` |
| `v_recent_requests` | Flat denormalized view for live tables | `timestamp`, `caller`, `model`, `status_code`, `latency_ms`, `vertex_region`, `path` |

The views sit on top of the raw log table (whose name varies by GCP
version) and provide clean, stable column names that Looker Studio can
connect to reliably.

---

## Prerequisites

1. The `observability` module has been deployed
   (`enable_observability: true` in `config.yaml` or
   `enable_observability = true` in `terraform.tfvars`).
2. The gateways have received at least one request — the raw log table
   is created by Cloud Logging on first write, and the views reference it.
   Running `scripts/seed-demo-data.sh` is the easiest way to generate data.
3. You have **Viewer** on the BigQuery dataset in the deployment project.

---

## Creating views

Views are created automatically by `scripts/deploy-observability.sh`
after the raw log table exists. If you use Terraform, set
`enable_looker_views = true` and `log_table_name` in your
`terraform.tfvars`:

```hcl
enable_looker_views = true
log_table_name      = "run_googleapis_com_stdout"  # check your dataset
```

To find your table name, open BigQuery in the Console and look inside
the `claude_code_logs` dataset for a table starting with
`run_googleapis_com_`.

---

## Building the report panels

After opening the Looker Studio URL, add panels using the pre-connected
data sources. Here are recommended panels:

### Panel A — Requests per day

- Data source: `v_requests_summary`
- Chart type: **Time series**
- Date dimension: `date`
- Metric: `request_count` (SUM)

### Panel B — Requests by model

- Data source: `v_requests_summary`
- Chart type: **Pie chart**
- Dimension: `model`
- Metric: `request_count` (SUM)

### Panel C — Top callers

- Data source: `v_top_callers`
- Chart type: **Table**
- Dimension: `caller`
- Metrics: `request_count`, `error_count`
- Sort: `request_count` descending

### Panel D — Error rate over time

- Data source: `v_error_analysis`
- Chart type: **Time series**
- Date dimension: `date`
- Metric: `count` (SUM)
- Breakdown dimension: `status_code`

### Panel E — Latency percentiles

- Data source: `v_latency_stats`
- Chart type: **Scorecard** (three side by side)
- Metrics:
  - `PERCENTILE(latency_ms, 50)` labelled "p50 ms"
  - `PERCENTILE(latency_ms, 95)` labelled "p95 ms"
  - `PERCENTILE(latency_ms, 99)` labelled "p99 ms"

### Panel F — Recent requests

- Data source: `v_recent_requests`
- Chart type: **Table**
- Columns: `timestamp`, `caller`, `model`, `status_code`, `latency_ms`, `vertex_region`
- Sort: `timestamp` descending

---

## Template-based cloning (multi-project)

Once you've built a compelling report with all five data sources and
polished panels, you can turn it into a **template** that other
projects clone with their own data:

1. Open your finished report in Looker Studio.
2. Copy the **report ID** from the URL:
   `https://lookerstudio.google.com/reporting/<REPORT_ID>/page/...`
3. Update `scripts/setup-looker-studio.sh`: set the `TEMPLATE_ID`
   variable to your report ID (or pass `--template-id <id>`).
4. When other projects run the script, it generates a clone URL:
   ```
   https://lookerstudio.google.com/reporting/create
     ?c.reportId=<TEMPLATE_ID>
     &ds.ds0.connector=bigQuery&ds.ds0.projectId=<THEIR_PROJECT>&...
   ```
   The `ds.ds0`–`ds.ds4` aliases remap each data source to the new
   project's BigQuery views — the report layout, charts, and theme
   are preserved from the template.

> **Important:** For this to work, each data source in your template
> must have a **Data source alias** set (`ds0` through `ds4`). In the
> report editor: Resource > Manage added data sources > Edit (pencil
> icon) > set the alias field. Map them as:
> `ds0`=`v_requests_summary`, `ds1`=`v_error_analysis`,
> `ds2`=`v_latency_stats`, `ds3`=`v_top_callers`,
> `ds4`=`v_recent_requests`.

---

## Save + share

1. Rename the report (top-left) to something like
   "Claude Code on Vertex — Ops".
2. Click **Share > Add people**, grant Viewer to your team's Google group.

---

## Tips for operators

- **Ingestion lag** from Cloud Logging to BigQuery is usually < 1 minute
  but can spike under heavy write load.
- **Cost.** The sink writes partitioned tables; the Terraform module
  sets `default_partition_expiration_ms` from `var.log_retention_days`
  (90 days by default). Shorten it to reduce storage cost.
- **View recreation.** Views are recreated on each
  `deploy-observability.sh` run (idempotent PUT). If you change the raw
  table name, re-run the deploy script.
- **Quota alerts.** Consider a Looker Studio alert on Panel D (error
  rate) to catch 429 spikes.

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
| `path` | string | `/v1/projects/.../publishers/anthropic/models/claude-opus-4-6:rawPredict` |
| `upstream_host` | string | `us-east5-aiplatform.googleapis.com` |
| `vertex_region` | string | `us-east5` |
| `model` | string | `claude-opus-4-6` |
| `status_code` | int | `200` |
| `latency_ms_to_headers` | int | `812` |
| `betas_stripped` | list | `["anthropic-beta"]` or `[]` |

See `observability/log-queries.md` for raw Cloud Logging queries you
can paste into the Logs Explorer without spinning up Looker Studio.
