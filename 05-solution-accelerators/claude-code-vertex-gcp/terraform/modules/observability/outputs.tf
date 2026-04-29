output "dataset_id" {
  description = "BigQuery dataset holding the gateway logs."
  value       = google_bigquery_dataset.logs.dataset_id
}

output "sink_writer_identity" {
  description = "Writer identity of the log sink (useful for debugging IAM on the BQ dataset)."
  value       = google_logging_project_sink.gateway.writer_identity
}

output "looker_views" {
  description = "Names of the BigQuery views created for Looker Studio. Empty when enable_looker_views is false."
  value = var.enable_looker_views ? [
    "v_requests_summary",
    "v_error_analysis",
    "v_latency_stats",
    "v_top_callers",
    "v_recent_requests",
  ] : []
}
