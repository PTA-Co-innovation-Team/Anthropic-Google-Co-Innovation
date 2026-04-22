# =============================================================================
# LLM Gateway module.
#
# One Cloud Run service, one dedicated service account, IAM bindings
# granting the SA `roles/aiplatform.user`.
#
# Auth: Cloud Run's invoker IAM check is disabled because Claude Code
# sends ADC access tokens, which Cloud Run IAM rejects (it only accepts
# OIDC identity tokens). The app-level token_validation.py middleware
# handles auth instead, accepting both token types.
# =============================================================================

locals {
  service_name = "llm-gateway"

  # A Google-published placeholder used when the operator hasn't yet
  # built+pushed the real gateway image. Lets `terraform apply` succeed
  # on a first run before the image exists.
  #
  # Build-and-swap workflow (see README → Terraform deployment path):
  #   1. `terraform apply` with var.image="" creates the Cloud Run
  #      service running the `hello` placeholder.
  #   2. `scripts/deploy-llm-gateway.sh` builds + pushes the real
  #      image to Artifact Registry, then deploys a new Cloud Run
  #      revision referencing it.
  #   3. Optional: set var.image to the full AR reference in
  #      terraform.tfvars and re-apply so TF tracks the real image.
  placeholder_image = "us-docker.pkg.dev/cloudrun/container/hello"

  image = var.image != "" ? var.image : local.placeholder_image
}

# --- Dedicated service account ----------------------------------------------
resource "google_service_account" "sa" {
  project      = var.project_id
  account_id   = "llm-gateway"
  display_name = "LLM Gateway (Claude Code → Vertex AI)"
  description  = "Identity the LLM gateway uses when calling Vertex AI."
}

# --- SA IAM: Vertex caller + log writer -------------------------------------
resource "google_project_iam_member" "sa_vertex" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.sa.email}"
}

resource "google_project_iam_member" "sa_logwriter" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.sa.email}"
}

# --- Cloud Run service -------------------------------------------------------
resource "google_cloud_run_v2_service" "gateway" {
  project  = var.project_id
  name     = local.service_name
  location = var.region
  labels   = var.labels

  ingress              = var.enable_glb ? "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" : "INGRESS_TRAFFIC_ALL"
  invoker_iam_disabled = true

  template {
    service_account = google_service_account.sa.email

    scaling {
      min_instance_count = 0  # scale to zero when idle
      max_instance_count = 10 # pick a small cap; raise if you hit it
    }

    # Pipe egress through the VPC connector when enabled, so Vertex
    # traffic uses Private Google Access.
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

  # `ignore_changes` on image prevents `terraform apply` from rolling
  # back a newer image that was pushed out-of-band by the deploy script.
  # Remove this block if you want TF to be the single source of truth.
  lifecycle {
    ignore_changes = [
      client,
      client_version,
    ]
  }
}

# --- Invoker IAM is disabled on this service ---------------------------------
# Cloud Run's invoker IAM check is disabled (invoker_iam_disabled = true)
# because Claude Code sends ADC access tokens which Cloud Run IAM rejects.
# Auth is handled by the app-level token_validation.py middleware instead.
