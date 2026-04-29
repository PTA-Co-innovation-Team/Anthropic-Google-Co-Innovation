# Claude Code on GCP via Vertex AI

**A production-quality reference architecture and deployment kit for running
[Claude Code](https://docs.claude.com/en/docs/claude-code) on Google Cloud
with all model inference routed through [Vertex AI](https://cloud.google.com/vertex-ai).**

No traffic to `api.anthropic.com`. Google identity everywhere. Near-zero cost
when idle. Built for teams whose security reviewers will actually read the
diagram.

---

## Disclaimer

This repository is a **reference architecture**, not a supported
product of Google LLC, Anthropic PBC, or any affiliated entity. It is
released under Apache 2.0 and is provided strictly **as-is, with no
warranty of any kind**, express or implied.

You are responsible for reviewing, adapting, and testing every
component before running it against a production Google Cloud
project. The operational, security, compliance, and cost consequences
of any deployment are yours to evaluate and own.

**Use at your own risk — this is a map, not the territory.**

---

## What you'll get

When this is done deploying, your GCP project will contain:

| Component | What it is | Why it exists |
| --- | --- | --- |
| **LLM Gateway** | Cloud Run service — tiny FastAPI reverse proxy | Single point for auth, logging, and header sanitation in front of Vertex AI |
| **MCP Gateway** | Cloud Run service — FastMCP over Streamable HTTP | Place to host your organization's custom MCP tools |
| **Dev Portal** | Cloud Run static site | Self-service setup instructions for your developers (IAP-protected in GLB mode, Cloud Run IAM in standard mode) |
| **Dev VM** *(optional, off by default)* | GCE VM with VS Code Server, accessed via IAP | Cloud dev environment for teams that don't want local installs |
| **Observability** | Log sink → BigQuery + built-in admin dashboard | Admin dashboard: who is using Claude, how much, errors, top models |

**Standard mode:** The LLM and MCP gateways use **app-level token validation**
(`token_validation.py` middleware) that accepts both OAuth2 access tokens and
OIDC identity tokens. Cloud Run's built-in invoker IAM check is disabled
(`--no-invoker-iam-check`) because Claude Code sends access tokens, which
Cloud Run IAM rejects. Ingress is `all` so developer laptops can reach the
services directly; the token validation middleware is the security boundary.
An `ALLOWED_PRINCIPALS` allowlist controls who can call the gateways.

**GLB mode** *(optional):* A Global HTTP(S) Load Balancer sits in front of
all services. Ingress is `internal-and-cloud-load-balancing`; the GLB is the
only entry point. Gateways use the same app-level token validation as
standard mode; portal and dashboard use IAP for browser auth.

**VPC internal mode** *(optional, mutually exclusive with GLB mode):* All
Cloud Run services use `--ingress internal` — they are only reachable from
within the VPC. Developers access services through the dev VM, which is
inside the VPC and accessed via IAP SSH tunneling (`gcloud compute ssh
--tunnel-through-iap`). No VPN is required — IAP provides secure access.
VPN/Cloud Interconnect remain available as optional advanced configurations.
The VPC Connector is forced on so Cloud Run egress goes through the VPC for
Private Google Access. `developer-setup.sh` detects unreachable services
and skips the smoke test with a warning. `e2e-test.sh` and
`seed-demo-data.sh` must be run from within the VPC (e.g., from the dev VM).

The Dev VM has **no public IP** and is reached via IAP TCP tunneling.

### Access Tiers (IAP-based, no VPN required)

Both restricted-ingress modes use IAP as the access mechanism:

**Tier 1 — GLB + IAP** (production): The Global Load Balancer fronts all
services. Browser services (dev portal, admin dashboard) use IAP for
Google SSO authentication. API services (llm-gateway, mcp-gateway) use
app-level token validation. Requires a DNS domain for managed certificates.

```
Developer laptop ──(HTTPS + access token)──▶ GLB ──▶ Cloud Run (internal + GLB)
                 ──(browser + IAP SSO)──────▶ GLB ──▶ Cloud Run (IAP-protected)
```

**Tier 2 — Dev VM + IAP SSH** (development/budget): No GLB needed. Cloud
Run uses `--ingress internal`. Developers SSH into the dev VM via IAP and
run Claude Code directly. The VM is pre-configured with gateway URLs.

```
Developer laptop ──(IAP SSH tunnel)──▶ Dev VM (inside VPC) ──▶ Cloud Run (internal)
```

```
Developer Laptop ──(gcloud auth + IAP)──▶ LLM Gateway (Cloud Run) ──▶ Vertex AI (Claude)
                                     │
                                     └──▶ MCP Gateway (Cloud Run)
```

See [ARCHITECTURE.md](../../04-best-practice-guides/claude-code-vertex-gcp/ARCHITECTURE.md) for the full diagram and design decisions,
and [COSTS.md](../../04-best-practice-guides/claude-code-vertex-gcp/COSTS.md) for a detailed cost breakdown.

---

## Prerequisites

Before you deploy, you need:

1. **A Google Cloud project** where you have the `Owner` or `Editor` role.
   If you don't have one: https://console.cloud.google.com/projectcreate
2. **A billing account linked to that project.** Running this costs roughly
   **$0–5/month** when idle (see [COSTS.md](../../04-best-practice-guides/claude-code-vertex-gcp/COSTS.md)).
3. **Access to the Anthropic Claude models on Vertex AI.**
   Open https://console.cloud.google.com/vertex-ai/model-garden, search for
   "Claude", and click **Enable** on the models you want to use
   (Opus 4.6, Sonnet 4.6, Haiku 4.5 are the current defaults).
4. **A local machine with:**
   - `gcloud` CLI installed and logged in
     ([install guide](https://cloud.google.com/sdk/docs/install))
   - `git` installed
   - For the Terraform path: `terraform` ≥ 1.6
   - For the notebook path: nothing — just a browser

> **New to GCP?** That's expected. Every script in this repo is interactive
> and explains what it's about to do before doing it. You can always answer
> "no" and nothing gets created.

---

## Four ways to deploy

Pick whichever matches your comfort level. All four end up with the same
resources.

### 1. Lazy one-liner (curl-to-bash)

Fastest way to kick the tires:

```bash
curl -fsSL https://raw.githubusercontent.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation/main/05-solution-accelerators/claude-code-vertex-gcp/scripts/deploy.sh | bash
```

**What this does:** downloads `deploy.sh`, which then clones the full
repository into a temporary directory and re-executes itself from there.
Everything runs locally on your machine — no data is sent to third parties.

> ⚠️ **Security note.** Piping `curl` to `bash` runs code on your machine
> without you reading it first. If your org requires code review before
> execution, use path 2 instead. You can always read the script first:
> `curl -fsSL https://raw.githubusercontent.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation/main/05-solution-accelerators/claude-code-vertex-gcp/scripts/deploy.sh | less`

### 2. Git clone + script (recommended)

Same behavior as the one-liner, but you keep a local copy you can inspect
and re-run:

```bash
git clone https://github.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation.git
cd Anthropic-Google-Co-Innovation/05-solution-accelerators/claude-code-vertex-gcp/scripts
./deploy.sh
```

The script will interactively prompt for project, region, and which
components to enable, then write a `config.yaml`, show it to you, and
**ask for explicit confirmation** before creating any resources.

### 3. Terraform (for teams who already use IaC)

Two-phase flow — `terraform apply` twice, once with placeholder
images and once with the real ones:

```bash
git clone https://github.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation.git
cd Anthropic-Google-Co-Innovation/05-solution-accelerators/claude-code-vertex-gcp/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set project_id and allowed_principals

# Phase 1: create the VPC, SAs, empty Cloud Run services with a
# placeholder "hello" image. This gives us the Artifact Registry repo
# we need for phase 2.
terraform init
terraform apply

# Phase 2: build + push the real gateway images via the deploy
# scripts, then re-apply with real image refs.
cd ..
PROJECT_ID=$(terraform -chdir=terraform output -raw project_id) \
REGION=$(terraform -chdir=terraform output -raw region) \
FALLBACK_REGION=us-central1 \
PRINCIPALS="user:[email protected]" \
  bash scripts/deploy-llm-gateway.sh
# repeat for deploy-mcp-gateway.sh, deploy-dev-portal.sh

# The deploy scripts rewrite the Cloud Run services directly; no
# second terraform apply is strictly needed, but if you want TF to
# track the real image tag, set llm_gateway_image / mcp_gateway_image
# / dev_portal_image in terraform.tfvars and re-apply.
```

> **Why two phases?** The TF modules fall back to
> `us-docker.pkg.dev/cloudrun/container/hello` when `*_image` is
> empty, so the first apply always succeeds. If you prefer a single
> `terraform apply`, build the images yourself with `gcloud builds
> submit` before the first apply, set the three `*_image` variables
> in `terraform.tfvars`, and skip phase 2.

Module toggles in `terraform.tfvars` mirror the `components:` block in
`config.yaml` one-for-one.

### 4. Notebook (Colab / Vertex Workbench)

Open [`01-tutorials/claude-code-vertex-gcp/deploy.ipynb`](../../01-tutorials/claude-code-vertex-gcp/deploy.ipynb) in
[Colab](https://colab.research.google.com/) or
[Vertex Workbench](https://console.cloud.google.com/vertex-ai/workbench) and
step through the cells. Best option if you want to see each step and its
output without installing anything locally.

> The notebook is **fully self-contained** — all source code (Dockerfiles,
> Python services, HTML) is embedded directly in the cells. No git clone
> required.

---

## After deployment: point Claude Code at your gateway

The deploy script prints the gateway URL at the end. To connect Claude Code
to it, run on your laptop:

```bash
./scripts/developer-setup.sh
```

This will:

1. Check `gcloud` is installed and authenticated.
2. Run `gcloud auth application-default login` (opens a browser).
3. Install the Claude Code CLI via `npm install -g @anthropic-ai/claude-code`
   if `claude` is not already on `PATH` (requires Node.js/npm already installed).
4. Auto-discover the gateway URL (checks GLB domain/IP first, then falls back
   to Cloud Run service URL) and offer it as the default in the interactive prompt.
5. Write `~/.claude/settings.json` with the right environment variables
   (Claude Code reads from here). It asks before overwriting an existing file.
6. Send a test request through the gateway to prove the round-trip works.

The settings file will look roughly like this:

```json
{
  "env": {
    "CLAUDE_CODE_USE_VERTEX": "1",
    "CLOUD_ML_REGION": "global",
    "ANTHROPIC_VERTEX_PROJECT_ID": "your-project-id",
    "ANTHROPIC_VERTEX_BASE_URL": "https://your-gateway-abc123-uc.a.run.app",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

Then just run `claude` — you're on Vertex.

---

## Validating your deployment

### Pre-deploy checks (no GCP access needed)

Before deploying, run the local code-consistency checker:

```bash
./scripts/pre-deploy-check.sh
```

This runs 19 checks validating that GLB + hybrid-auth changes are
internally consistent across deploy scripts, Terraform modules, and
application code (unit tests, token_validation.py sync, middleware
registration, deploy script GLB conditionals, Terraform variable
wiring, teardown coverage). No GCP credentials required.

### Post-deploy e2e tests

Right after `deploy.sh` (or `terraform apply`) finishes, run the
end-to-end test script to confirm everything is wired up correctly:

```bash
./scripts/e2e-test.sh
```

This runs seven layers of checks — infrastructure sanity, direct Vertex
reachability, gateway proxy behavior, MCP tool invocation, dev VM
verification, negative tests (unauth rejection, no public IP), and
GLB-specific tests. The GLB URL is auto-discovered from the project's
static IP or `GLB_DOMAIN` environment variable (you can also pass it
explicitly with `--glb-url`). It prints a PASS/FAIL/SKIP summary and
exits non-zero on any failure.

For a faster smoke test (5 checks, <30 seconds):

```bash
./scripts/e2e-test.sh --quick
```

### GLB-specific validation

When GLB is enabled, run the dedicated GLB validation suite:

```bash
./scripts/validate-glb-demo.sh --project $PROJECT_ID
```

This runs 31 tests across 8 layers: GLB infrastructure, Cloud Run
configuration, auth flows (access tokens, OIDC tokens, rejection),
URL map routing, dev VM integration, IAP bindings, MCP through GLB,
and bash/Terraform parity. The GLB URL is auto-discovered.

See [TEST-AND-DEMO-PLAN.md](../../03-demos/claude-code-vertex-gcp/TEST-AND-DEMO-PLAN.md) for the full
validation procedure, including the manual Layer 4 (laptop) and Layer
6 (negative identity) tests that can't be automated from a single
machine.

### External uptime probes

Both gateways expose a `GET /health` endpoint, but the auth posture
depends on deployment mode:

**Standard mode:** Cloud Run uses `--no-invoker-iam-check` with
`ingress=all` and app-level token validation. The `/health` endpoint
bypasses the token validation middleware, so an anonymous external
probe **can reach it** directly.

**GLB mode:** `/health` bypasses the token validation middleware (so
GLB health probes work). However, only the GLB can reach Cloud Run
(`ingress=internal-and-cloud-load-balancing`), so external probes
must hit the GLB URL: `https://<glb-ip-or-domain>/health`. The
GLB's own health probes are automatic; for external monitoring,
point an uptime check at the GLB URL with no auth header (the
health endpoint is intentionally open).

**VPC internal mode:** Cloud Run services use `ingress=internal` and
are not reachable from outside the VPC. External uptime probes
cannot reach them. Use Cloud Monitoring uptime checks from within
the VPC, or rely on Cloud Run's built-in health reporting.

#### SA-authenticated probe (standard mode)

1. **Create a service account** for the probe:
   ```bash
   gcloud iam service-accounts create uptime-probe \
     --project=$PROJECT_ID \
     --display-name="Cloud Monitoring uptime-probe"
   ```
2. **Grant it `roles/run.invoker`** on the gateway service:
   ```bash
   gcloud run services add-iam-policy-binding llm-gateway \
     --project=$PROJECT_ID --region=$REGION \
     --member="serviceAccount:uptime-probe@$PROJECT_ID.iam.gserviceaccount.com" \
     --role="roles/run.invoker"
   ```
3. **Create the uptime check** in the
   [Cloud Monitoring console](https://console.cloud.google.com/monitoring/uptime).
   Under **Advanced options → Authentication**, pick
   **Service account authentication** and select
   `uptime-probe@...`. Target URL: `https://<gateway-url>/health`,
   HTTP GET, expected 200.

Repeat for the MCP gateway if you want a second probe. The SA can
be reused — just add another `run.invoker` binding on `mcp-gateway`.

### Admin Dashboard

When observability is enabled, the deploy script creates a **BigQuery
dataset** (`claude_code_logs`), a **Cloud Logging sink** that routes
gateway logs into it, and an **Admin Dashboard** Cloud Run service.

The dashboard shows real-time charts for request volume, model usage,
top callers, error rate, and latency percentiles — all powered by
BigQuery. It auto-refreshes every 60 seconds.

Data appears ~60 seconds after the first request through the LLM
gateway. Access is gated by Cloud Run IAM (same principals as the
gateways).

### Demo prep

After a fresh deploy the dashboard is empty. To populate it with
realistic-looking traffic before a screenshot or live demo:

```bash
./scripts/seed-demo-data.sh --users 5 --requests-per-user 10
```

The seeder issues small Haiku requests (~$0.001 each, hard-capped at
200 total). All requests are attributed to **your** identity — the
"top callers" panel will show only you.

---

## Global Load Balancer + IAP (Optional)

By default, both standard and GLB modes use **app-level token validation**
(`token_validation.py` middleware) that accepts both OAuth2 access tokens
and OIDC identity tokens. Cloud Run's invoker IAM check is disabled because
Claude Code sends access tokens, which Cloud Run IAM rejects.

The **Global Load Balancer (GLB)** option adds a unified entry point,
custom domain support, IAP for browser-facing services (portal, dashboard),
and Cloud Armor WAF capabilities.

### Architecture

| Service | Auth mechanism | Why |
| --- | --- | --- |
| LLM Gateway | App-level middleware (no IAP) | Claude Code sends access tokens |
| MCP Gateway | App-level middleware (no IAP) | MCP client sends access tokens |
| Dev Portal | IAP (browser OAuth flow) | Users access via browser |
| Admin Dashboard | IAP (browser OAuth flow) | Users access via browser |

All Cloud Run services: `ingress=internal-and-cloud-load-balancing` +
`--no-invoker-iam-check`. The GLB becomes the only entry point.

### Enable

**Script path:**
```bash
./scripts/deploy.sh
# Answer "yes" to "Deploy Global Load Balancer?"
```

**Terraform path:**
```hcl
# terraform.tfvars
enable_glb        = true
glb_domain        = "claude.yourcompany.com"  # optional, IP-only if empty
iap_support_email = "admin@yourcompany.com"   # required for IAP on portal
```

### Cost

The GLB adds ~$18/month (forwarding rule). Data processing is
negligible for API traffic. Google-managed SSL cert is free.

### Verify

```bash
# Access token works through GLB (the whole point):
ACCESS_TOKEN=$(gcloud auth application-default print-access-token)
curl -sS -w "%{http_code}" -H "Authorization: Bearer $ACCESS_TOKEN" "$GLB_URL/health"
# Expected: 200

# Full e2e suite including GLB tests (GLB URL is auto-discovered):
./scripts/e2e-test.sh
```

---

## Cost summary

Idle is the common case. Typical monthly costs:

| Configuration | Estimated cost |
| --- | --- |
| **Default, idle** (LLM gateway + MCP gateway + portal, no dev VM, Private Google Access) | **~$0–5/month** |
| **Default, light use** (a few developers) | **~$10–30/month** (Vertex tokens dominate) |
| **Everything on** (incl. shared dev VM `e2-small`, log sink to BigQuery) | **~$25–50/month** |
| **+ GLB** (add to any configuration above) | **+~$18/month** |
| **+ VPC internal** (add to any non-GLB configuration above) | **+~$0** (VPC Connector is forced on but has no additional charge beyond the default) |

See [COSTS.md](../../04-best-practice-guides/claude-code-vertex-gcp/COSTS.md) for the line-by-line breakdown.

Token costs for Claude on Vertex follow
[Google's published Vertex AI pricing](https://cloud.google.com/vertex-ai/generative-ai/pricing)
— they are billed to your GCP project, not to Anthropic.

---

## Troubleshooting

If setup or a request fails, check [TROUBLESHOOTING.md](../../04-best-practice-guides/claude-code-vertex-gcp/TROUBLESHOOTING.md)
first — it covers deployment issues, authentication (ADC, IAM, IAP, token
validation), runtime errors (beta headers, quotas, 502s), GLB-specific
problems (SSL certs, URL map routing, IAP loops, auto-discovery), VPC
internal mode connectivity, MCP handshake failures, observability pipeline
debugging, and a detailed e2e/GLB test failure reference table.

---

## Tear down

```bash
./scripts/teardown.sh
```

Interactive. You have to type your project ID to confirm.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Issues and PRs welcome.

---

## License

Apache 2.0 — see [LICENSE](LICENSE).
