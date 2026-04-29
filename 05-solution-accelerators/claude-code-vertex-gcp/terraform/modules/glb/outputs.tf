# =============================================================================
# GLB module outputs.
# =============================================================================

output "glb_ip" {
  description = "Static IP address of the global load balancer."
  value       = google_compute_global_address.glb.address
}

output "glb_url" {
  description = "HTTPS URL for the load balancer (domain or IP)."
  value       = var.domain != "" ? "https://${var.domain}" : "https://${google_compute_global_address.glb.address}"
}
