output "dataset_id" {
  description = "BigQuery dataset holding the gateway logs."
  value       = google_bigquery_dataset.logs.dataset_id
}

output "sink_writer_identity" {
  description = "Writer identity of the log sink (useful for debugging IAM on the BQ dataset)."
  value       = google_logging_project_sink.gateway.writer_identity
}
