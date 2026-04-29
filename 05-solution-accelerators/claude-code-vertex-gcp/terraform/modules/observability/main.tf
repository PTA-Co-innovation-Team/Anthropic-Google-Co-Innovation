# =============================================================================
# Observability module.
#
# Creates:
#   * A BigQuery dataset that holds gateway request logs.
#   * A log sink that routes Cloud Run logs from the LLM+MCP gateways
#     into the dataset.
#
# BigQuery views for Looker Studio can be enabled with enable_looker_views.
# See observability/looker-studio-template.md or run scripts/setup-looker-studio.sh.
# =============================================================================

locals {
  dataset_id = "claude_code_logs"
  sink_name  = "claude-code-gateway-logs"
}

# --- BigQuery dataset --------------------------------------------------------
resource "google_bigquery_dataset" "logs" {
  project                    = var.project_id
  dataset_id                 = local.dataset_id
  friendly_name              = "Claude Code gateway logs"
  description                = "Log sink destination for LLM + MCP gateway request logs. Feeds the admin dashboard and optional Looker Studio views."
  location                   = var.region
  labels                     = var.labels
  delete_contents_on_destroy = false

  # Expire partitions after retention window. Cheap way to cap storage
  # cost; more advanced schemes can be added later.
  default_partition_expiration_ms = var.log_retention_days * 24 * 60 * 60 * 1000
}

# --- Log sink ----------------------------------------------------------------
# Filter captures any Cloud Run revision log from our gateway services.
# The service names must match the ones set in llm_gateway/main.tf and
# mcp_gateway/main.tf.
resource "google_logging_project_sink" "gateway" {
  project                = var.project_id
  name                   = local.sink_name
  description            = "Routes gateway request logs into BigQuery for the admin dashboard and Looker Studio views."
  destination            = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.logs.dataset_id}"
  unique_writer_identity = true

  filter = <<-EOT
    resource.type="cloud_run_revision"
    AND resource.labels.service_name=~"^(llm-gateway|mcp-gateway)$"
  EOT

  bigquery_options {
    # Use partitioned tables — one per day. Makes the dataset small
    # and the dashboard fast.
    use_partitioned_tables = true
  }
}

# --- Grant the sink's writer identity permission to write to BQ -------------
resource "google_bigquery_dataset_iam_member" "sink_writer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.gateway.writer_identity
}

# --- BigQuery views for Looker Studio (optional) -----------------------------
# Provides stable, well-named data sources on top of the variable-named raw
# log table. Enable after the log sink has created its first table.

resource "google_bigquery_table" "v_requests_summary" {
  count      = var.enable_looker_views ? 1 : 0
  project    = var.project_id
  dataset_id = google_bigquery_dataset.logs.dataset_id
  table_id   = "v_requests_summary"

  view {
    query          = <<-SQL
      SELECT
        DATE(timestamp) AS date,
        jsonPayload.model AS model,
        jsonPayload.caller AS caller,
        jsonPayload.vertex_region AS vertex_region,
        COUNT(*) AS request_count,
        COUNTIF(CAST(jsonPayload.status_code AS INT64) >= 400) AS error_count
      FROM `${var.project_id}.${local.dataset_id}.${var.log_table_name}`
      WHERE jsonPayload.model IS NOT NULL
      GROUP BY date, model, caller, vertex_region
    SQL
    use_legacy_sql = false
  }

  deletion_protection = false
  labels              = var.labels
}

resource "google_bigquery_table" "v_error_analysis" {
  count      = var.enable_looker_views ? 1 : 0
  project    = var.project_id
  dataset_id = google_bigquery_dataset.logs.dataset_id
  table_id   = "v_error_analysis"

  view {
    query          = <<-SQL
      SELECT
        DATE(timestamp) AS date,
        jsonPayload.model AS model,
        CAST(jsonPayload.status_code AS INT64) AS status_code,
        jsonPayload.caller AS caller,
        COUNT(*) AS count
      FROM `${var.project_id}.${local.dataset_id}.${var.log_table_name}`
      WHERE CAST(jsonPayload.status_code AS INT64) >= 400
      GROUP BY date, model, status_code, caller
    SQL
    use_legacy_sql = false
  }

  deletion_protection = false
  labels              = var.labels
}

resource "google_bigquery_table" "v_latency_stats" {
  count      = var.enable_looker_views ? 1 : 0
  project    = var.project_id
  dataset_id = google_bigquery_dataset.logs.dataset_id
  table_id   = "v_latency_stats"

  view {
    query          = <<-SQL
      SELECT
        timestamp,
        DATE(timestamp) AS date,
        jsonPayload.model AS model,
        jsonPayload.caller AS caller,
        CAST(jsonPayload.latency_ms_to_headers AS INT64) AS latency_ms
      FROM `${var.project_id}.${local.dataset_id}.${var.log_table_name}`
      WHERE jsonPayload.latency_ms_to_headers IS NOT NULL
    SQL
    use_legacy_sql = false
  }

  deletion_protection = false
  labels              = var.labels
}

resource "google_bigquery_table" "v_top_callers" {
  count      = var.enable_looker_views ? 1 : 0
  project    = var.project_id
  dataset_id = google_bigquery_dataset.logs.dataset_id
  table_id   = "v_top_callers"

  view {
    query          = <<-SQL
      SELECT
        jsonPayload.caller AS caller,
        jsonPayload.model AS model,
        COUNT(*) AS request_count,
        COUNTIF(CAST(jsonPayload.status_code AS INT64) >= 400) AS error_count,
        MIN(timestamp) AS first_seen,
        MAX(timestamp) AS last_seen
      FROM `${var.project_id}.${local.dataset_id}.${var.log_table_name}`
      WHERE jsonPayload.caller IS NOT NULL
      GROUP BY caller, model
    SQL
    use_legacy_sql = false
  }

  deletion_protection = false
  labels              = var.labels
}

resource "google_bigquery_table" "v_recent_requests" {
  count      = var.enable_looker_views ? 1 : 0
  project    = var.project_id
  dataset_id = google_bigquery_dataset.logs.dataset_id
  table_id   = "v_recent_requests"

  view {
    query          = <<-SQL
      SELECT
        timestamp,
        jsonPayload.caller AS caller,
        jsonPayload.caller_source AS caller_source,
        jsonPayload.method AS method,
        jsonPayload.model AS model,
        CAST(jsonPayload.status_code AS INT64) AS status_code,
        CAST(jsonPayload.latency_ms_to_headers AS INT64) AS latency_ms,
        jsonPayload.vertex_region AS vertex_region,
        jsonPayload.path AS path
      FROM `${var.project_id}.${local.dataset_id}.${var.log_table_name}`
      WHERE jsonPayload.model IS NOT NULL
    SQL
    use_legacy_sql = false
  }

  deletion_protection = false
  labels              = var.labels
}
