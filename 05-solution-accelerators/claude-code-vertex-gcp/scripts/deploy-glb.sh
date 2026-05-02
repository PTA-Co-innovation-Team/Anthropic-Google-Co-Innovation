#!/usr/bin/env bash
# =============================================================================
# deploy-glb.sh
#
# Creates a Global HTTP(S) Load Balancer in front of Cloud Run services.
#
# Architecture:
#   * LLM gateway + MCP gateway: GLB backends WITHOUT IAP.
#     App-level middleware validates access tokens + OIDC tokens.
#   * Dev portal + admin dashboard: GLB backends WITH IAP.
#     Browser-based OAuth flow.
#
# Reads from environment (populated by deploy.sh):
#   PROJECT_ID, FALLBACK_REGION, GLB_DOMAIN, IAP_SUPPORT_EMAIL, PRINCIPALS
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

print_help() {
  cat <<'HELP'
Usage: deploy-glb.sh [--help] [--dry-run]

Creates the Global HTTP(S) Load Balancer. Reads PROJECT_ID, FALLBACK_REGION,
GLB_DOMAIN, IAP_SUPPORT_EMAIL, and PRINCIPALS from the environment.
HELP
}

parse_common_flags "$@"

: "${PROJECT_ID:?PROJECT_ID must be set}"
: "${FALLBACK_REGION:?FALLBACK_REGION must be set}"
: "${GLB_DOMAIN:=}"
: "${IAP_SUPPORT_EMAIL:=}"
: "${PRINCIPALS:=}"

require_cmd gcloud

CR_REGION="${FALLBACK_REGION}"

# --- Static IP ---------------------------------------------------------------
log_step "ensure static IP"
if ! gcloud compute addresses describe claude-code-glb-ip --global \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
  run_cmd gcloud compute addresses create claude-code-glb-ip --global \
    --project "${PROJECT_ID}"
fi
GLB_IP="$(gcloud compute addresses describe claude-code-glb-ip --global \
  --project "${PROJECT_ID}" --format="value(address)" 2>/dev/null || echo "<pending>")"
log_info "GLB IP: ${GLB_IP}"

# --- DNS record (managed cert only) ------------------------------------------
_dns_zone=""
if [[ -n "${GLB_DOMAIN}" ]]; then
  log_step "ensure DNS A record for ${GLB_DOMAIN}"

  _parent_domain="${GLB_DOMAIN#*.}"

  _dns_zone="$(gcloud dns managed-zones list --project "${PROJECT_ID}" \
    --filter="dnsName=${_parent_domain}." \
    --format="value(name)" 2>/dev/null | head -1 || echo "")"

  if [[ -n "${_dns_zone}" ]]; then
    _existing="$(gcloud dns record-sets describe "${GLB_DOMAIN}." \
      --zone="${_dns_zone}" --type=A --project "${PROJECT_ID}" \
      --format="value(rrdatas[0])" 2>/dev/null || echo "")"

    if [[ "${_existing}" == "${GLB_IP}" ]]; then
      log_info "DNS A record already points to ${GLB_IP}"
    elif [[ -n "${_existing}" ]]; then
      log_info "updating DNS A record from ${_existing} to ${GLB_IP}"
      run_cmd gcloud dns record-sets update "${GLB_DOMAIN}." \
        --zone="${_dns_zone}" --type=A --ttl=300 \
        --rrdatas="${GLB_IP}" --project "${PROJECT_ID}"
    else
      run_cmd gcloud dns record-sets create "${GLB_DOMAIN}." \
        --zone="${_dns_zone}" --type=A --ttl=300 \
        --rrdatas="${GLB_IP}" --project "${PROJECT_ID}"
    fi
  else
    log_warn "no Cloud DNS zone found for ${_parent_domain} in this project"
    log_warn "create the A record manually: ${GLB_DOMAIN} → ${GLB_IP}"
  fi
fi

