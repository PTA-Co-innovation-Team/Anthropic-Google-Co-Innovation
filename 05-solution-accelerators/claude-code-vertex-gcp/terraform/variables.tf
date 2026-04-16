# =============================================================================
# variables.tf — root module inputs.
#
# Variable names here are deliberately kept 1:1 with the fields in
# config.yaml so the interactive deploy script can translate between the
# two without a lookup table.
# =============================================================================

# -----------------------------------------------------------------------------
# REQUIRED: which GCP project to deploy into.
# -----------------------------------------------------------------------------
variable "project_id" {
  description = "The GCP project ID to deploy into. Must have billing enabled."
  type        = string
}

# -----------------------------------------------------------------------------
# Vertex region (and, when it's a real region, the GCE/Cloud Run region).
#
# "global" is the multi-region Vertex endpoint. It's NOT a valid region
# for GCE or Cloud Run, so when the user picks "global" we fall back to
# us-central1 for the GCE/Cloud Run plane (the gateways and dev VM).
# See local.gce_region below.
# -----------------------------------------------------------------------------
variable "region" {
  description = "Vertex region (e.g. \"global\", \"us-east5\", \"europe-west3\"). When \"global\" or a multi-region (\"us\", \"europe\"), GCE/Cloud Run resources use var.fallback_region instead."
  type        = string
  default     = "global"
}

variable "fallback_region" {
  description = "Region used for GCE/Cloud Run resources when var.region is a Vertex-only value like \"global\". Ignored otherwise."
  type        = string
  default     = "us-central1"
}

# -----------------------------------------------------------------------------
# Component toggles — mirror components: in config.yaml.
# -----------------------------------------------------------------------------
variable "enable_llm_gateway" {
  description = "Deploy the LLM gateway Cloud Run service. Strongly recommended to leave on."
  type        = bool
  default     = true
}

variable "enable_mcp_gateway" {
  description = "Deploy the MCP gateway Cloud Run service."
  type        = bool
  default     = true
}

variable "enable_dev_vm" {
  description = "Deploy the optional shared developer VM. Off by default; costs money when on."
  type        = bool
  default     = false
}

variable "enable_dev_portal" {
  description = "Deploy the tiny IAP-protected welcome page on Cloud Run."
  type        = bool
  default     = true
}

variable "enable_observability" {
  description = "Install log sink → BigQuery (for the Looker Studio dashboard)."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Dev VM configuration — only read when enable_dev_vm is true.
# -----------------------------------------------------------------------------
variable "dev_vm_mode" {
  description = "\"shared\" for one VM across all devs, or \"per_user\" for one VM per principal."
  type        = string
  default     = "shared"

  validation {
    condition     = contains(["shared", "per_user"], var.dev_vm_mode)
    error_message = "dev_vm_mode must be either \"shared\" or \"per_user\"."
  }
}

variable "dev_vm_machine_type" {
  description = "GCE machine type for the dev VM."
  type        = string
  default     = "e2-small"
}

variable "dev_vm_disk_size_gb" {
  description = "Boot disk size in GB."
  type        = number
  default     = 30
}

variable "dev_vm_auto_shutdown_idle_hours" {
  description = "Auto-shutdown after this many hours with no SSH connections. 0 disables."
  type        = number
  default     = 2
}

variable "dev_vm_install_vscode_server" {
  description = "Install code-server on the dev VM for browser-based VS Code."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Networking knobs.
# -----------------------------------------------------------------------------
variable "use_psc" {
  description = "Create a Private Service Connect endpoint for googleapis.com (on-prem-to-GCP only). Adds ~$10/month."
  type        = bool
  default     = false
}

variable "use_vpc_connector" {
  description = "Create a Serverless VPC Connector so Cloud Run egress is private. ~$10/month when on."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Access control — principals allowed to use this deployment.
# -----------------------------------------------------------------------------
variable "allowed_principals" {
  description = "IAM members (user:, group:, serviceAccount:) granted access to the gateways, dev VM, and portal."
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Model defaults written into developer settings.json.
# -----------------------------------------------------------------------------
variable "pin_model_versions" {
  description = "If true, the developer setup script writes pinned model IDs into settings.json."
  type        = bool
  default     = true
}

variable "model_opus" {
  description = "Pinned Claude Opus model ID."
  type        = string
  default     = "claude-opus-4-6"
}

variable "model_sonnet" {
  description = "Pinned Claude Sonnet model ID."
  type        = string
  default     = "claude-sonnet-4-6"
}

variable "model_haiku" {
  description = "Pinned Claude Haiku model ID."
  type        = string
  default     = "claude-haiku-4-5@20251001"
}

# -----------------------------------------------------------------------------
# Gateway image tags. The deploy scripts build+push images to Artifact
# Registry first; Terraform then references them. Override if you want
# to pin to an immutable SHA tag for production.
# -----------------------------------------------------------------------------
variable "llm_gateway_image" {
  description = "Full Artifact Registry image reference for the LLM gateway."
  type        = string
  default     = ""
}

variable "mcp_gateway_image" {
  description = "Full Artifact Registry image reference for the MCP gateway."
  type        = string
  default     = ""
}

variable "dev_portal_image" {
  description = "Full Artifact Registry image reference for the dev portal."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Derived locals used across resources.
# -----------------------------------------------------------------------------
locals {
  # GCE + Cloud Run need a real region, not "global" or a multi-region.
  # Fall back when needed.
  _vertex_only_regions = toset(["global", "us", "europe", "asia"])
  gce_region = (
    contains(local._vertex_only_regions, var.region)
    ? var.fallback_region
    : var.region
  )

  # A shortened project identifier used to name resources that have a
  # character limit (log sinks, firewall rules). Strips non-alphanumerics.
  project_slug = replace(lower(var.project_id), "/[^a-z0-9]/", "-")

  # Common labels applied to everything we create.
  labels = {
    deployed-by = "claude-code-vertex-gcp"
    managed-by  = "terraform"
  }
}
