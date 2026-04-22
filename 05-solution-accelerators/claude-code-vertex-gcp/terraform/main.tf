# =============================================================================
# main.tf — root composition.
#
# This file wires the per-component modules together based on the toggle
# variables. Every module call is guarded by `count = enable_* ? 1 : 0`
# so a deployment with components turned off creates nothing for them.
# =============================================================================

# -----------------------------------------------------------------------------
# Enable the Google APIs this deployment depends on. The google_project_service
# resource is idempotent, so re-applying is safe. `disable_on_destroy = false`
# keeps the APIs enabled on teardown (some orgs share projects and disabling
# would affect unrelated workloads).
# -----------------------------------------------------------------------------
locals {
  required_apis = [
    "aiplatform.googleapis.com",
    "run.googleapis.com",
    "compute.googleapis.com",
    "iap.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "iamcredentials.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "bigquery.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each                   = toset(local.required_apis)
  project                    = var.project_id
  service                    = each.value
  disable_dependent_services = false
  disable_on_destroy         = false
}

# -----------------------------------------------------------------------------
# Artifact Registry repo that holds gateway + portal container images.
# -----------------------------------------------------------------------------
resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = local.gce_region
  repository_id = "claude-code-vertex-gcp"
  description   = "Container images for the Claude-Code-on-Vertex reference deployment."
  format        = "DOCKER"
  labels        = local.labels

  depends_on = [google_project_service.apis]
}

# -----------------------------------------------------------------------------
# Network — VPC, subnet, Private Google Access, optional PSC + VPC connector.
# Every other module consumes networking outputs from here.
# -----------------------------------------------------------------------------
module "network" {
  source = "./modules/network"

  project_id        = var.project_id
  region            = local.gce_region
  use_psc           = var.use_psc
  use_vpc_connector = var.use_vpc_connector
  labels            = local.labels

  depends_on = [google_project_service.apis]
}

# -----------------------------------------------------------------------------
# LLM Gateway (Cloud Run).
# -----------------------------------------------------------------------------
module "llm_gateway" {
  count  = var.enable_llm_gateway ? 1 : 0
  source = "./modules/llm_gateway"

  project_id         = var.project_id
  region             = local.gce_region
  vertex_region      = var.region
  image              = var.llm_gateway_image
  allowed_principals = local.gateway_allowed_principals
  vpc_connector_name = module.network.vpc_connector_name
  use_vpc_connector  = var.use_vpc_connector
  enable_glb         = var.enable_glb
  labels             = local.labels

  depends_on = [google_artifact_registry_repository.images]
}

# -----------------------------------------------------------------------------
# MCP Gateway (Cloud Run).
# -----------------------------------------------------------------------------
module "mcp_gateway" {
  count  = var.enable_mcp_gateway ? 1 : 0
  source = "./modules/mcp_gateway"

  project_id         = var.project_id
  region             = local.gce_region
  vertex_region      = var.region
  image              = var.mcp_gateway_image
  allowed_principals = local.gateway_allowed_principals
  vpc_connector_name = module.network.vpc_connector_name
  use_vpc_connector  = var.use_vpc_connector
  enable_glb         = var.enable_glb
  labels             = local.labels

  depends_on = [google_artifact_registry_repository.images]
}

# -----------------------------------------------------------------------------
# Dev Portal (Cloud Run static page).
# -----------------------------------------------------------------------------
module "dev_portal" {
  count  = var.enable_dev_portal ? 1 : 0
  source = "./modules/dev_portal"

  project_id         = var.project_id
  region             = local.gce_region
  image              = var.dev_portal_image
  allowed_principals = var.allowed_principals
  enable_glb         = var.enable_glb
  labels             = local.labels

  depends_on = [google_artifact_registry_repository.images]
}

# -----------------------------------------------------------------------------
# Dev VM (GCE + IAP).
# -----------------------------------------------------------------------------
module "dev_vm" {
  count  = var.enable_dev_vm ? 1 : 0
  source = "./modules/dev_vm"

  project_id               = var.project_id
  region                   = local.gce_region
  zone                     = "${local.gce_region}-a"
  network_self_link        = module.network.network_self_link
  subnet_self_link         = module.network.subnet_self_link
  mode                     = var.dev_vm_mode
  machine_type             = var.dev_vm_machine_type
  disk_size_gb             = var.dev_vm_disk_size_gb
  auto_shutdown_idle_hours = var.dev_vm_auto_shutdown_idle_hours
  install_vscode_server    = var.dev_vm_install_vscode_server
  allowed_principals       = var.allowed_principals
  llm_gateway_url = (
    var.enable_glb && length(module.glb) > 0
    ? module.glb[0].glb_url
    : var.enable_llm_gateway ? module.llm_gateway[0].service_url : ""
  )
  mcp_gateway_url = (
    var.enable_glb && length(module.glb) > 0
    ? module.glb[0].glb_url
    : var.enable_mcp_gateway ? module.mcp_gateway[0].service_url : ""
  )
  vertex_region            = var.region
  labels                   = local.labels
}

# -----------------------------------------------------------------------------
# Observability (log sink → BigQuery).
# -----------------------------------------------------------------------------
module "observability" {
  count  = var.enable_observability ? 1 : 0
  source = "./modules/observability"

  project_id = var.project_id
  region     = local.gce_region
  labels     = local.labels

  depends_on = [google_project_service.apis]
}

# -----------------------------------------------------------------------------
# Global Load Balancer (optional).
# -----------------------------------------------------------------------------
module "glb" {
  count  = var.enable_glb ? 1 : 0
  source = "./modules/glb"

  project_id               = var.project_id
  region                   = local.gce_region
  domain                   = var.glb_domain
  iap_support_email        = var.iap_support_email
  allowed_principals       = var.allowed_principals
  llm_gateway_service_name      = var.enable_llm_gateway ? module.llm_gateway[0].service_name : ""
  mcp_gateway_service_name      = var.enable_mcp_gateway ? module.mcp_gateway[0].service_name : ""
  dev_portal_service_name       = var.enable_dev_portal ? module.dev_portal[0].service_name : ""
  admin_dashboard_service_name  = var.admin_dashboard_service_name
  labels                        = local.labels

  depends_on = [module.llm_gateway, module.mcp_gateway, module.dev_portal]
}
