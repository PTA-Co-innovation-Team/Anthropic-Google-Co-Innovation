# =============================================================================
# Observability module.
#
# Creates:
#   * A BigQuery dataset that holds gateway request logs.
#   * A log sink that routes Cloud Run logs from the LLM+MCP gateways
#     into the dataset.
#
# The Looker Studio template (observability/looker-studio-template.md)
# points at this dataset; see that file for dashboard setup.
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
  description                = "Log sink destination for LLM + MCP gateway request logs. Feeds the Looker Studio dashboard."
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
  description            = "Routes gateway request logs into BigQuery for the Looker dashboard."
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
