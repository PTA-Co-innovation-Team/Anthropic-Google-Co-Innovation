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

  ingress = (
    var.enable_glb          ? "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" :
    var.enable_vpc_internal ? "INGRESS_TRAFFIC_INTERNAL_ONLY" :
                              "INGRESS_TRAFFIC_ALL"
  )
  invoker_iam_disabled = true

  template {
    service_account = google_service_account.sa.email

    scaling {
      min_instance_count = 0
      max_instance_count = 5
    }

    dynamic "vpc_access" {
      for_each = (var.use_vpc_connector || var.enable_vpc_internal) && var.vpc_connector_name != "" ? [1] : []
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
      env {
        name  = "VERTEX_DEFAULT_REGION"
        value = var.vertex_region
      }

      env {
        name  = "ENABLE_TOKEN_VALIDATION"
        value = "1"
      }
      env {
        name  = "ALLOWED_PRINCIPALS"
        value = join(",", var.allowed_principals)
      }

      startup_probe {
        http_get {
          path = "/health"
        }
        initial_delay_seconds = 2
        period_seconds        = 5
        failure_threshold     = 3
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

# Invoker IAM is disabled (invoker_iam_disabled = true). Auth is handled
# by the app-level token_validation.py middleware instead.
