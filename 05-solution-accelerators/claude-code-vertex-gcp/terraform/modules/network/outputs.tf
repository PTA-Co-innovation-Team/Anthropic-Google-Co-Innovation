output "network_self_link" {
  description = "Self link of the VPC network."
  value       = google_compute_network.vpc.self_link
}

output "network_name" {
  description = "Name of the VPC network."
  value       = google_compute_network.vpc.name
}

output "subnet_self_link" {
  description = "Self link of the regional subnet."
  value       = google_compute_subnetwork.subnet.self_link
}

output "subnet_name" {
  description = "Name of the regional subnet."
  value       = google_compute_subnetwork.subnet.name
}

output "vpc_connector_name" {
  description = "Name of the Serverless VPC Connector, or empty string when disabled."
  value       = length(google_vpc_access_connector.connector) > 0 ? google_vpc_access_connector.connector[0].name : ""
}

output "vpc_connector_id" {
  description = "ID of the Serverless VPC Connector, or empty string when disabled."
  value       = length(google_vpc_access_connector.connector) > 0 ? google_vpc_access_connector.connector[0].id : ""
}

output "psc_ip_address" {
  description = "IP of the optional PSC endpoint for googleapis.com, or empty string when disabled."
  value       = length(google_compute_global_address.psc_ip) > 0 ? google_compute_global_address.psc_ip[0].address : ""
}

output "cloud_router_name" {
  description = "Name of the Cloud Router for NAT, or empty string when disabled."
  value       = length(google_compute_router.router) > 0 ? google_compute_router.router[0].name : ""
}

output "cloud_nat_name" {
  description = "Name of the Cloud NAT gateway, or empty string when disabled."
  value       = length(google_compute_router_nat.nat) > 0 ? google_compute_router_nat.nat[0].name : ""
}
