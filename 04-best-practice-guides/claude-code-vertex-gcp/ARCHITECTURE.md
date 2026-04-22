# Architecture

This document explains *what* gets deployed, *why* it was designed this way,
and *how* the pieces fit together. Read it before you run `deploy.sh` in
production — or after, if you want to understand what it just did.

---

## Goals

1. **All Claude inference goes through Vertex AI.** No traffic to
   `api.anthropic.com`. This is a hard requirement for most enterprise
   deployments on GCP.
2. **Google identity everywhere.** No API keys, no shared secrets, no bearer
   tokens in dotfiles. IAM and IAP do the authentication.
3. **Near-zero idle cost.** Cloud Run scales to zero. The optional dev VM is
   off by default and auto-shuts-down when enabled.
4. **Deployable by beginners.** One interactive script, one Terraform apply,
   or one notebook. The scripts explain themselves before acting.
5. **No public surface area.** Cloud Run services use internal ingress. The
   dev VM has no public IP and is reached via IAP TCP tunneling.

---

## Topology

```
Developer Laptop ──┐
                   │  (gcloud auth + IAP TCP tunnel)
                   ▼
 ┌───────────────────────── Google Cloud Project ─────────────────────────┐
 │                                                                        │
 │  ┌─────────────┐                                                       │
 │  │  Dev Portal │  IAP-protected static page (Cloud Run)                │
 │  └─────────────┘                                                       │
 │                                                                        │
 │  ┌────────────────┐    ┌──────────────────┐    ┌─────────────────┐     │
 │  │  Developer VM  │───▶│   LLM Gateway    │───▶│    Vertex AI    │     │
 │  │ (GCE, optional)│    │ (Cloud Run,      │    │  Claude models  │     │
 │  │ VS Code Server │    │  pass-through    │    │  via Private    │     │
 │  │ Claude Code    │    │  reverse proxy)  │    │  Google Access  │     │
 │  └────────────────┘    └──────────────────┘    └─────────────────┘     │
 │         │                                                              │
 │         │              ┌──────────────────┐                            │
 │         └─────────────▶│   MCP Gateway    │                            │
 │                        │ (Cloud Run,      │                            │
 │                        │  FastMCP +       │                            │
 │                        │  Streamable HTTP)│                            │
 │                        └──────────────────┘                            │
 │                                                                        │
 │  Cloud Logging  ──▶  BigQuery sink  ──▶  Admin Dashboard (Cloud Run)   │
 └────────────────────────────────────────────────────────────────────────┘
```

---

## Components

### 1. LLM Gateway (Cloud Run, FastAPI)

**Role:** a thin **pass-through reverse proxy** that sits between Claude Code
and the Vertex AI endpoint for Claude models.

**Why a gateway at all when Claude Code already speaks Vertex natively?**
Because the gateway gives you the things Vertex does not do for you:

