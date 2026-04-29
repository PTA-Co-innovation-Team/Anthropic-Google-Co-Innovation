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

variable "enable_cloud_nat" {
  description = "If true, create a Cloud Router and Cloud NAT gateway so VMs without public IPs can reach non-Google internet hosts (apt repos, npm registry, etc.). Required for the dev VM startup script."
  type        = bool
  default     = false
}

variable "enable_vpc_internal" {
  description = "When true, create firewall rules for VPC-internal-only access patterns. IAP provides developer access; VPN firewall rules are available for optional advanced configurations."
  type        = bool
  default     = false
}

variable "vpn_client_cidrs" {
  description = "Optional: CIDRs for VPN clients, if VPN is used alongside IAP. Most deployments do not need this — IAP provides developer access without VPN."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Resource labels applied where supported."
  type        = map(string)
  default     = {}
}
