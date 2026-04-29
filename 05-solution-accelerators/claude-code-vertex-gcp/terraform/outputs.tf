# =============================================================================
# outputs.tf — surfaces the URLs and hints the deploy scripts need.
# =============================================================================

output "project_id" {
  description = "The GCP project this deployment lives in."
  value       = var.project_id
}

output "region" {
  description = "The Vertex region selected for Claude calls."
  value       = var.region
}

output "llm_gateway_url" {
  description = "Cloud Run URL of the LLM gateway. Empty when the gateway is disabled."
  value       = length(module.llm_gateway) > 0 ? module.llm_gateway[0].service_url : ""
}

output "mcp_gateway_url" {
  description = "Cloud Run URL of the MCP gateway. Empty when disabled."
  value       = length(module.mcp_gateway) > 0 ? module.mcp_gateway[0].service_url : ""
}

output "dev_portal_url" {
  description = "Cloud Run URL of the dev portal. Empty when disabled."
  value       = length(module.dev_portal) > 0 ? module.dev_portal[0].service_url : ""
}

output "dev_vm_ssh_command" {
  description = "gcloud command to SSH into the dev VM via IAP. Empty when the VM is disabled."
  value       = length(module.dev_vm) > 0 ? module.dev_vm[0].ssh_command : ""
}

output "artifact_registry_repo" {
  description = "Artifact Registry repository path that holds the container images."
  value       = "${local.gce_region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "glb_ip" {
  description = "Static IP of the Global Load Balancer. Empty when GLB is disabled."
  value       = length(module.glb) > 0 ? module.glb[0].glb_ip : ""
}

output "glb_url" {
  description = "HTTPS URL of the Global Load Balancer. Empty when GLB is disabled."
  value       = length(module.glb) > 0 ? module.glb[0].glb_url : ""
}

output "llm_gateway_effective_url" {
  description = "URL developers should use for the LLM gateway (GLB URL when enabled, otherwise Cloud Run URL)."
  value = (
    var.enable_glb && length(module.glb) > 0
    ? module.glb[0].glb_url
    : length(module.llm_gateway) > 0 ? module.llm_gateway[0].service_url : ""
  )
}

output "next_steps" {
  description = "Human-readable hints for what to do after a successful apply."
  value = join("\n", compact([
    "Deployment complete.",
    length(module.llm_gateway) > 0 ? "  LLM gateway: ${module.llm_gateway[0].service_url}" : "",
    length(module.mcp_gateway) > 0 ? "  MCP gateway: ${module.mcp_gateway[0].service_url}" : "",
    length(module.dev_portal) > 0 ? "  Dev portal:  ${module.dev_portal[0].service_url}" : "",
    length(module.dev_vm) > 0 ? "  Dev VM SSH:  ${module.dev_vm[0].ssh_command}" : "",
    "",
    "Next: run ./scripts/developer-setup.sh on each developer's laptop.",
  ]))
}