- **Centralized auth verification.** Every request must carry a valid Google
  identity token (the caller's ADC or an IAP-injected JWT). The gateway
  verifies the signature and the audience before forwarding.
- **Structured logging.** Every request emits a Cloud Logging entry with
  caller identity, model, input/output token counts (pulled from Vertex's
  response), latency, and status. This is what powers the admin dashboard.
- **Header sanitation.** Claude Code occasionally sends `anthropic-beta`
  headers for experimental features. Vertex rejects unknown beta headers.
  The gateway drops them before forwarding. (Claude Code also supports
  `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` client-side, which we set in
  `settings.json` — the server-side strip is belt-and-suspenders.)
- **A single URL** that everyone configures, so you can rotate regions,
  quota projects, or routing logic in one place without reconfiguring every
  developer.

**What it is NOT:** a format translator. Claude Code already emits Vertex
format when `CLAUDE_CODE_USE_VERTEX=1`. The gateway does not rewrite
payloads. It is roughly 100 lines of FastAPI.

**Auth:** Cloud Run's built-in invoker IAM check is **disabled**
(`--no-invoker-iam-check` / `invoker_iam_disabled = true` in Terraform).
This is necessary because Claude Code sends **OAuth2 access tokens** (from
ADC), which Cloud Run IAM rejects — it only accepts OIDC identity tokens.
Instead, the gateway uses **app-level token validation** (`token_validation.py`
middleware) that accepts both token types and enforces an `ALLOWED_PRINCIPALS`
allowlist. Token validation is always on (`ENABLE_TOKEN_VALIDATION=1`).

**Ingress:** `all` in standard mode (developer laptops reach the service
directly; token validation is the security boundary). In GLB mode,
`internal-and-cloud-load-balancing` (only the GLB can reach it).

**Path normalization:** Claude Code omits the `/v1/` prefix from URL paths
when `ANTHROPIC_VERTEX_BASE_URL` is set (e.g. `/projects/P/locations/R/...`
instead of `/v1/projects/P/locations/R/...`). The gateway auto-prepends
`/v1/` when missing, so both path formats work.

**Identity:** dedicated service account with `roles/aiplatform.user` and
`roles/logging.logWriter`. That service account — not the caller — is what
authenticates to Vertex.

### 2. MCP Gateway (Cloud Run, FastMCP)

**Role:** a place for your organization to host custom
[Model Context Protocol](https://modelcontextprotocol.io/) tools that all
your Claude Code users share (e.g., "list GCS buckets in the current
project", "query our internal ticket system", "fetch this runbook").

**Transport:** [Streamable HTTP](https://modelcontextprotocol.io/docs/concepts/transports#streamable-http),
the March 2025 MCP spec standard. We do **not** use SSE — it's deprecated in
the current MCP spec.

**Framework:** [FastMCP](https://github.com/jlowin/fastmcp) — the most
ergonomic Python MCP server library and what Google's own examples use.

**Auth:** same model as the LLM gateway — Cloud Run invoker IAM is
disabled; app-level token validation middleware handles auth. Token
validation is always on.

The shipped server has one example tool (`gcp_project_info`). See
`mcp-gateway/ADD_YOUR_OWN_TOOL.md` for the beginner walkthrough.

### 3. Dev Portal (Cloud Run, nginx)

**Role:** a tiny IAP-protected static page that tells developers how to set
up Claude Code against this deployment — complete with the correct gateway
URL already filled in.

Why have a portal at all? Because "here is a URL, go figure it out" doesn't
scale. The portal has per-OS (macOS / Linux / Windows) copy-paste blocks and
a button to download `developer-setup.sh`. New team members hit the URL and
are self-service.

**Ingress:** In **GLB mode**, `internal-and-cloud-load-balancing` with IAP
enforced on the GLB backend — only Google identities in
`access.allowed_principals` can open the page. In **standard mode** (no GLB),
`--no-allow-unauthenticated` with `roles/run.invoker` grants per principal.

### 4. Dev VM (GCE, optional, off by default)

**Role:** a cloud dev environment. For teams where local installs are
disallowed, or where developers want a beefier machine than their laptop.

Two modes:

- **`shared`** *(default when enabled)* — one VM that all developers share
  via IAP SSH, each user getting their own Linux account via OS Login.
  Cheaper, but not isolated.
- **`per_user`** — one VM per developer. Stronger isolation, higher cost.
  The deploy script provisions one VM for each principal in
  `access.allowed_principals` matched by user prefix.

**No public IP.** SSH happens via IAP TCP tunneling:
`gcloud compute ssh --tunnel-through-iap <vm>`. Web access to VS Code Server
goes through an IAP-protected HTTPS load balancer.

**Auto-shutdown.** The startup script installs a systemd timer that powers
the VM off after `dev_vm.auto_shutdown_idle_hours` of no SSH connections, so
forgotten VMs don't rack up a bill.

### 5. Observability

A log sink in the project routes all logs tagged with
`resource.type="cloud_run_revision"` (filtered to our gateway services) into
a BigQuery dataset. A **built-in Admin Dashboard** (deployed as a Cloud Run
service by `deploy-observability.sh`) queries that dataset and gives admins:

- Requests per user per day
- Error rate over time
- Top token consumers (users and models)
- p50/p95/p99 latency by model

The dashboard auto-refreshes every 60 seconds. For a custom Looker Studio
alternative, see `observability/looker-studio-template.md`.

---

## Networking

### Vertex connectivity: Private Google Access (the default)

Cloud Run services configured with a VPC egress connector and Private Google
Access can reach `*.googleapis.com` **without traversing the public
internet**. Traffic stays on Google's backbone.

This is:

- **Free** (no per-GB NAT charges).
- **Private** (no public IPs involved).
- **Simple** (no extra resources beyond the subnet flag).

For a GCP-native deployment, this is almost always what you want, and it is
what this repo provisions by default.

### Private Service Connect: opt-in

If your developers are **not** in GCP — e.g., they're on an on-prem network
connected to GCP via Cloud Interconnect — Private Google Access alone isn't
enough, because the "private" path is from *within* the VPC. In that case
set `networking.use_psc: true`, and the TF will provision a PSC endpoint
for `googleapis.com` that your on-prem network can reach via the
interconnect.

PSC adds ~$7–10/month in forwarding rule costs, which is why it is off by
default.

### No public IPs

- Cloud Run gateways use `ingress=all` in standard mode (token validation
  is the security boundary) or `internal-and-cloud-load-balancing` in GLB
  mode.
- The dev VM is created with `--no-address`.
- Developer access is via ADC-authenticated requests (standard mode) or
  IAP (tunnel for SSH, IAP-protected HTTPS LB for web).

### Deployment-path compatibility (TF vs. gcloud scripts)

The Terraform path and the gcloud-scripts path provision the **same
components** but with different network topologies:

| | Terraform | gcloud scripts |
| --- | --- | --- |
| VPC | Custom `claude-code-vpc` | **Project default** network |
| Subnet PGA | Explicitly enabled on custom subnet | Default subnet's existing PGA setting |
| Serverless VPC Connector | Optional (`use_vpc_connector`) | Not provisioned |
| Dev VM network | Custom subnet | Default |
| IAP SSH firewall | Attached to custom VPC | Attached to default VPC |

Each path works correctly **in isolation**. **Do not mix them on the
same project.** If you `terraform apply` after using the gcloud scripts
(or vice versa), Terraform will propose moving resources between
networks — which is destructive for the dev VM (recreate) and
disruptive for the gateways (new URLs as the service is replaced).
Pick one path per deployment and stay on it.

If you want Terraform's VPC features (custom subnet, connector, PSC)
but already ran the gcloud path, the clean migration is:
`scripts/teardown.sh` → `cd terraform && terraform apply`.

---

## Authentication and authorization

There are exactly three auth flows, all using Google identity:

1. **Developer's laptop → Cloud Run gateway.** The developer runs
   `gcloud auth application-default login`. Claude Code sends
   **OAuth2 access tokens** (from ADC) to the gateway's `*.run.app`
   URL. Cloud Run's built-in invoker IAM check is **disabled**
   (`--no-invoker-iam-check`) because it only accepts OIDC identity
   tokens, not the access tokens Claude Code sends. Instead, the
   gateway's **app-level token validation middleware**
   (`token_validation.py`) verifies the token via Google's tokeninfo
   endpoint (access tokens) or public key verification (OIDC tokens),
   and enforces the `ALLOWED_PRINCIPALS` allowlist. An
   **unauthenticated** request is rejected by the middleware with
   401 (see Layer 6.1 in the e2e test suite).
2. **Developer's laptop → Dev VM.**
   `gcloud compute ssh --tunnel-through-iap`. IAP checks
   `roles/iap.tunnelResourceAccessor` + `roles/compute.osLogin`.
3. **LLM Gateway → Vertex AI.** The gateway's service account uses
   workload-identity-federated credentials (on Cloud Run, ADC just works).
   The SA has `roles/aiplatform.user` on the project.

No shared secrets. No API keys in dotfiles. No bearer tokens to rotate.

---

## Region selection

Default is `global`, which is the Vertex AI multi-region endpoint for
Anthropic models. It auto-routes to whichever regional backend has capacity,
gets new model versions first, and has no regional premium on token pricing.

Customers with data residency requirements should pick a specific region —
e.g., `europe-west3` (Frankfurt) for EU, `us-east5` (Columbus) for the most
mature Claude footprint. The interactive deploy shows the common list and
accepts free-form entry.

**Per-model regional override:** if you're on `global` and a specific model
(e.g., a just-released Haiku point release) isn't on `global` yet, set
`VERTEX_REGION_CLAUDE_HAIKU_4_5=us-east5` in the developer's settings to
route that one model to a specific region. The gateway honors this header.

---

## Model pinning

When `models.pin_versions: true` (the default), developer setup writes:

```json
{
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-6",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5@20251001"
  }
}
```

Pinning is **recommended** for enterprise rollouts — it prevents silent
behavior changes when Anthropic or Google promotes a new default. Unpin
when you want to track the rolling latest.

Note the two format flavors above:

- **Opus and Sonnet** are pinned at the major version (`-4-6`). Vertex
  does not publish dated point-release IDs for these today, so the
  major is the finest grain you can pin to.
- **Haiku** is the most actively refreshed of the three and Vertex
  exposes dated snapshots (`claude-haiku-4-5@20251001`). Pinning to
  the dated snapshot is strictly stricter than pinning to the major
  and protects against unexpected behavior changes between point
  releases.

When Google publishes a new dated snapshot for Haiku (or dated
snapshots become available for Opus / Sonnet), update
`terraform/variables.tf`'s defaults and the
`scripts/developer-setup.sh` fallbacks.

---

## What is intentionally NOT included

- **No custom domain by default.** Cloud Run's `*.run.app` URLs are used
  in standard mode. The optional GLB frontend supports two SSL modes:
  **(1) Google-managed certificate** with a custom domain (e.g.
  `claude.example.com`) — the deploy script auto-creates a DNS A record
  if Cloud DNS manages the parent zone; or **(2) self-signed certificate**
  for IP-only access — `NODE_TLS_REJECT_UNAUTHORIZED=0` is injected
  automatically into developer settings.
- **No multi-project or multi-region HA.** This is a reference deployment,
  not a fault-tolerant production SaaS. Vertex itself is highly available;
  the gateway scales to zero and back.
- **No paid tools / licenses.** Everything is OSS + Google services.
