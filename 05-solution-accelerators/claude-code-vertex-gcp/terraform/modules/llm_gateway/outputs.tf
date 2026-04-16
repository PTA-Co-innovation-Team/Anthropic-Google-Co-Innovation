output "service_url" {
  description = "HTTPS URL of the LLM gateway Cloud Run service."
  value       = google_cloud_run_v2_service.gateway.uri
}

output "service_name" {
  description = "Cloud Run service name."
  value       = google_cloud_run_v2_service.gateway.name
}

output "service_account_email" {
  description = "Email of the gateway's dedicated service account."
  value       = google_service_account.sa.email
}
