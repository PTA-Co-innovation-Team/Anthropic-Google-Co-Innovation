# =============================================================================
# Dev Portal module.
#
# Cloud Run service serving the static welcome page. Ingress is
# internal-and-cloud-load-balancing; IAM gates invocation to the
# allowed_principals list.
# =============================================================================

locals {
  service_name      = "dev-portal"
  placeholder_image = "us-docker.pkg.dev/cloudrun/container/hello"
  image             = var.image != "" ? var.image : local.placeholder_image
}

resource "google_service_account" "sa" {
  project      = var.project_id
  account_id   = "dev-portal"
  display_name = "Dev Portal (static welcome page)"
  description  = "Runs the dev portal Cloud Run service. Needs no GCP API access."
}

resource "google_cloud_run_v2_service" "portal" {
  project  = var.project_id
  name     = local.service_name
  location = var.region
  labels   = var.labels

  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = google_service_account.sa.email

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    containers {
      image = local.image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "256Mi"
        }
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
  name     = google_cloud_run_v2_service.portal.name
  role     = "roles/run.invoker"
  member   = each.value
}
