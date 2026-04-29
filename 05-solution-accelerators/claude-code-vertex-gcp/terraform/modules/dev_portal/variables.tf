variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Cloud Run region."
  type        = string
}

variable "image" {
  description = "Full container image reference (static site image). Placeholder if empty."
  type        = string
  default     = ""
}

variable "allowed_principals" {
  description = "IAM members granted roles/run.invoker on the portal."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Labels applied to the Cloud Run service."
  type        = map(string)
  default     = {}
}

variable "enable_glb" {
  description = "When true, restrict ingress to GLB and allow unauthenticated (IAP is the auth boundary)."
  type        = bool
  default     = false
}

variable "enable_vpc_internal" {
  description = "When true, restrict ingress to VPC-internal only (developers access via dev VM + IAP SSH tunneling; no VPN required)."
  type        = bool
  default     = false
}
