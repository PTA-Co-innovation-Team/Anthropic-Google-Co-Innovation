variable "project_id" {
  description = "GCP project to create network resources in."
  type        = string
}

variable "region" {
  description = "Region for the subnet and any regional resources."
  type        = string
}

variable "use_psc" {
  description = "If true, provision a Private Service Connect endpoint for googleapis.com."
  type        = bool
  default     = false
}

variable "use_vpc_connector" {
  description = "If true, provision a Serverless VPC Connector for Cloud Run egress."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Resource labels applied where supported."
  type        = map(string)
  default     = {}
}
