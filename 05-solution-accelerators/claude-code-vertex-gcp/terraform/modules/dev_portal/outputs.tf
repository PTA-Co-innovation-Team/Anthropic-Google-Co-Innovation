output "service_url" {
  description = "HTTPS URL of the dev portal Cloud Run service."
  value       = google_cloud_run_v2_service.portal.uri
}

output "service_name" {
  description = "Cloud Run service name."
  value       = google_cloud_run_v2_service.portal.name
}
