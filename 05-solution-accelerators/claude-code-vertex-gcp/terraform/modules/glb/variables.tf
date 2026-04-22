# =============================================================================
# GLB module variables.
# =============================================================================

variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Cloud Run region where services are deployed."
  type        = string
}

variable "domain" {
  description = "Domain for Google-managed SSL cert. Empty = IP-only (self-signed)."
  type        = string
  default     = ""
}

variable "iap_support_email" {
  description = "Support email for the IAP OAuth consent screen. Required for IAP-protected services."
  type        = string
  default     = ""
}

variable "allowed_principals" {
  description = "IAM members granted access via IAP (for browser services)."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Labels applied to GLB resources."
  type        = map(string)
  default     = {}
}

# Service names — empty string means that service is not deployed.
variable "llm_gateway_service_name" {
  description = "Cloud Run service name for the LLM gateway. Empty = not deployed."
  type        = string
  default     = ""
}

variable "mcp_gateway_service_name" {
  description = "Cloud Run service name for the MCP gateway. Empty = not deployed."
  type        = string
  default     = ""
}

variable "dev_portal_service_name" {
  description = "Cloud Run service name for the dev portal. Empty = not deployed."
  type        = string
  default     = ""
}

variable "admin_dashboard_service_name" {
  description = "Cloud Run service name for the admin dashboard. Empty = not deployed."
  type        = string
  default     = ""
}