# --- Serverless NEGs ---------------------------------------------------------
log_step "create serverless NEGs"
for svc in llm-gateway mcp-gateway dev-portal admin-dashboard; do
  neg_name="${svc}-neg"
  if gcloud run services describe "${svc}" --project "${PROJECT_ID}" \
     --region "${CR_REGION}" >/dev/null 2>&1; then
    if ! gcloud compute network-endpoint-groups describe "${neg_name}" \
         --region "${CR_REGION}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
      run_cmd gcloud compute network-endpoint-groups create "${neg_name}" \
        --project "${PROJECT_ID}" --region "${CR_REGION}" \
        --network-endpoint-type=serverless \
        --cloud-run-service="${svc}"
    else
      log_info "NEG ${neg_name} already exists"
    fi
  else
    log_info "service ${svc} not deployed — skipping NEG"
  fi
done

# --- Backend services --------------------------------------------------------
log_step "create backend services"

_create_backend() {
  local name="$1" neg="$2"
  if ! gcloud compute backend-services describe "${name}" --global \
       --project "${PROJECT_ID}" >/dev/null 2>&1; then
    run_cmd gcloud compute backend-services create "${name}" \
      --project "${PROJECT_ID}" --global \
      --load-balancing-scheme=EXTERNAL_MANAGED
    run_cmd gcloud compute backend-services add-backend "${name}" \
      --project "${PROJECT_ID}" --global \
      --network-endpoint-group="${neg}" \
      --network-endpoint-group-region="${CR_REGION}"
  else
    log_info "backend ${name} already exists"
  fi
}

for svc in llm-gateway mcp-gateway dev-portal admin-dashboard; do
  neg_name="${svc}-neg"
  backend_name="${svc}-backend"
  if gcloud compute network-endpoint-groups describe "${neg_name}" \
     --region "${CR_REGION}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
    _create_backend "${backend_name}" "${neg_name}"
  fi
done

# --- URL map -----------------------------------------------------------------
log_step "create URL map"
if ! gcloud compute url-maps describe claude-code-glb-url-map --global \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then

  # Determine default backend (dev-portal landing page, else llm-gateway).
  if gcloud compute backend-services describe dev-portal-backend --global \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
    DEFAULT_BACKEND="dev-portal-backend"
  else
    DEFAULT_BACKEND="llm-gateway-backend"
  fi

  run_cmd gcloud compute url-maps create claude-code-glb-url-map \
    --project "${PROJECT_ID}" --global \
    --default-service="${DEFAULT_BACKEND}"

  # Single path matcher with all routes. Matches Terraform's URL map structure:
  #   /v1/*, /v1beta1/*, /health, /healthz → llm-gateway
  #   /mcp, /mcp/* → mcp-gateway (if deployed)
  #   /* (default) → dev-portal (or llm-gateway if no portal)
  if gcloud compute backend-services describe llm-gateway-backend --global \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
    PATH_RULES="/v1/*=llm-gateway-backend,/v1beta1/*=llm-gateway-backend,/health=llm-gateway-backend,/healthz=llm-gateway-backend"

    if gcloud compute backend-services describe mcp-gateway-backend --global \
       --project "${PROJECT_ID}" >/dev/null 2>&1; then
      PATH_RULES="${PATH_RULES},/mcp=mcp-gateway-backend,/mcp/*=mcp-gateway-backend"
    fi

    run_cmd gcloud compute url-maps add-path-matcher claude-code-glb-url-map \
      --project "${PROJECT_ID}" --global \
      --path-matcher-name=llm-routes \
      --default-service="${DEFAULT_BACKEND}" \
      --new-hosts="*" \
      --path-rules="${PATH_RULES}"
  fi
else
  log_info "URL map already exists"
fi

# --- SSL certificate ---------------------------------------------------------
log_step "ensure SSL certificate"
if [[ -n "${GLB_DOMAIN}" ]]; then
  if ! gcloud compute ssl-certificates describe claude-code-glb-cert --global \
       --project "${PROJECT_ID}" >/dev/null 2>&1; then
    run_cmd gcloud compute ssl-certificates create claude-code-glb-cert \
      --project "${PROJECT_ID}" --global \
      --domains="${GLB_DOMAIN}"
  fi
  CERT_NAME="claude-code-glb-cert"
