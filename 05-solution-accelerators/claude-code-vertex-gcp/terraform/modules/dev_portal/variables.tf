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
