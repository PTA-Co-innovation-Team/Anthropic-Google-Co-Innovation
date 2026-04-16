# =============================================================================
# Dev VM module.
#
# One GCE VM with no external IP. Reached via IAP TCP tunneling. The
# startup.sh.tpl script installs Claude Code + optional code-server and
# configures auto-shutdown. IAM grants the allowed principals OS Login +
# IAP tunnel access so they can SSH in as their own Google identities.
#
# For mode="shared" we create one VM. For mode="per_user" we create one
# VM per principal in allowed_principals, named after the local-part of
# the email.
# =============================================================================

locals {
  # Per-user mode parses the local-part of "user:[email protected]" entries
  # from allowed_principals. Only "user:" members are usable — group:
  # and serviceAccount: members can't be mapped 1:1 to a dedicated VM.
  #
  # Parsing is done with try(...) + regexall so a malformed entry
  # (e.g. "user:" with no email, or a "user:name" missing @) yields
  # an empty string that the downstream filter drops, rather than
  # aborting the whole plan with a regex error.
  _user_locals = [
    for p in var.allowed_principals :
    try(regexall("^user:([^@]+)@", p)[0][0], "")
    if startswith(p, "user:")
  ]

  # In shared mode this is ["shared"]; in per_user it's the list of
  # local-parts normalized to RFC-1123-safe characters (a-z0-9-).
  instance_keys = (
    var.mode == "shared"
    ? ["shared"]
    : [
      for local_part in local._user_locals :
      replace(lower(local_part), "/[^a-z0-9-]/", "-")
      if local_part != ""
    ]
  )

  startup_script_common = templatefile("${path.module}/startup.sh.tpl", {
    project_id               = var.project_id
    vertex_region            = var.vertex_region
    llm_gateway_url          = var.llm_gateway_url
    mcp_gateway_url          = var.mcp_gateway_url
    install_vscode_server    = tostring(var.install_vscode_server)
    auto_shutdown_idle_hours = tostring(var.auto_shutdown_idle_hours)
  })
}

# --- Input validation guard -------------------------------------------------
# A precondition on the google_compute_instance.vm resource below would be
# VACUOUS when for_each produces an empty set (no instances = no checks
# run), so we hang the per_user-mode validation off a terraform_data
# resource which ALWAYS exists. This forces Terraform to surface a loud
# error when mode=per_user yields zero usable entries, rather than
# silently creating no VMs.
resource "terraform_data" "validate_instance_keys" {
  lifecycle {
    precondition {
      condition     = var.mode == "shared" || length(local.instance_keys) > 0
      error_message = "dev_vm_mode = \"per_user\" requires at least one user: entry in allowed_principals. group: and serviceAccount: members are ignored in per_user mode; use shared mode if you need them."
    }
  }
}

# --- Dedicated service account for the VM -----------------------------------
resource "google_service_account" "sa" {
  project      = var.project_id
  account_id   = "claude-code-dev-vm"
  display_name = "Claude Code Dev VM"
  description  = "Identity used by the dev VM. Needs roles/aiplatform.user so developers on the VM can call Vertex."
}

# The VM itself calls Vertex, so it gets aiplatform.user.
resource "google_project_iam_member" "sa_vertex" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.sa.email}"
}

# And log writing, for startup-script diagnostics.
resource "google_project_iam_member" "sa_logwriter" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.sa.email}"
}

# --- The VM(s) ---------------------------------------------------------------
resource "google_compute_instance" "vm" {
  for_each     = toset(local.instance_keys)
  project      = var.project_id
  name         = "claude-code-dev-${each.key}"
  zone         = var.zone
  machine_type = var.machine_type
  labels       = var.labels
  tags         = ["claude-code-dev-vm"]


  boot_disk {
    initialize_params {
      image = "projects/debian-cloud/global/images/family/debian-12"
      size  = var.disk_size_gb
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = var.subnet_self_link
    # Deliberately no `access_config` block — no public IP.
  }

  service_account {
    email = google_service_account.sa.email
    # cloud-platform is a broad scope; narrow if your policy requires.
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    # OS Login so developers SSH in with their own Google identity.
    enable-oslogin = "TRUE"
  }

  metadata_startup_script = local.startup_script_common

  # Changing the machine_type shouldn't recreate the VM; the shielded-
  # VM defaults do, though, so we lock them here.
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    ignore_changes = [
      # The VM can be updated out-of-band (image families change); don't
      # churn on those.
      boot_disk[0].initialize_params[0].image,
    ]
  }
}

# --- IAM: IAP tunnel + OS Login for allowed principals ----------------------
resource "google_project_iam_member" "iap_tunnel" {
  for_each = toset(var.allowed_principals)
  project  = var.project_id
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value
}

resource "google_project_iam_member" "oslogin" {
  for_each = toset(var.allowed_principals)
  project  = var.project_id
  role     = "roles/compute.osLogin"
  member   = each.value
}
