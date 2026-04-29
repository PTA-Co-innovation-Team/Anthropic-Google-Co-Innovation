# =============================================================================
# Network module.
#
# Provisions:
#   * A VPC with no auto-created subnets (custom subnet below).
#   * A single regional subnet with Private Google Access ON — this is
#     what lets Cloud Run + GCE reach *.googleapis.com privately.
#   * Firewall rules permitting IAP TCP forwarding (SSH tunneling).
#   * OPTIONAL: Serverless VPC Connector for Cloud Run egress via the VPC.
#   * OPTIONAL: Private Service Connect endpoint for googleapis.com
#     (on-prem-to-GCP scenarios).
# =============================================================================

locals {
  # Short, descriptive names. Changing them breaks state; pick once and
  # leave alone.
  network_name   = "claude-code-vpc"
  subnet_name    = "claude-code-subnet"
  connector_name = "cc-run-connector" # <= 25 chars required by GCP
  subnet_cidr    = "10.100.0.0/24"
  # VPC connector needs its own /28 that does NOT overlap with the subnet.
  connector_cidr = "10.100.1.0/28"
}

# --- VPC ---------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = local.network_name
  project                 = var.project_id
  auto_create_subnetworks = false
  description             = "VPC for the Claude-Code-on-Vertex reference deployment."
}

# --- Subnet with Private Google Access ---------------------------------------
resource "google_compute_subnetwork" "subnet" {
  name                     = local.subnet_name
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = local.subnet_cidr
  description              = "Subnet with Private Google Access so workloads can reach *.googleapis.com without traversing the public internet."
  private_ip_google_access = true
}

# --- Firewall: allow IAP → SSH ---------------------------------------------
# Without this rule, gcloud compute ssh --tunnel-through-iap fails with 4003.
# IAP's source range is 35.235.240.0/20 (documented and stable).
resource "google_compute_firewall" "allow_iap_ssh" {
  name        = "allow-iap-ssh"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "Allow IAP TCP forwarding to reach instance SSH (tcp:22)."

  source_ranges = ["35.235.240.0/20"]
  direction     = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Only apply to instances tagged for dev-vm use, so general instances
  # in this VPC don't accidentally receive IAP SSH access.
  target_tags = ["claude-code-dev-vm"]
}

# --- Firewall: allow IAP → 8080 (code-server) -------------------------------
resource "google_compute_firewall" "allow_iap_web" {
  name        = "allow-iap-web"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "Allow IAP TCP forwarding to reach code-server (tcp:8080) on the dev VM."

  source_ranges = ["35.235.240.0/20"]
  direction     = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  target_tags = ["claude-code-dev-vm"]
}

# --- Serverless VPC Connector (optional) ------------------------------------
resource "google_vpc_access_connector" "connector" {
  count         = var.use_vpc_connector ? 1 : 0
  name          = local.connector_name
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = local.connector_cidr
  # Keep the connector small — our traffic is low-volume. Minimum/
  # maximum throughput controls instance counts.
  min_throughput = 200
  max_throughput = 300
}

# --- Cloud NAT (optional) ---------------------------------------------------
# Required when workloads with no public IP need to reach non-Google
# internet hosts (e.g. the dev VM startup script fetches Node.js from
# deb.nodesource.com and Claude Code from registry.npmjs.org).
# Cloud NAT provides outbound-only NAT — no inbound ports are opened.
resource "google_compute_router" "router" {
  count   = var.enable_cloud_nat ? 1 : 0
  name    = "claude-code-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  count                              = var.enable_cloud_nat ? 1 : 0
  name                               = "claude-code-nat"
  router                             = google_compute_router.router[0].name
  project                            = var.project_id
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# --- Firewall: allow VPN clients (optional, advanced) -----------------------
# Most deployments do not need this — IAP (via GLB or dev VM SSH) provides
# developer access without VPN. This rule is for organizations that also
# run a Cloud VPN or Cloud Interconnect alongside IAP.
resource "google_compute_firewall" "allow_vpn_to_services" {
  count       = var.enable_vpc_internal && length(var.vpn_client_cidrs) > 0 ? 1 : 0
  name        = "allow-vpn-to-services"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "Optional: allow VPN clients to reach Cloud Run services. Most deployments use IAP instead."

  source_ranges = var.vpn_client_cidrs
  direction     = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

# --- Private Service Connect (optional) -------------------------------------
# PSC here creates a private IP inside the VPC that resolves to the
# googleapis.com bundle. Useful only when on-prem networks connected
# via Interconnect need to reach Google APIs privately.
resource "google_compute_global_address" "psc_ip" {
  count         = var.use_psc ? 1 : 0
  project       = var.project_id
  name          = "claude-code-psc-ip"
  purpose       = "PRIVATE_SERVICE_CONNECT"
  address_type  = "INTERNAL"
  network       = google_compute_network.vpc.id
  address       = "10.100.2.0"
  prefix_length = 24
}

resource "google_compute_global_forwarding_rule" "psc_googleapis" {
  count                 = var.use_psc ? 1 : 0
  project               = var.project_id
  name                  = "claude-code-psc-googleapis"
  target                = "all-apis" # Google's bundled PSC target
  network               = google_compute_network.vpc.id
  ip_address            = google_compute_global_address.psc_ip[0].id
  load_balancing_scheme = ""
}
