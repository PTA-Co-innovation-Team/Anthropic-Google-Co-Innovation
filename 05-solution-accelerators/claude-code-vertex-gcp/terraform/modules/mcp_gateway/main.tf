# =============================================================================
# MCP Gateway module.
#
# Same shape as the LLM gateway: one Cloud Run service + dedicated SA.
# The SA starts with only `logging.logWriter`; individual tools require
# additional roles granted separately (e.g., roles/storage.viewer for a
# GCS-listing tool). Least-privilege by default.
# =============================================================================

locals {
  service_name = "mcp-gateway"
  # Placeholder image when var.image is unset — lets `terraform apply`
  # succeed on a first run before a real MCP gateway image exists.
  # Replace via `scripts/deploy-mcp-gateway.sh` (which builds + pushes
  # + redeploys) or by setting var.image and re-applying. Same pattern
  # as the LLM gateway — see its main.tf for the detailed comment.
  placeholder_image = "us-docker.pkg.dev/cloudrun/container/hello"
  image             = var.image != "" ? var.image : local.placeholder_image
}

resource "google_service_account" "sa" {
  project      = var.project_id
  account_id   = "mcp-gateway"
  display_name = "MCP Gateway (shared Claude Code tools)"
  description  = "Identity the MCP gateway uses when its tools call GCP APIs."
}

resource "google_project_iam_member" "sa_logwriter" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.sa.email}"
}

resource "google_cloud_run_v2_service" "gateway" {
  project  = var.project_id
  name     = local.service_name
  location = var.region
  labels   = var.labels

  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = google_service_account.sa.email

    scaling {
      min_instance_count = 0
      max_instance_count = 5
    }

    dynamic "vpc_access" {
      for_each = var.use_vpc_connector && var.vpc_connector_name != "" ? [1] : []
      content {
        connector = "projects/${var.project_id}/locations/${var.region}/connectors/${var.vpc_connector_name}"
        egress    = "PRIVATE_RANGES_ONLY"
      }
    }

    containers {
      image = local.image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
    }
  }

  lifecycle {
    ignore_changes = [
      client,
      client_version,
    ]
  }
}

resource "google_cloud_run_v2_service_iam_member" "invokers" {
  for_each = toset(var.allowed_principals)
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.gateway.name
  role     = "roles/run.invoker"
  member   = each.value
}
