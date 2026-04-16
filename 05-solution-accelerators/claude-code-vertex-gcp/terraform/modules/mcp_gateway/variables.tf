variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Cloud Run region."
  type        = string
}

variable "image" {
  description = "Full container image reference. When empty, a placeholder is used."
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