else
  log_info "no domain — generating self-signed cert for IP-only access"
  CERT_PREFIX="claude-code-glb-self-signed"

  # Check if a self-signed cert already exists.
  EXISTING_CERT="$(gcloud compute ssl-certificates list --project "${PROJECT_ID}" \
    --filter="name~${CERT_PREFIX}" --format="value(name)" 2>/dev/null | head -1 || true)"

  if [[ -n "${EXISTING_CERT}" ]]; then
    log_info "self-signed cert ${EXISTING_CERT} already exists"
    CERT_NAME="${EXISTING_CERT}"
  else
    require_cmd openssl
    TMPDIR_CERT="$(mktemp -d)"
    trap 'rm -rf "${TMPDIR_CERT}"' EXIT

    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${TMPDIR_CERT}/key.pem" \
      -out "${TMPDIR_CERT}/cert.pem" \
      -days 365 \
      -subj "/CN=claude-code-glb/O=Claude Code on GCP" \
      2>/dev/null

    CERT_NAME="${CERT_PREFIX}-$(date +%Y%m%d)"
    run_cmd gcloud compute ssl-certificates create "${CERT_NAME}" \
      --project "${PROJECT_ID}" --global \
      --certificate="${TMPDIR_CERT}/cert.pem" \
      --private-key="${TMPDIR_CERT}/key.pem"

    rm -rf "${TMPDIR_CERT}"
    trap - EXIT
  fi
fi

# --- HTTPS proxy + forwarding rule -------------------------------------------
log_step "create HTTPS proxy and forwarding rule"
if ! gcloud compute target-https-proxies describe claude-code-glb-https-proxy --global \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
  if [[ -n "${CERT_NAME}" ]]; then
    run_cmd gcloud compute target-https-proxies create claude-code-glb-https-proxy \
      --project "${PROJECT_ID}" --global \
      --url-map=claude-code-glb-url-map \
      --ssl-certificates="${CERT_NAME}"
  else
    log_warn "skipping HTTPS proxy — no SSL certificate available (provide --glb-domain)"
  fi
fi

if ! gcloud compute forwarding-rules describe claude-code-glb-fwd --global \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
  if gcloud compute target-https-proxies describe claude-code-glb-https-proxy --global \
     --project "${PROJECT_ID}" >/dev/null 2>&1; then
    run_cmd gcloud compute forwarding-rules create claude-code-glb-fwd \
      --project "${PROJECT_ID}" --global \
      --address=claude-code-glb-ip \
      --target-https-proxy=claude-code-glb-https-proxy \
      --ports=443 \
      --load-balancing-scheme=EXTERNAL_MANAGED
  fi
fi

