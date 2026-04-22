# Troubleshooting

Common problems and their fixes. If you hit something not listed here, open
an issue with the full error text and the output of
`gcloud config list --format=json`.

---

## Table of contents

- [Deployment issues](#deployment-issues)
  - [Billing is not enabled for this project](#billing-is-not-enabled-for-this-project)
  - [Terraform says `Error acquiring the state lock`](#terraform-says-error-acquiring-the-state-lock)
  - [Dev VM is missing after `deploy.sh` completed](#dev-vm-is-missing-after-deploysh-completed)
  - [Deploy script fails in dry-run mode](#deploy-script-fails-in-dry-run-mode)
  - [Portal shows placeholder URLs instead of real gateway URLs](#portal-shows-placeholder-urls-instead-of-real-gateway-urls)
- [Authentication issues](#authentication-issues)
  - [`gcloud` auth issues during setup](#gcloud-auth-issues-during-setup)
  - [Cloud Run 403 when Claude Code calls the gateway](#cloud-run-403-when-claude-code-calls-the-gateway)
  - [Cloud Run 401 / ADC token not sent](#cloud-run-401--adc-token-not-sent)
  - [IAP tunnel refuses to connect](#iap-tunnel-refuses-to-connect)
- [Runtime issues](#runtime-issues)
  - [Header rejection: `Unknown beta header: <name>`](#header-rejection-unknown-beta-header-name)
  - [HTTP 429: quota exceeded](#http-429-quota-exceeded)
  - ["Model not available in region"](#model-not-available-in-region)
  - [Gateway returns 502 upstream_unavailable](#gateway-returns-502-upstream_unavailable)
- [GLB-specific issues](#glb-specific-issues)
  - [GLB returns 404 for all requests](#glb-returns-404-for-all-requests)
  - [SSL certificate stuck in PROVISIONING](#ssl-certificate-stuck-in-provisioning)
  - [Direct Cloud Run URL works but GLB URL doesn't](#direct-cloud-run-url-works-but-glb-url-doesnt)
  - [IAP login loop on dev portal or admin dashboard](#iap-login-loop-on-dev-portal-or-admin-dashboard)
  - [Token validation rejects a valid identity](#token-validation-rejects-a-valid-identity)
  - [GLB auto-discovery fails](#glb-auto-discovery-fails)
- [Observability issues](#observability-issues)
  - [Admin dashboard shows no data](#admin-dashboard-shows-no-data)
  - [BigQuery dataset exists but table is empty](#bigquery-dataset-exists-but-table-is-empty)
- [MCP gateway issues](#mcp-gateway-issues)
  - [MCP tool invocation fails with handshake error](#mcp-tool-invocation-fails-with-handshake-error)
  - [MCP works directly but fails through GLB](#mcp-works-directly-but-fails-through-glb)
- [Test failures (`scripts/e2e-test.sh`)](#test-failures-scriptse2e-testsh)
- [GLB validation failures (`scripts/validate-glb-demo.sh`)](#glb-validation-failures-scriptsvalidate-glb-demosh)
- [Diagnostics toolkit](#diagnostics-toolkit)
- [Still stuck?](#still-stuck)

---

## Deployment issues

### "Billing is not enabled for this project"

**Symptom.** `aiplatform.googleapis.com` or `run.googleapis.com` enablement
fails during deploy with a billing error.

**Fix.**
1. Go to https://console.cloud.google.com/billing
2. Link a billing account to the project.
3. Re-run `deploy.sh`.

---

### Terraform says `Error acquiring the state lock`

**Symptom.** A previous `terraform apply` was interrupted.

**Fix.** If you're **sure** no other apply is running:
```bash
terraform force-unlock <LOCK_ID>
```
The lock ID is shown in the error message.

---

### Dev VM is missing after `deploy.sh` completed

**Symptom.** `config.yaml` has `components.dev_vm: true` and the main
`deploy.sh` ran without visible errors, but `gcloud compute instances list`
shows no `claude-code-dev-shared` instance and the service account
`claude-code-dev-vm@<project>.iam.gserviceaccount.com` does not exist.

**Cause.** `scripts/deploy-dev-vm.sh` was either skipped by the orchestrator
or failed partway through (most commonly: a transient auth/proxy error or
the user pressed Ctrl+C mid-run). Because the step creates the service
account first, a missing SA is a reliable indicator the script did not
complete.

**Fix.** Run `deploy-dev-vm.sh` standalone. It is idempotent — any resources
that already exist (IAM bindings, firewall rule) are detected and skipped.

```bash
PROJECT_ID=<your-project> \
REGION=<vertex-region> \
FALLBACK_REGION=<cloud-run-region> \
PRINCIPALS=user:<[email protected]> \
bash scripts/deploy-dev-vm.sh
```

`PROJECT_ID`, `REGION`, and `FALLBACK_REGION` must match the values in your
`config.yaml`. `PRINCIPALS` is a comma-separated list of IAM members who
should be granted `roles/iap.tunnelResourceAccessor` and
`roles/compute.osLogin` so they can SSH in via IAP.

In GLB mode, also set `ENABLE_GLB=true` so the startup script bakes the
GLB URL into the VM's Claude Code settings instead of the (unreachable)
direct Cloud Run URL.

**Verify.** The script prints an SSH command at the end; run it:
```bash
gcloud compute ssh --tunnel-through-iap \
  --project=<your-project> --zone=<region>-a claude-code-dev-shared
```
The first boot's startup log (installs Node.js, Claude Code, settings)
is at `/var/log/claude-code-bootstrap.log` on the VM.

---

### Deploy script fails in dry-run mode

**Symptom.** Running `deploy.sh --dry-run` with a fake project ID crashes
with an error like `could not resolve project number`.

**Cause.** Some gcloud commands (like `gcloud projects describe`) fail when
the project doesn't exist. The scripts guard these calls in dry-run mode
with placeholder values. If you see this error, the guard may be missing
for a specific command.

**Fix.** This was fixed in `deploy-glb.sh` (the `gcloud projects describe`
call for the IAP brand now uses placeholder `000000000000` in dry-run mode).
If you hit a similar issue elsewhere, report it as a bug. As a workaround,
use a real project ID even in dry-run mode — dry-run only skips
side-effecting commands (`run_cmd`), not read-only queries.

---

### Portal shows placeholder URLs instead of real gateway URLs

**Symptom.** The dev portal page shows literal `__LLM_GATEWAY_URL__` or
`__MCP_GATEWAY_URL__` text instead of real URLs.

**Cause.** The `deploy-dev-portal.sh` script uses `sed` to replace
placeholders in the HTML before building the container. If the gateway
services weren't deployed yet (or couldn't be discovered), the replacement
uses empty strings.

**Fix.**
1. Make sure the LLM and MCP gateways are deployed first.
2. Re-run `scripts/deploy-dev-portal.sh` — it re-discovers the URLs and
   rebuilds the container.
3. In GLB mode, the portal is automatically re-deployed after the GLB is
   created (the `deploy.sh` orchestrator handles this). If you ran
   `deploy-dev-portal.sh` standalone before GLB was ready, re-run it.

---

## Authentication issues

### `gcloud` auth issues during setup

#### "Application Default Credentials not found"

Run:
```bash
gcloud auth application-default login
```
Claude Code uses ADC (not `gcloud auth login`) when talking to Vertex. These
are two different credential stores on your machine.

#### "Reauthentication failed" / expired session

```bash
gcloud auth application-default revoke
gcloud auth application-default login
```

#### Multiple gcloud configs interfering

Check: `gcloud config configurations list`. If you have the wrong
configuration active, switch: `gcloud config configurations activate NAME`.

#### Identity token vs. access token confusion

Claude Code sends **OAuth2 access tokens** (from ADC), not OIDC identity
tokens. Cloud Run's built-in invoker IAM check only accepts OIDC tokens,
which is why the gateways disable it (`--no-invoker-iam-check`) and use
app-level token validation instead.

**If you see this error:** the gateway's `ENABLE_TOKEN_VALIDATION` env var
may not be set to `1`, or the gateway image predates the token validation
middleware. Re-deploy the gateway:
```bash
bash scripts/deploy-llm-gateway.sh
```
The deploy script always sets `ENABLE_TOKEN_VALIDATION=1` and
`--no-invoker-iam-check`.

---

### Cloud Run 403 when Claude Code calls the gateway

**Symptom.** Gateway returns `403 Forbidden`; response body contains
`{"error": "forbidden", "detail": "... is not in the allowed principals list"}`.

**Cause.** The calling identity is not in the gateway's
`ALLOWED_PRINCIPALS` environment variable. The gateways use app-level
token validation (Cloud Run's invoker IAM is disabled via
`--no-invoker-iam-check`), so the 403 comes from the
`token_validation.py` middleware, not from Cloud Run IAM.

**Fix.** Re-deploy with the correct principals:
```bash
PRINCIPALS="user:[email protected],group:[email protected]" \
bash scripts/deploy-llm-gateway.sh
```

Or add the user to the Google group you listed in
`access.allowed_principals` and re-run `deploy.sh` — the script is
idempotent and will reconcile the `ALLOWED_PRINCIPALS` env var.

---

### Cloud Run 401 / ADC token not sent

**Symptom.** `401 Unauthorized` from the gateway when Claude Code calls it.

**Cause.** Claude Code didn't attach a bearer token to the outbound request
because no ADC is set up in the shell it's running from.

**Fix.**
```bash
gcloud auth application-default login
gcloud auth application-default print-access-token  # should print a token
```
Then restart Claude Code so it re-reads credentials.

**GLB mode note.** In GLB mode, the token validation middleware returns a
specific error body: `{"error": "missing_token"}` for no token or
`{"error": "invalid_token"}` for an expired/malformed token. Check the
response body for details.

---

### IAP tunnel refuses to connect

**Symptom.** `gcloud compute ssh --tunnel-through-iap <vm>` hangs or errors
with `4003: failed to connect to backend`.

**Causes and fixes.**

| Cause | Fix |
| --- | --- |
| Caller lacks `roles/iap.tunnelResourceAccessor` | Grant it: `gcloud projects add-iam-policy-binding PROJECT --member=user:YOU --role=roles/iap.tunnelResourceAccessor` |
| IAP source ranges blocked by firewall | Ensure the `allow-iap-ssh` firewall rule exists (source range `35.235.240.0/20`, tcp:22). Re-run `deploy-dev-vm.sh` if missing. |
| OS Login not enabled / caller missing `roles/compute.osLogin` | `gcloud projects add-iam-policy-binding PROJECT --member=user:YOU --role=roles/compute.osLogin` |
| VM is stopped (auto-shutdown kicked in) | `gcloud compute instances start claude-code-dev-shared --zone=<zone>` |
| Wrong zone | The VM is created in `<FALLBACK_REGION>-a`. Check with `gcloud compute instances list --project PROJECT` |

---

## Runtime issues

### Header rejection: `Unknown beta header: <name>`

**Symptom.** Claude Code prints a request error and the gateway log shows
the upstream Vertex response contained `Unknown beta header` or similar.

**Cause.** Claude Code sometimes sets an `anthropic-beta:` header for an
experimental feature that Anthropic's direct API supports but Vertex does
not. Vertex strict-rejects unknown beta headers.

**Fix.** Two layers, both should be on:

1. **Client-side.** `~/.claude/settings.json` must contain:
   ```json
   {
     "env": {
       "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
     }
   }
   ```
   `scripts/developer-setup.sh` writes this for you.
2. **Server-side.** The LLM gateway strips `anthropic-beta:` headers before
   forwarding. This is implemented in `gateway/app/headers.py`. If you've
   customized the gateway and removed that logic, put it back.

Verify by tailing the gateway log during a request:
```bash
gcloud logging read \
  'resource.type=cloud_run_revision AND resource.labels.service_name=llm-gateway' \
  --limit 20 --format json
```
You should see `"betas_stripped": ["..."]` on requests where a beta header
came in.

---

### HTTP 429: quota exceeded

**Symptom.** `Resource exhausted` or HTTP 429 from Vertex; Claude Code shows
rate-limit errors.

**Cause.** The project's
[Vertex AI quota](https://console.cloud.google.com/iam-admin/quotas) for
Anthropic models is capped. Default quotas for new projects are low.

**Fix.**
1. Open the quotas page, filter by `Vertex AI API` and `Anthropic`.
2. Find the quota that's maxing out — typically "Online prediction requests
   per minute per region per base model".
3. Click **Edit Quotas** and request an increase. Approval is usually
   minutes to hours.

**Short-term workaround.** Switch `CLOUD_ML_REGION=global` if you were on a
specific region — the multi-region endpoint has its own, usually higher,
pool.

---

### "Model not available in region"

**Symptom.** Request fails with a message like
`Model claude-opus-4-6 is not available in region europe-west2`.

**Cause.** Not every Claude model is in every region. Availability is
published on the
[Model Garden](https://console.cloud.google.com/vertex-ai/model-garden)
(filter by "Anthropic").

**Fix.**
1. If on a specific region, switch to `global` in `~/.claude/settings.json`:
   ```json
   { "env": { "CLOUD_ML_REGION": "global" } }
   ```
2. Or set a per-model region override for the specific model that's
   unavailable in your primary region. Example:
   ```json
   {
     "env": {
       "CLOUD_ML_REGION": "europe-west3",
       "VERTEX_REGION_CLAUDE_HAIKU_4_5": "us-east5"
     }
   }
   ```
3. Also make sure the model is **enabled** in your project via the Model
   Garden — click the model and press **Enable**. Enabling is per-project.

---

### Gateway returns 502 upstream_unavailable

**Symptom.** The gateway returns `{"error": "upstream_unavailable", "detail": "..."}` with HTTP 502.

**Cause.** The gateway's connection to Vertex AI failed. Common reasons:
- Vertex AI is experiencing an outage.
- The gateway service account lacks `roles/aiplatform.user`.
- Network connectivity to `aiplatform.googleapis.com` is blocked (corporate
  firewall, missing Private Google Access on the subnet).
- The request timed out (Claude responses with long contexts can take tens
  of seconds; the gateway's read timeout is 300 seconds).

**Fix.**
1. Check the gateway logs for the `upstream_error` entry — the `error_type`
   field tells you whether it was a `ConnectError`, `ReadTimeout`, etc.
   ```bash
   gcloud logging read \
     'resource.type=cloud_run_revision AND resource.labels.service_name=llm-gateway AND jsonPayload.message=upstream_error' \
     --project PROJECT_ID --limit 5 --format json
   ```
2. If `ConnectError`: verify the SA has `roles/aiplatform.user` and that a
   subnet has Private Google Access enabled.
3. If `ReadTimeout`: the request was too large or the model is overloaded.
   Retry or switch to `CLOUD_ML_REGION=global`.

---

## GLB-specific issues

### GLB returns 404 for all requests

**Symptom.** Every request to the GLB IP or domain returns 404, even
`/health`.

**Cause.** The URL map path matcher is missing or misconfigured. The GLB
routes `/v1/*`, `/v1beta1/*`, `/health`, `/healthz` to the LLM gateway,
`/mcp` and `/mcp/*` to the MCP gateway, and everything else (`/`) to the
dev portal.

**Fix.**
1. Inspect the URL map:
   ```bash
   gcloud compute url-maps describe claude-code-glb-url-map --global \
     --project PROJECT_ID --format yaml
   ```
2. Check that path matchers exist for the routes listed above.
3. If missing, re-run `scripts/deploy-glb.sh` — it creates the URL map
   idempotently. If the URL map already exists but is misconfigured, delete
   it and re-run:
   ```bash
   gcloud compute url-maps delete claude-code-glb-url-map --global --quiet
   bash scripts/deploy-glb.sh
   ```

---

### SSL certificate stuck in PROVISIONING

**Symptom.** Google-managed SSL cert shows `PROVISIONING` status for >30
minutes. HTTPS to the GLB domain fails.

**Cause.** Google-managed certs require DNS to point at the GLB IP before
they'll issue. The certificate won't provision until the A record resolves.

**Fix.**
1. Get the GLB static IP:
   ```bash
   gcloud compute addresses describe claude-code-glb-ip --global \
     --project PROJECT_ID --format="value(address)"
   ```
2. Check DNS. If `deploy-glb.sh` found a Cloud DNS managed zone for your
   parent domain, the A record was created automatically. Verify:
   ```bash
   dig +short claude.YOUR_DOMAIN
   ```
   If it doesn't resolve, either the Cloud DNS zone is in a different
   project or you're using external DNS — create the A record manually.
3. Wait. Provisioning typically takes 15–60 minutes after DNS propagates.
4. Check status:
   ```bash
   gcloud compute ssl-certificates describe claude-code-glb-cert --global \
     --project PROJECT_ID --format="value(managed.status)"
   ```

---

### Self-signed certificate errors in Claude Code

**Symptom.** Claude Code reports `Unable to connect to API: Self-signed
certificate detected` when using IP-based GLB access.

**Cause.** When you deploy without a domain (cert mode = self-signed),
the GLB uses a self-signed certificate. Node.js rejects self-signed
certs by default.

**Fix.** The `developer-setup.sh` and dev VM startup scripts
automatically set `NODE_TLS_REJECT_UNAUTHORIZED=0` in Claude Code's
settings when the gateway URL is IP-based. If you see this error:

1. Re-run `scripts/developer-setup.sh` — it detects the IP-based URL
   and adds the env var.
2. Or manually add to `~/.claude/settings.json`:
   ```json
   {
     "env": {
       "NODE_TLS_REJECT_UNAUTHORIZED": "0"
     }
   }
   ```

**To switch to a trusted cert later:** Re-run `deploy.sh`, choose the
GLB option, and select option 1 (Google-managed certificate). Provide
your base domain (e.g. `dpeterside.altostrat.com`) and the script will
set `GLB_DOMAIN=claude.dpeterside.altostrat.com`, create the DNS record
if Cloud DNS manages the zone, and provision a Google-managed cert.

---

### Direct Cloud Run URL works but GLB URL doesn't

**Symptom.** Requests to `https://<service>-xxx-uc.a.run.app/health` work,
but `https://<GLB_IP>/health` returns 502 or hangs.

**Causes.**
1. **GLB backends not connected.** The serverless NEGs or backend services
   may not be wired up.
2. **Health check failing.** The GLB health check can't reach the backend.
3. **Ingress restriction.** Cloud Run services in GLB mode use
   `ingress=internal-and-cloud-load-balancing`. Direct access is blocked
   by design — only the GLB can reach them.

**Fix.**
1. Run `scripts/validate-glb-demo.sh` to check all GLB infrastructure
   (NEGs, backends, URL map, forwarding rule).
2. Check backend health:
   ```bash
   gcloud compute backend-services get-health llm-gateway-backend \
     --global --project PROJECT_ID
   ```
3. Allow 2–5 minutes after deployment for the GLB health checks to mark
   backends as healthy.

---

### IAP login loop on dev portal or admin dashboard

**Symptom.** Accessing the dev portal or admin dashboard through the GLB
redirects to Google login, but after authenticating you get redirected back
in an infinite loop (or see a "You don't have access" page).

**Cause.** IAP is enabled on the backend service but the caller lacks
`roles/iap.httpsResourceAccessor`.

**Fix.**
```bash
gcloud iap web add-iam-policy-binding \
  --resource-type=backend-services --service=dev-portal-backend \
  --project PROJECT_ID \
  --member=user:[email protected] \
  --role=roles/iap.httpsResourceAccessor --quiet
```
Repeat for `admin-dashboard-backend` if needed.

The `deploy-glb.sh` script grants this role to all identities in the
`PRINCIPALS` list. If you added a new user after deployment, either
re-run the script or grant the binding manually.

**Note:** IAP is only on browser-facing services (dev portal, admin
dashboard). The LLM and MCP gateways use app-level token validation
instead, because Claude Code sends access tokens, not browser cookies.

---

### Token validation rejects a valid identity

**Symptom.** The GLB returns `{"error": "forbidden", "detail": "[email protected]
is not in the allowed principals list"}` with HTTP 403.

**Cause.** The `ALLOWED_PRINCIPALS` environment variable on the gateway
service doesn't include the caller's email. The token is valid (Google
verified it) but the email isn't in the allowlist.

**Fix.**
1. Check what's currently set:
   ```bash
   gcloud run services describe llm-gateway \
     --project PROJECT_ID --region REGION \
     --format="yaml(spec.template.spec.containers[0].env)"
   ```
2. Re-deploy with the correct principals:
   ```bash
   PRINCIPALS="user:[email protected],group:[email protected]" \
   ENABLE_GLB=true \
   bash scripts/deploy-llm-gateway.sh
   ```

**Dev VM note.** If you have a dev VM deployed, its service account
(`claude-code-dev-vm@PROJECT.iam.gserviceaccount.com`) must be in the
`ALLOWED_PRINCIPALS` list too. The deploy scripts add it automatically
when `ENABLE_VM=true`, but if you deploy the VM after the gateways, you'll
need to re-deploy the gateways to pick up the VM SA.

---

### GLB auto-discovery fails

**Symptom.** Scripts like `developer-setup.sh`, `seed-demo-data.sh`, or
`e2e-test.sh` don't auto-discover the GLB URL and prompt for a URL or
skip GLB tests.

**Cause.** Auto-discovery checks two sources in order:
1. The `GLB_DOMAIN` environment variable.
2. The `claude-code-glb-ip` static IP via
   `gcloud compute addresses describe`.

If neither exists (GLB not deployed, wrong project, or the caller lacks
`compute.addresses.get` permission), discovery returns empty.

**Fix.**
- Set `GLB_DOMAIN` in your environment if you have a custom domain:
  ```bash
  export GLB_DOMAIN=claude.yourcompany.com
  ```
- Or pass the URL explicitly to the script:
  ```bash
  ./scripts/e2e-test.sh --glb-url https://34.120.x.x
  ./scripts/seed-demo-data.sh --gateway-url https://claude.yourcompany.com
  ```
- For `developer-setup.sh`, the auto-discovered URL is shown as the default
  in the interactive prompt — just press Enter to accept it.

---

## Observability issues

### Admin dashboard shows no data

**Symptom.** The admin dashboard loads but all charts are empty.

**Cause.** No requests have been routed through the gateways yet, or
the BigQuery dataset hasn't received data from the Cloud Logging sink.

**Fix.**
1. Send a test request through the gateway (run `developer-setup.sh` and
   ask Claude a question, or use the e2e test).
2. Wait ~60 seconds for Cloud Logging to flush to BigQuery.
3. Refresh the dashboard.

To populate the dashboard with demo-quality traffic:
```bash
./scripts/seed-demo-data.sh --users 5 --requests-per-user 10
```
This sends small Haiku requests (~$0.0001 each, hard-capped at 200). All
requests are attributed to **your** identity.

---

### BigQuery dataset exists but table is empty

**Symptom.** The `claude_code_logs` dataset exists in BigQuery but the
`run_googleapis_com_requests` table has zero rows.

**Cause.**
1. The Cloud Logging sink might not have writer access to BigQuery.
2. No log entries match the sink's filter.
3. There's ingestion lag (usually <1 minute but can spike).

**Fix.**
1. Verify the sink exists and has the right filter:
   ```bash
   gcloud logging sinks describe claude-code-gateway-logs \
     --project PROJECT_ID --format yaml
   ```
   The filter should be:
   `resource.type="cloud_run_revision" AND resource.labels.service_name=~"^(llm-gateway|mcp-gateway)$"`
2. Check that the sink's writer identity has `roles/bigquery.dataEditor`:
   ```bash
   SINK_SA=$(gcloud logging sinks describe claude-code-gateway-logs \
     --project PROJECT_ID --format="value(writerIdentity)")
   gcloud projects get-iam-policy PROJECT_ID \
     --flatten="bindings[].members" \
     --filter="bindings.members:${SINK_SA}" \
     --format="value(bindings.role)"
   ```
3. If the IAM binding is missing, re-run `scripts/deploy-observability.sh`.

---

## MCP gateway issues

### MCP tool invocation fails with handshake error

**Symptom.** Claude Code tries to use an MCP tool but gets a connection
or handshake error. The e2e test (5.2) also fails.

**Cause.** The MCP gateway uses Streamable HTTP transport at the `/mcp`
path. Common issues:
- Wrong URL path (Claude Code must be configured with `<url>/mcp`, not just
  `<url>`).
- The MCP gateway container is running an old image without the
  FastAPI + FastMCP composition.

**Fix.**
1. Check that `~/.claude/settings.json` has the correct MCP config:
   ```json
   {
     "mcpServers": {
       "gcp-tools": {
         "type": "http",
         "url": "https://<gateway-url>/mcp"
       }
     }
   }
   ```
2. Verify the `/health` endpoint works first:
   ```bash
   TOKEN=$(gcloud auth print-identity-token --audiences=<MCP_URL>)
   curl -sS -H "Authorization: Bearer $TOKEN" <MCP_URL>/health
   ```
3. If `/health` works but `/mcp` doesn't, rebuild and redeploy:
   ```bash
   bash scripts/deploy-mcp-gateway.sh
   ```

---

### MCP works directly but fails through GLB

**Symptom.** MCP tool calls succeed when pointing at the Cloud Run URL
but fail through the GLB.

**Cause.** The GLB URL map routes `/mcp` and `/mcp/*` to the MCP gateway
backend. If the path matcher is missing, requests route to the default
backend (dev portal) instead.

**Fix.**
1. Inspect the URL map for MCP routes:
   ```bash
   gcloud compute url-maps describe claude-code-glb-url-map --global \
     --project PROJECT_ID --format yaml | grep -A5 mcp
   ```
2. If missing, re-run `deploy-glb.sh` to recreate the path rules.
3. In GLB mode, the MCP URL in `~/.claude/settings.json` should use the
   GLB URL, not the Cloud Run URL:
   ```json
   {
     "mcpServers": {
       "gcp-tools": {
         "type": "http",
         "url": "https://<GLB_URL>/mcp"
       }
     }
   }
   ```

---

## Test failures (`scripts/e2e-test.sh`)

When the end-to-end script reports a FAIL, check the table below
**first** — most failures have one obvious cause.

| Test | Typical cause | First thing to check |
| --- | --- | --- |
| **1.1** Cloud Run services READY | Image didn't build, or Cloud Run is still provisioning | `gcloud run services describe <svc> --region=<r>` — look at `status.conditions` for the real error |
| **1.2** no external IP addresses | Someone manually attached a static IP to a VM | `gcloud compute addresses list --filter="addressType=EXTERNAL"` — GLB IPs (`claude-code-glb-ip`) are expected and whitelisted |
| **1.3** gateway service accounts | Deploy script failed midway | Re-run `scripts/deploy-llm-gateway.sh` — it's idempotent |
| **1.4** subnet Private Google Access | Custom VPC created without PGA | `gcloud compute networks subnets list --format='value(name,privateIpGoogleAccess)'` — the flag must be True |
| **1.5** required APIs enabled | APIs disabled after deploy | `gcloud services enable aiplatform.googleapis.com run.googleapis.com iap.googleapis.com compute.googleapis.com bigquery.googleapis.com` |
| **1.6** admin dashboard READY | Observability not deployed, or image build failed | Re-run `scripts/deploy-observability.sh` |
| **1.7** BigQuery dataset | Observability not deployed | Re-run `scripts/deploy-observability.sh` |
| **1.8** Cloud Logging sink | Observability not deployed, or sink was manually deleted | Re-run `scripts/deploy-observability.sh` |
| **2.1** direct Vertex inference | Quota or model not enabled in region | Open Model Garden, confirm Claude Haiku 4.5 is enabled; check quotas page for 429s |
| **3.1** gateway inference | Caller not in `ALLOWED_PRINCIPALS` env var on the gateway, or token validation not enabled | Check `ALLOWED_PRINCIPALS` and `ENABLE_TOKEN_VALIDATION=1` env vars on the service: `gcloud run services describe llm-gateway --region=REGION --format="yaml(spec.template.spec.containers[0].env)"` |
| **3.2** structured log emitted | Gateway isn't actually reached (ingress issue) or logs lagging | Wait another minute and re-run; if still fails, check `gcloud logging read` filter matches service name |
| **3.3** anthropic-beta stripped | Old gateway image without `headers.py` sanitation | Rebuild + redeploy the LLM gateway |
| **4.1** portal responds | Dev portal not deployed, or IAM missing | Re-run `scripts/deploy-dev-portal.sh` |
| **4.2** portal placeholders replaced | Portal deployed before gateways (placeholders weren't substituted) | Re-deploy portal after gateways are up |
| **5.1** MCP /health responds | **401/403**: caller not in `ALLOWED_PRINCIPALS` or token validation not enabled. **404**: old image without the health endpoint — rebuild + redeploy |
| **5.2** MCP tool invocation | Handshake session lost / wrong path | Check `mcp-gateway/server.py` mount path matches `/mcp`; try `curl -i <url>/mcp` directly |
| **6.1** unauth rejected | Token validation middleware not enabled (`ENABLE_TOKEN_VALIDATION` not `1`) | Re-deploy the gateway — the deploy script always sets `ENABLE_TOKEN_VALIDATION=1` and `--no-invoker-iam-check` |
| **6.2** VM has no external IP | Someone created the VM outside the deploy scripts | Either delete + re-create via `scripts/deploy-dev-vm.sh`, or manually remove the access config |
| **6.3** dashboard /health | Dashboard not deployed, or caller missing `roles/run.invoker` | Re-run `scripts/deploy-observability.sh` |
| **6.4** dashboard API | Dashboard deployed but BigQuery query failing | Check dashboard SA has `roles/bigquery.dataViewer` and `roles/bigquery.jobUser` |
| **7.1–7.3** GLB inference | GLB not deployed, backends unhealthy, or SSL cert not yet provisioned | Run `scripts/validate-glb-demo.sh` for detailed GLB diagnostics |
| **7.4** direct Cloud Run blocked | Ingress not set to `internal-and-cloud-load-balancing` | Re-deploy gateways with `ENABLE_GLB=true` |
| **7.5** GLB unauth rejected | Token validation middleware not enabled | Check `ENABLE_TOKEN_VALIDATION=1` in the gateway's env vars |

### Failure triage flow

1. **Start with the lowest-numbered failing layer.** A Layer 1 failure
   often causes cascading failures in Layers 2–6 — fix it first.
2. **Re-run with `--verbose`** to see the exact gcloud/curl commands.
3. **For any 4xx from the gateway**, run
   `gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=llm-gateway' --limit=5 --format=json`
   and inspect the last few entries for auth or header errors.
4. **For MCP failures**, test the plain `/health` endpoint first
   (Layer 5.1). If that passes but 5.2 fails, the tool itself or the
   handshake is the problem, not the gateway.
5. **GLB tests (Layer 7) auto-discover** the GLB URL from the project's
   static IP or `GLB_DOMAIN` env var. If auto-discovery fails, pass it
   explicitly with `--glb-url`.
6. **Layer 4 (laptop) and the negative-identity subset of Layer 6**
   must be tested manually with a second account — see
   [TEST-AND-DEMO-PLAN.md](../../03-demos/claude-code-vertex-gcp/TEST-AND-DEMO-PLAN.md).

---

## GLB validation failures (`scripts/validate-glb-demo.sh`)

The GLB validation suite runs 31 tests across 8 layers. When tests fail,
here's what to check:

| Layer | Tests | Common failure | Fix |
| --- | --- | --- | --- |
| **L1: GLB Infra** | Static IP, NEGs, backends, URL map, SSL cert, forwarding rule, HTTPS proxy | Missing resources | Re-run `scripts/deploy-glb.sh`. Check that all Cloud Run services were deployed before the GLB. |
| **L2: CR Config** | Ingress restricted, allUsers invoker, token validation enabled, allowed principals set, dev VM SA included | Wrong Cloud Run config | Re-deploy services with `ENABLE_GLB=true`. For the dev VM SA, ensure `ENABLE_VM=true` when deploying gateways. |
| **L3: Auth** | Health without token, access token, OIDC, no-token rejection, direct Cloud Run blocked | Token validation misconfigured | Check `ENABLE_TOKEN_VALIDATION=1` and `ALLOWED_PRINCIPALS` env vars on gateway services. |
| **L4: Routing** | /health, /v1/*, /mcp, / (default) routes | URL map path rules missing | Delete and recreate the URL map, or re-run `deploy-glb.sh`. |
| **L5: Dev VM** | VM exists, metadata has GLB URL, VM SA exists | VM deployed before GLB, so startup script has Cloud Run URLs | Re-deploy VM with `ENABLE_GLB=true` to bake the GLB URL into its settings. |
| **L6: IAP** | OAuth brand, IAP on portal/dashboard, no IAP on gateways | IAP setup incomplete | Re-run `deploy-glb.sh` with `IAP_SUPPORT_EMAIL` set. Manual Console setup may be needed for the OAuth consent screen. |
| **L7: MCP+GLB** | MCP tool invocation through GLB | MCP path rules missing in URL map | Re-run `deploy-glb.sh` to recreate URL map with MCP routes. |
| **L8: Parity** | Resource names match, backend protocol correct | Resources created manually with non-standard names | Re-deploy from the scripts to ensure naming consistency with Terraform modules. |

The GLB URL is auto-discovered from the project's static IP or the
`GLB_DOMAIN` env var. Pass `--glb-url` explicitly if auto-discovery fails.

---

## Diagnostics toolkit

Run these to gather context before filing an issue or asking for help.

### Quick health check

```bash
# Run the developer-setup diagnostic mode (read-only, no changes)
./scripts/developer-setup.sh --diagnose
```

### Gateway connectivity

```bash
# Get a token
TOKEN=$(gcloud auth print-identity-token --audiences=<GATEWAY_URL> 2>/dev/null \
  || gcloud auth application-default print-access-token)

# Hit the health endpoint
curl -sS -w "\nHTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  <GATEWAY_URL>/health

# Check the last 10 gateway log entries
gcloud logging read \
  'resource.type=cloud_run_revision AND resource.labels.service_name=llm-gateway AND jsonPayload.message=proxy_request' \
  --project PROJECT_ID --limit 10 --format json
```

### Full validation suites

```bash
# Standard deployment (all layers, no GLB)
./scripts/e2e-test.sh

# Quick smoke test (5 checks, <30 seconds)
./scripts/e2e-test.sh --quick

# GLB-specific validation (31 tests)
./scripts/validate-glb-demo.sh --project PROJECT_ID

# Pre-deploy code consistency (19 checks, no GCP access needed)
./scripts/pre-deploy-check.sh
```

### Infrastructure inspection

```bash
# List all Cloud Run services
gcloud run services list --project PROJECT_ID --region REGION

# Check Cloud Run service configuration
gcloud run services describe llm-gateway \
  --project PROJECT_ID --region REGION --format yaml

# List GLB components
gcloud compute forwarding-rules list --project PROJECT_ID --filter="name~claude-code"
gcloud compute backend-services list --project PROJECT_ID --filter="name~gateway OR name~portal OR name~dashboard"

# Check BigQuery dataset + logging sink
gcloud logging sinks list --project PROJECT_ID
```

---

## Still stuck?

1. Re-read `ARCHITECTURE.md` to confirm the component in question is doing
   what you think.
2. Run `scripts/developer-setup.sh --diagnose` to dump your local config.
3. Run `scripts/e2e-test.sh --verbose` for detailed command-level output.
4. For GLB issues, run `scripts/validate-glb-demo.sh` — it tests all 8
   layers and pinpoints the exact failure.
5. File an issue with:
   - The exact command and its output.
   - `gcloud config list --format=json`
   - The last ~20 lines of `gcloud logging read` for the relevant service.
   - Your `~/.claude/settings.json` (redact the project ID if sensitive).
   - Output of `scripts/e2e-test.sh --verbose` if applicable.
