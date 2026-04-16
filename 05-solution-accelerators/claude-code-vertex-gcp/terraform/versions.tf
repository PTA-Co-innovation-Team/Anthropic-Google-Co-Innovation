# =============================================================================
# versions.tf
#
# Pin Terraform and provider versions. Pins live in the root so every
# module shares the same constraint; modules deliberately do NOT declare
# their own provider blocks — they inherit from the root.
# =============================================================================

terraform {
  # Terraform 1.6+ supports the features we rely on (import blocks,
  # test framework, moved blocks). Cap major versions for safety.
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    # Stable Google provider. 6.x is the current major at the time of
    # authoring; lower bound 6.0 keeps us on a modern API surface.
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }

    # Beta is needed for a handful of resources (e.g., IAP OAuth client
    # settings on the web-facing LB). Even modules that don't use beta
    # resources benefit from the pin being declared once here.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }

    # Used to generate unique suffixes for globally-scoped resource
    # names (Artifact Registry repos, log sink names, etc.).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Root-level provider configuration. Each module receives this
# implicitly unless it declares its own required_providers.
provider "google" {
  project = var.project_id
  # "global" and multi-region values (us, europe) are not valid GCE
  # regions, so we only pass the region to the provider when it looks
  # like a GCE region. The Cloud Run region is set per-resource.
  region = local.gce_region
}

provider "google-beta" {
  project = var.project_id
  region  = local.gce_region
}
