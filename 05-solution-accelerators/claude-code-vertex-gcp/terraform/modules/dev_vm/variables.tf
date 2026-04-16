variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Region for disks and the instance."
  type        = string
}

variable "zone" {
  description = "Zone for the instance."
  type        = string
}

variable "network_self_link" {
  description = "Self link of the VPC network to attach the instance to."
  type        = string
}

variable "subnet_self_link" {
  description = "Self link of the regional subnet."
  type        = string
}

variable "mode" {
  description = <<-EOT
    VM deployment mode. One of:
      * "shared"   — a single VM all allowed principals share. Supports
                     user:, group:, and serviceAccount: entries in
                     allowed_principals (everyone SSHes in via OS Login).
      * "per_user" — one VM per "user:" entry in allowed_principals. The
                     local-part of each user's email names the VM
                     (e.g. user:[email protected] → claude-code-dev-alice).
                     group: and serviceAccount: members are ignored in
                     this mode; see the module's precondition for the
                     exact error if no user: entries resolve.
  EOT
  type        = string
  default     = "shared"

  validation {
    condition     = contains(["shared", "per_user"], var.mode)
    error_message = "mode must be either \"shared\" or \"per_user\"."
  }
}

variable "machine_type" {
  description = "GCE machine type."
  type        = string
  default     = "e2-small"
}

variable "disk_size_gb" {
  description = "Boot disk size in GB."
  type        = number
  default     = 30
}

variable "auto_shutdown_idle_hours" {
  description = "Auto-shutdown threshold. 0 disables."
  type        = number
  default     = 2
}

variable "install_vscode_server" {
  description = "Install code-server on the VM."
  type        = bool
  default     = true
}

variable "allowed_principals" {
  description = "IAM members granted IAP SSH + OS Login."
  type        = list(string)
  default     = []
}

variable "llm_gateway_url" {
  description = "URL of the LLM gateway (for writing the on-VM Claude Code config)."
  type        = string
  default     = ""
}

variable "mcp_gateway_url" {
  description = "URL of the MCP gateway (for writing the on-VM Claude Code config)."
  type        = string
  default     = ""
}

variable "vertex_region" {
  description = "Vertex region pinned in the on-VM Claude Code config."
  type        = string
  default     = "global"
}

variable "labels" {
  description = "Labels applied to the instance."
  type        = map(string)
  default     = {}
}
