# =============================================================================
# GLB module — Global HTTP(S) Load Balancer in front of Cloud Run services.
#
# Architecture:
#   * LLM gateway + MCP gateway: GLB backends WITHOUT IAP. App-level
#     middleware validates both access tokens and OIDC tokens.
#   * Dev portal + admin dashboard: GLB backends WITH IAP. Browser OAuth flow.
#
# Cloud Run services must have ingress=internal-and-cloud-load-balancing
# and allow-unauthenticated=true when this module is active.
# =============================================================================

# --- Static IP ---------------------------------------------------------------
resource "google_compute_global_address" "glb" {
  project = var.project_id
  name    = "claude-code-glb-ip"
}

# --- Serverless NEGs (one per Cloud Run service) -----------------------------
resource "google_compute_region_network_endpoint_group" "llm_gateway" {
  count   = var.llm_gateway_service_name != "" ? 1 : 0
  project = var.project_id
  name    = "llm-gateway-neg"
  region  = var.region

  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = var.llm_gateway_service_name
  }
}

resource "google_compute_region_network_endpoint_group" "mcp_gateway" {
  count   = var.mcp_gateway_service_name != "" ? 1 : 0
  project = var.project_id
  name    = "mcp-gateway-neg"
  region  = var.region

  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = var.mcp_gateway_service_name
  }
}

resource "google_compute_region_network_endpoint_group" "dev_portal" {
  count   = var.dev_portal_service_name != "" ? 1 : 0
  project = var.project_id
  name    = "dev-portal-neg"
  region  = var.region

  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = var.dev_portal_service_name
  }
}

resource "google_compute_region_network_endpoint_group" "admin_dashboard" {
  count   = var.admin_dashboard_service_name != "" ? 1 : 0
  project = var.project_id
  name    = "admin-dashboard-neg"
  region  = var.region

  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = var.admin_dashboard_service_name
  }
}

# --- Backend services --------------------------------------------------------

# LLM gateway — NO IAP. App-level token validation accepts access tokens.
resource "google_compute_backend_service" "llm_gateway" {
  count   = var.llm_gateway_service_name != "" ? 1 : 0
  project = var.project_id
  name    = "llm-gateway-backend"

  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.llm_gateway[0].id
  }
}

# MCP gateway — NO IAP. App-level token validation.
resource "google_compute_backend_service" "mcp_gateway" {
  count   = var.mcp_gateway_service_name != "" ? 1 : 0
  project = var.project_id
  name    = "mcp-gateway-backend"

  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.mcp_gateway[0].id
  }
}

# Dev portal — WITH IAP for browser-based OAuth.
resource "google_compute_backend_service" "dev_portal" {
  count   = var.dev_portal_service_name != "" ? 1 : 0
  project = var.project_id
  name    = "dev-portal-backend"

  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.dev_portal[0].id
  }

  dynamic "iap" {
    for_each = var.iap_support_email != "" ? [1] : []
    content {
      oauth2_client_id     = google_iap_client.portal[0].client_id
      oauth2_client_secret = google_iap_client.portal[0].secret
    }
  }
}

# Admin dashboard — WITH IAP for browser-based OAuth.
resource "google_compute_backend_service" "admin_dashboard" {
  count   = var.admin_dashboard_service_name != "" ? 1 : 0
  project = var.project_id
  name    = "admin-dashboard-backend"

  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.admin_dashboard[0].id
  }

  dynamic "iap" {
    for_each = var.iap_support_email != "" ? [1] : []
    content {
      oauth2_client_id     = google_iap_client.portal[0].client_id
      oauth2_client_secret = google_iap_client.portal[0].secret
    }
  }
}

# --- IAP OAuth brand + client (for browser-facing services) ------------------
resource "google_iap_brand" "brand" {
  count             = var.iap_support_email != "" ? 1 : 0
  project           = var.project_id
  support_email     = var.iap_support_email
  application_title = "Claude Code on GCP"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_iap_client" "portal" {
  count        = var.iap_support_email != "" ? 1 : 0
  display_name = "Claude Code GLB IAP Client"
  brand        = google_iap_brand.brand[0].name
}