# --- IAP (for browser-facing services) ---------------------------------------
if [[ -n "${IAP_SUPPORT_EMAIL}" ]]; then
  log_step "configure IAP for browser services"

  # Ensure OAuth consent screen (IAP brand) exists. Only one per project.
  PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || echo "")"
  if [[ -z "${PROJECT_NUMBER}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      PROJECT_NUMBER="000000000000"
      log_warn "could not resolve project number (dry-run) — using placeholder"
    else
      log_error "could not resolve project number for ${PROJECT_ID}"
      exit 1
    fi
  fi
  BRAND_NAME="projects/${PROJECT_NUMBER}/brands/${PROJECT_NUMBER}"

  if ! gcloud iap oauth-brands describe "${BRAND_NAME}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
    log_info "creating IAP OAuth brand (consent screen)"
    if ! gcloud iap oauth-brands create \
         --project "${PROJECT_ID}" \
         --application_title="Claude Code on GCP" \
         --support_email="${IAP_SUPPORT_EMAIL}" 2>&1; then
      log_error "IAP brand creation FAILED."
      log_error "  Most likely cause: this project has Cloud Identity / Workspace org policies"
      log_error "  that prevent programmatic OAuth consent screen creation. Manual fix:"
      log_error "    1. Open https://console.cloud.google.com/apis/credentials/consent?project=${PROJECT_ID}"
      log_error "    2. Pick user type Internal (Workspace) or External (Gmail)."
      log_error "    3. App name: 'Claude Code on GCP', support email: ${IAP_SUPPORT_EMAIL}."
      log_error "    4. Save, then re-run scripts/deploy-glb.sh."
      exit 1
    fi
  else
    log_info "IAP OAuth brand already exists"
  fi

  # Create IAP OAuth client if needed.
  IAP_CLIENT_ID=""
  IAP_CLIENT_SECRET=""
  EXISTING_CLIENT="$(gcloud iap oauth-clients list "${BRAND_NAME}" \
    --project "${PROJECT_ID}" --format='value(name)' 2>/dev/null | head -1 || true)"

  if [[ -z "${EXISTING_CLIENT}" ]]; then
    log_info "creating IAP OAuth client"
    if ! CLIENT_OUTPUT="$(gcloud iap oauth-clients create "${BRAND_NAME}" \
         --project "${PROJECT_ID}" \
         --display_name="Claude Code GLB IAP Client" \
         --format='value(name,secret)' 2>&1)"; then
      log_error "IAP client creation FAILED:"
      log_error "  ${CLIENT_OUTPUT}"
      log_error "  Verify the brand exists at https://console.cloud.google.com/apis/credentials?project=${PROJECT_ID}"
      log_error "  and that your account holds roles/iap.admin on the project."
      exit 1
    fi

    if [[ -n "${CLIENT_OUTPUT}" ]]; then
      # gcloud returns the full resource path as the name field:
      #   projects/NUM/brands/NUM/identityAwareProxyClients/CLIENT_ID
      # Extract just the OAuth client ID (last path segment).
      _raw_name="$(echo "${CLIENT_OUTPUT}" | cut -f1)"
      IAP_CLIENT_ID="${_raw_name##*/}"
      IAP_CLIENT_SECRET="$(echo "${CLIENT_OUTPUT}" | cut -f2)"
    fi
  else
    log_info "IAP OAuth client already exists"
  fi

  # Enable IAP on dev-portal and admin-dashboard backends.
  for backend in dev-portal-backend admin-dashboard-backend; do
    if gcloud compute backend-services describe "${backend}" --global \
       --project "${PROJECT_ID}" >/dev/null 2>&1; then
      if [[ -n "${IAP_CLIENT_ID}" && -n "${IAP_CLIENT_SECRET}" ]]; then
        run_cmd gcloud compute backend-services update "${backend}" \
          --project "${PROJECT_ID}" --global \
          --iap=enabled,oauth2-client-id="${IAP_CLIENT_ID}",oauth2-client-secret="${IAP_CLIENT_SECRET}" || \
          log_warn "IAP enable for ${backend} may require manual Console setup"
      else
        run_cmd gcloud iap web enable --resource-type=backend-services \
          --service="${backend}" --project "${PROJECT_ID}" || \
          log_warn "IAP enable for ${backend} may require manual Console setup"
      fi
    fi
  done

  # Grant IAP access to principals.
  if [[ -n "${PRINCIPALS}" ]]; then
    IFS=',' read -ra _principals <<<"${PRINCIPALS}"
    for p in "${_principals[@]}"; do
      p="${p## }"; p="${p%% }"
      [[ -z "${p}" ]] && continue
      for backend in dev-portal-backend admin-dashboard-backend; do
        if gcloud compute backend-services describe "${backend}" --global \
           --project "${PROJECT_ID}" >/dev/null 2>&1; then
          run_cmd gcloud iap web add-iam-policy-binding \
            --resource-type=backend-services --service="${backend}" \
            --project "${PROJECT_ID}" \
            --member="${p}" --role="roles/iap.httpsResourceAccessor" --quiet || true
        fi
      done
    done
  fi
fi

# --- Summary -----------------------------------------------------------------
if [[ -n "${GLB_DOMAIN}" ]]; then
  log_info "GLB URL: https://${GLB_DOMAIN}"
  if [[ -n "${_dns_zone}" ]]; then
    log_info "DNS A record created in zone ${_dns_zone}: ${GLB_DOMAIN} → ${GLB_IP}"
  else
    echo "" >&2
    echo "  REQUIRED: Create a DNS A record:" >&2
    echo "    ${GLB_DOMAIN}  →  A  →  ${GLB_IP}" >&2
    echo "" >&2
  fi
  log_info "Google-managed cert provisions ~15 min after DNS propagates"
  log_info "check status: gcloud compute ssl-certificates describe claude-code-glb-cert --global"
else
  log_info "GLB IP: ${GLB_IP} (self-signed cert)"
  log_info "developer-setup.sh will set NODE_TLS_REJECT_UNAUTHORIZED=0 automatically"
  log_info "to switch to a trusted cert later, re-run deploy.sh and choose option 1 (managed cert)"
fi
