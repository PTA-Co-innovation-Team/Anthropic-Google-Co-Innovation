variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Cloud Run region."
  type        = string
}

variable "vertex_region" {
  description = "Default Vertex region (e.g. \"global\") — passed to the container as VERTEX_DEFAULT_REGION."
  type        = string
}

variable "image" {
  description = "Full container image reference. When empty, a placeholder image is used."
  type        = string
  default     = ""
}

variable "allowed_principals" {
  description = "IAM members granted roles/run.invoker on this service."
  type        = list(string)
  default     = []
}

variable "vpc_connector_name" {
  description = "Serverless VPC Connector name (empty string disables private egress)."
  type        = string
  default     = ""
}

variable "use_vpc_connector" {
  description = "Whether to route Cloud Run egress through the VPC connector."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to the Cloud Run service."
  type        = map(string)
  default     = {}
}

variable "enable_glb" {
  description = "When true, restrict ingress to GLB and enable app-level token validation."
  type        = bool
  default     = false
}

# --- Traffic policy (optional, all empty = disabled) ------------------------
variable "rate_limit_per_min" {
  description = "Per-caller request cap, requests per minute. 0 disables. Default 0."
  type        = number
  default     = 0
}

variable "rate_limit_burst" {
  description = "Per-caller burst capacity. Defaults to rate_limit_per_min if 0."
  type        = number
  default     = 0
}

variable "token_limit_per_min" {
  description = "Per-caller LLM token cap (input + output) per minute. 0 disables. Default 0."
  type        = number
  default     = 0
}

variable "token_limit_burst" {
  description = "Per-caller token-bucket burst capacity. Defaults to token_limit_per_min if 0."
  type        = number
  default     = 0
}

variable "allowed_models" {
  description = "Comma-separated allowlist of model names (e.g. claude-sonnet-4-6,claude-haiku-4-5). Empty = no allowlist."
  type        = string
  default     = ""
}

variable "model_rewrite" {
  description = "Comma-separated model rewrite rules (e.g. claude-opus-4-6=claude-sonnet-4-6). Empty = no rewriting."
  type        = string
  default     = ""
}