# IAP access for portal — grant each principal the httpsResourceAccessor role.
resource "google_iap_web_backend_service_iam_member" "portal_access" {
  for_each = var.iap_support_email != "" && var.dev_portal_service_name != "" ? toset(var.allowed_principals) : toset([])
  project  = var.project_id

  web_backend_service = google_compute_backend_service.dev_portal[0].name
  role                = "roles/iap.httpsResourceAccessor"
  member              = each.value
}

# IAP access for admin dashboard — same principals as portal.
resource "google_iap_web_backend_service_iam_member" "dashboard_access" {
  for_each = var.iap_support_email != "" && var.admin_dashboard_service_name != "" ? toset(var.allowed_principals) : toset([])
  project  = var.project_id

  web_backend_service = google_compute_backend_service.admin_dashboard[0].name
  role                = "roles/iap.httpsResourceAccessor"
  member              = each.value
}

# --- URL Map -----------------------------------------------------------------
resource "google_compute_url_map" "glb" {
  project = var.project_id
  name    = "claude-code-glb-url-map"

  # Default backend: dev portal (landing page) if deployed, else LLM gateway.
  default_service = (
    var.dev_portal_service_name != "" ? google_compute_backend_service.dev_portal[0].id
    : var.llm_gateway_service_name != "" ? google_compute_backend_service.llm_gateway[0].id
    : null
  )

  # Path matcher routes Vertex rawPredict, MCP, and health to their
  # respective backends. Unmatched paths fall through to dev-portal
  # (landing page) when deployed, otherwise to llm-gateway.
  dynamic "path_matcher" {
    for_each = var.llm_gateway_service_name != "" ? [1] : []
    content {
      name = "llm-routes"
      default_service = (
        var.dev_portal_service_name != ""
        ? google_compute_backend_service.dev_portal[0].id
        : google_compute_backend_service.llm_gateway[0].id
      )

      path_rule {
        paths   = ["/v1/*", "/v1beta1/*", "/health", "/healthz"]
        service = google_compute_backend_service.llm_gateway[0].id
      }

      dynamic "path_rule" {
        for_each = var.mcp_gateway_service_name != "" ? [1] : []
        content {
          paths   = ["/mcp", "/mcp/*"]
          service = google_compute_backend_service.mcp_gateway[0].id
        }
      }
    }
  }

  dynamic "host_rule" {
    for_each = var.llm_gateway_service_name != "" ? [1] : []
    content {
      hosts        = ["*"]
      path_matcher = "llm-routes"
    }
  }
}

# --- SSL certificate ---------------------------------------------------------
resource "google_compute_managed_ssl_certificate" "glb" {
  count   = var.domain != "" ? 1 : 0
  project = var.project_id
  name    = "claude-code-glb-cert"

  managed {
    domains = [var.domain]
  }
}

# Self-signed cert for IP-only access (no domain).
resource "google_compute_ssl_certificate" "self_signed" {
  count       = var.domain == "" ? 1 : 0
  project     = var.project_id
  name_prefix = "claude-code-glb-self-signed-"

  private_key = tls_private_key.self_signed[0].private_key_pem
  certificate = tls_self_signed_cert.self_signed[0].cert_pem

  lifecycle {
    create_before_destroy = true
  }
}

resource "tls_private_key" "self_signed" {
  count     = var.domain == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "self_signed" {
  count           = var.domain == "" ? 1 : 0
  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  subject {
    common_name  = "claude-code-glb"
    organization = "Claude Code on GCP"
  }

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# --- HTTPS proxy + forwarding rule -------------------------------------------
resource "google_compute_target_https_proxy" "glb" {
  project = var.project_id
  name    = "claude-code-glb-https-proxy"
  url_map = google_compute_url_map.glb.id

  ssl_certificates = var.domain != "" ? [
    google_compute_managed_ssl_certificate.glb[0].id
  ] : [
    google_compute_ssl_certificate.self_signed[0].id
  ]
}

resource "google_compute_global_forwarding_rule" "glb" {
  project    = var.project_id
  name       = "claude-code-glb-fwd"
  target     = google_compute_target_https_proxy.glb.id
  ip_address = google_compute_global_address.glb.address
  port_range = "443"

  load_balancing_scheme = "EXTERNAL_MANAGED"

  labels = var.labels
}
