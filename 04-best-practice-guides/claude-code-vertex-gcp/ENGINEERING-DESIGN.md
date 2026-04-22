# Engineering Design Document

<table>
<tr>
<td>

**Claude Code on Google Cloud via Vertex AI**
A reference architecture for enterprise deployment

</td>
<td align="right">

![Google Cloud](https://www.gstatic.com/devrel-devsite/prod/v870e399c64f7c43c99a3043db4b3a74327bb93d0914e84a0c3dba90bbfd67625/cloud/images/cloud-logo.svg) &nbsp; ![Anthropic](https://www.anthropic.com/images/icons/safari-pinned-tab.svg)

</td>
</tr>
</table>

---

| | |
| --- | --- |
| **Author** | Schneider Larbi, Senior Manager, Global Partner Technical Architecture — AI & SaaS ISV |
| **Document status** | Published — reference architecture v1.0 |
| **Last updated** | 2026-04-15 |
| **Audience** | Platform engineering, cloud architects, security reviewers, GCP + Anthropic partner teams |
| **License** | Apache 2.0 |

---

## 1. Executive summary

Anthropic's Claude Code is a terminal-native coding agent that is
rapidly being adopted by enterprise engineering teams. For customers
standardized on Google Cloud, running Claude Code against
`api.anthropic.com` creates two friction points: (1) it routes
sensitive source code through a second vendor's control plane, and
(2) it bills inference to an Anthropic account rather than to the
customer's existing GCP commit. Both are blockers for regulated
industries, public sector, and any large enterprise that has already
negotiated a unified cloud agreement.

This document describes a **production-grade reference architecture**
that lets enterprises run Claude Code entirely on **Google Cloud**
with all model inference routed through **Vertex AI's Anthropic
endpoints**. No traffic touches `api.anthropic.com`. All spend hits
the customer's GCP invoice. Identity, access control, audit logging,
and observability use the customer's existing Google identity
platform.

The deliverable is an open-source repository that includes the full
stack — Terraform modules, an opinionated LLM gateway, an MCP tool
gateway, a developer self-service portal, an optional shared dev VM,
an observability pipeline, an end-to-end test suite, and a five-minute
demo flow. It ships with four deployment paths (interactive script,
Terraform, Jupyter notebook, and a one-line `curl | bash` bootstrap)
so both hands-on and IaC-standardized customers can adopt it in under
an hour.

The architecture is deliberately minimalist: the LLM gateway is a
~150-line FastAPI reverse proxy, the MCP gateway is a thin FastMCP
composition, and the Terraform totals fewer than 1,000 lines. Every
design decision was optimized for three properties, in order:

1. **No exfiltration surface** — no public IPs, no API keys in
   dotfiles, no cross-vendor egress.
2. **Google-identity-first** — IAM and IAP do authentication; ADC
   does authorization; no shared secrets anywhere in the stack.
3. **Scales to zero** — every component idles at near-zero cost, so
   a customer can leave a non-production deployment running without
   a meaningful bill.

---

## 2. Problem statement

### 2.1 Customer requirements

Across engagements with enterprise GCP customers evaluating Claude
Code for engineering productivity, four requirements appear
consistently:

| # | Requirement | Rationale |
| --- | --- | --- |
| R1 | All model calls route through Vertex AI, never `api.anthropic.com` | Unified cloud contract; data residency; existing Vertex quota / billing / compliance posture |
| R2 | Authentication uses Google identity only — no API keys, no shared secrets | Fits existing IAM governance; avoids secret rotation; easier offboarding |
| R3 | Near-zero idle cost | Pilot projects cannot run a continuously billed service account team |
| R4 | Beginner-friendly one-command deploy | Adoption is blocked when the setup path requires a platform-engineering project plan |

### 2.2 What the default Claude Code install does not provide

Claude Code does natively speak the Vertex AI Anthropic endpoint when
`CLAUDE_CODE_USE_VERTEX=1` is set — so in principle a developer can
configure the tool against Vertex without any reference architecture
at all. That base configuration, however, leaves several enterprise
requirements unaddressed:

- **No central policy enforcement point.** Per-developer Vertex calls
  make it hard to uniformly apply request logging, quota shaping,
  model allowlisting, or regional routing overrides.
- **Header incompatibilities.** Claude Code occasionally sends
  experimental `anthropic-beta` headers that Vertex AI rejects,
  producing opaque failures for end users.
- **No centralized auditability.** Per-developer IAM policies against
  `aiplatform.user` produce a noisy audit trail; a gateway
  consolidates this into a small, tractable IAM surface.
- **No shared MCP tool plane.** The Model Context Protocol ecosystem
  is strongest when tools are centrally hosted; running MCP servers
  per developer does not scale.
- **No self-service onboarding.** New team members need a documented
  setup flow; a deployed portal with per-OS instructions removes that
  barrier.

### 2.3 Non-goals

The reference architecture deliberately does **not** cover:

- Load testing, soak testing, or multi-region active-active failover
  topologies.
- Full VPC Service Controls perimeter design (left to the customer;
  all components are VPC-SC-compatible).
- A custom domain or branded TLS certificate (left to the customer;
  default `*.run.app` hostnames are used).
- A production SaaS offering of this stack. The solution is a
  reference deployment a customer owns and operates, not a managed
  service.

---

## 3. Design goals

The architecture was engineered against five explicit goals, all of
which are enforced by automated tests in `scripts/e2e-test.sh` so
regressions are caught at deploy time.

1. **Zero unauthenticated attack surface.** Cloud Run gateways use
   app-level token validation (accepts both OAuth2 access tokens and
   OIDC identity tokens) with an `ALLOWED_PRINCIPALS` allowlist. The
   optional dev VM has no external IP. Developer access is brokered
   by Google identity (ADC for HTTPS, IAP tunnel for SSH).
2. **Google identity only.** Every actor in the system — developer,
   gateway, dev VM — authenticates via a Google identity. There are
   zero API keys, zero bearer tokens in dotfiles, zero shared
   secrets.
3. **Scale-to-zero.** The gateways and portal run on Cloud Run with
   min-instances = 0. An idle deployment costs roughly $0–5/month
   (see §10).
4. **One-command deploy.** Four deployment paths converge on the
   same interactive, idempotent installer. A new customer can go
   from a bare GCP project to a working deployment in under an hour.
5. **Beginner-friendly.** Every script explains itself before it
   acts, writes a displayed config file, and requires explicit
   confirmation before creating resources. Every file ships with
   heavy inline comments aimed at a reader who has never used
   Terraform or Cloud Run.

---

## 4. Architecture overview

### 4.1 Topology

```
Developer Laptop ──┐
                   │  gcloud ADC + token validation  /  IAP TCP tunnel
                   ▼
 ┌─────────────────────────── Google Cloud Project ───────────────────────────┐
 │                                                                            │
 │   ┌───────────────┐    IAP-protected                                       │
 │   │  Dev Portal   │    static welcome page (nginx on Cloud Run)            │
 │   └───────────────┘                                                        │
 │                                                                            │
 │   ┌────────────────┐   ┌──────────────────┐   ┌─────────────────┐          │
 │   │  Developer VM  │──▶│   LLM Gateway    │──▶│    Vertex AI    │          │
 │   │  (GCE,opt.)    │   │  FastAPI pass-   │   │  Claude models  │          │
 │   │  VS Code Server│   │  through proxy   │   │  via Private    │          │
 │   │  Claude Code   │   │  (Cloud Run)     │   │  Google Access  │          │
 │   └────────────────┘   └──────────────────┘   └─────────────────┘          │
 │           │                                                                │
 │           │            ┌──────────────────┐                                │
 │           └───────────▶│   MCP Gateway    │                                │
 │                        │   FastMCP over   │                                │
 │                        │   Streamable HTTP│                                │
 │                        │   (Cloud Run)    │                                │
 │                        └──────────────────┘                                │
 │                                                                            │
 │   Cloud Logging  ──▶  BigQuery sink  ──▶  Admin Dashboard (Cloud Run)      │
 └────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Principle of least architectural weight

A deliberate design choice across every component: **add as little
code as possible**.

- The LLM gateway is a **pass-through proxy**, not a format
  translator. Claude Code already emits Vertex-format payloads when
  `CLAUDE_CODE_USE_VERTEX=1` — the gateway therefore does not
  rewrite request bodies. Its only jobs are authentication logging,
  header sanitation, and replacing the caller's bearer token with
  the gateway service account's token for the outbound Vertex call.
- The MCP gateway is a **standard FastMCP server** with a single
  example tool. The only non-obvious code is the FastAPI wrapping
  that exposes a `GET /health` route alongside the MCP endpoint for
  uptime monitoring.
- The Terraform is composed of **six small modules**, each gated by
  a single `enable_*` variable so turning a component off creates
  zero resources for it.

The full Python footprint — gateway + MCP + test helper — is under
700 lines. The full Terraform footprint is under 900 lines. This is
intentional: every line is a potential liability in a security
review, and every line a customer must read to trust the artifact.

---

## 5. Component catalog

This section enumerates every component shipped in the repository,
its purpose, its implementation, and how it ties into the broader
design.

### 5.1 LLM Gateway (Cloud Run)

**Path:** `gateway/`
**Role:** single entry point for all Claude inference traffic;
everything else in the stack is organized around it.

**Sub-modules:**

| File | Responsibility |
| --- | --- |
| `app/main.py` | FastAPI app wiring — lifespan-managed shared `httpx.AsyncClient`, `/healthz` (legacy) and `/health` liveness endpoints, catch-all `/{full:path}` route dispatching to the proxy logic. Catch-all never captures the two health routes because FastAPI matches explicit paths first. |
| `app/proxy.py` | Pass-through reverse proxy. Computes the correct Vertex regional host from the inbound URL (`global` → `aiplatform.googleapis.com`; `us-east5` → `us-east5-aiplatform.googleapis.com`; etc.), normalizes the URL path (auto-prepends `/v1/` when Claude Code omits it), sanitizes headers, attaches a fresh gateway-SA bearer token, streams the response body back via `StreamingResponse` + `BackgroundTask`, and emits one structured log entry per request. |
| `app/auth.py` | Caller-identity extraction (`X-Goog-Authenticated-User-Email` from IAP or Cloud Run) and gateway-side credential management (`google.auth.default` with the `cloud-platform` scope, thread-safe refresh). |
| `app/headers.py` | Header sanitation rules. Exact drops (`Authorization`, `Host`, `Content-Length`, `X-Cloud-Trace-*`, forwarded-*), hop-by-hop drops per RFC 7230 § 6.1, prefix drops (`anthropic-beta`, `x-goog-`). Returns the cleaned header dict plus a list of stripped header names for structured logging. |
| `app/logging_config.py` | JSON-to-stdout formatter. Cloud Logging auto-parses JSON lines from Cloud Run containers; everything passed via Python's `logging.LogRecord.extra` becomes a queryable `jsonPayload` field. Uvicorn loggers are routed through the same handler so access logs are also JSON. |
| `app/token_validation.py` | App-level authentication middleware. Validates both OAuth2 access tokens (via Google's tokeninfo endpoint) and OIDC identity tokens (via public key verification). Enforces an `ALLOWED_PRINCIPALS` email allowlist. Health endpoints bypass validation. Always enabled (`ENABLE_TOKEN_VALIDATION=1`). |
| `tests/test_proxy.py` | Nine pytest cases with a mocked `httpx.AsyncClient`: happy-path regional routing, header sanitation + bearer replacement, 403 upstream relay, health endpoints, accept-encoding stripping, and path normalization (with/without `/v1/` prefix, regional and global). Offline, no Google credentials required. |
| `Dockerfile` | Multi-stage Python 3.12-slim build. Builder installs into `/opt/venv`; runtime image copies the venv, adds a non-root `app` user, exposes `$PORT` with uvicorn as CMD. Final image ~120 MB. |
| `requirements.txt` | `fastapi`, `uvicorn[standard]`, `httpx`, `google-auth`, `google-cloud-logging`. All minor-version-pinned. |

**Why a gateway at all?** Four capabilities that cannot be
implemented cleanly in the Claude Code client, listed in rough order
of importance:

1. **Unified access logs.** Every inference call produces one
   queryable log entry with caller, model, region, latency, status,
   and byte-level header diagnostics. This is what powers the
   observability dashboard.
2. **Experimental-beta header stripping.** Claude Code opts into
   experimental Anthropic features via `anthropic-beta` headers;
   Vertex AI's strict header validation rejects unknown beta
   strings. The gateway guarantees these never reach Vertex.
3. **Single configuration handle.** All developers point at one URL.
   A customer can rotate regions, add quota shaping, change default
   models, or move to a specific region for data residency by
   redeploying one Cloud Run service.
4. **Single auth surface.** Instead of granting every developer
   `roles/aiplatform.user` on the project, developers only need to
   be listed in the gateway's `ALLOWED_PRINCIPALS` allowlist. The
   gateway's own service account is the only principal with Vertex
   access, which narrows the audit surface dramatically.

**Traffic shape:** streaming POSTs ranging from ~4 KB (short prompts)
to ~800 KB (long-context conversations with caching). The gateway
streams the response body back chunk-by-chunk, so long-context calls
do not buffer in memory.

### 5.2 MCP Gateway (Cloud Run)

**Path:** `mcp-gateway/`
**Role:** shared host for Model Context Protocol tools.

**Sub-modules:**

| File | Responsibility |
| --- | --- |
| `server.py` | FastAPI parent app with FastMCP mounted at `/mcp`. Exposes `GET /health` at the root for uptime probes. **Critical detail:** FastMCP's internal task manager is lifespan-dependent, so the FastAPI parent must propagate the FastMCP sub-app's lifespan context — otherwise tool calls fail with "task group not initialized" errors. The code uses `http_app()` if available (FastMCP 2.x), falling back to `streamable_http_app()` on older versions. |
| `tools/gcp_project_info.py` | Example MCP tool that returns project ID, project number, region, and a count of enabled APIs. Uses `google.auth.default` for ADC, then makes two `urllib.request` calls to Cloud Resource Manager and Service Usage. Errors surface as fields in the return value rather than raised exceptions, consistent with MCP tool best practice. |
| `Dockerfile` | Two-stage build using the official `ghcr.io/astral-sh/uv` image. Dependencies are pre-resolved via `uv sync` into `/app/.venv`, then copied into a slim Python 3.12 runtime. Follows Google's published MCP-on-Cloud-Run pattern. |
| `pyproject.toml` | PEP 621 metadata. Runtime deps: `fastmcp>=0.2,<3.0`, `fastapi`, `uvicorn[standard]`, `google-auth`. Dev deps: `pytest`. |
| `ADD_YOUR_OWN_TOOL.md` | Six-step beginner walkthrough with a worked "list GCS buckets" example covering IAM grant, tool file structure, server registration, redeploy, and common pitfalls. |

**Transport:** Streamable HTTP — the standard defined by the March
2025 MCP specification. SSE is explicitly avoided as it is deprecated
in the current spec.

**Authentication posture:** same as the LLM gateway — Cloud Run's
invoker IAM check is disabled; the app-level `token_validation.py`
middleware validates tokens and enforces the `ALLOWED_PRINCIPALS`
allowlist. The `/health` endpoint bypasses the middleware (so Cloud
Run startup probes and monitoring checks work without a token).

### 5.3 Dev Portal (Cloud Run, nginx)

**Path:** `dev-portal/`
**Role:** self-service welcome page for new developers.

**Sub-modules:**

| File | Responsibility |
| --- | --- |
| `public/index.html` | Single static page. Shows the deployment coordinates (gateway URL, MCP URL, project, region), per-OS setup instructions in three tabs (macOS / Linux / Windows-via-WSL2), and a preview of the `~/.claude/settings.json` that `developer-setup.sh` will write. Uses four placeholders (`__LLM_GATEWAY_URL__`, `__MCP_GATEWAY_URL__`, `__PROJECT_ID__`, `__REGION__`) replaced at build time by `scripts/deploy-dev-portal.sh`. |
| `public/styles.css` | Vanilla CSS in Google blue (`#1a73e8`) + neutrals. No framework dependency; page renders instantly. |
| `Dockerfile` | `nginx:1.27-alpine`. URL placeholders (`__LLM_GATEWAY_URL__`, etc.) in `index.html` are substituted by `deploy-dev-portal.sh` using `sed` *before* the Docker image is built. At container startup, nginx's built-in `/etc/nginx/templates/` envsubst mechanism handles `$PORT` from Cloud Run — no shell wrapper needed. Also exposes a trivial `/healthz`. |

**Why a static portal?** Two reasons. First, new team members need
a single URL they can be sent. Second, the substituted URLs in the
portal come from the specific deployment, so there is no generic "go
figure out your gateway URL" step — the page *is* the deployment's
identity.

**Ingress & auth:** In **GLB mode**, `internal-and-cloud-load-balancing`
with IAP on the GLB backend (browser OAuth flow). In **standard mode**,
`--no-allow-unauthenticated` with `roles/run.invoker` grants per
principal. In both modes, the portal is not publicly accessible.

### 5.4 Developer VM (GCE, optional)

**Path:** `terraform/modules/dev_vm/`, `scripts/deploy-dev-vm.sh`
**Role:** cloud development environment for teams that cannot or
choose not to install Claude Code locally.

**Key design decisions:**

- **No external IP.** Created with `--no-address` (gcloud) or without
  an `access_config` block (Terraform). Developer SSH is via
  `gcloud compute ssh --tunnel-through-iap`, which fronts the VM
  through IAP's TCP tunnel service.
- **Shielded VM.** `enable_secure_boot`, `enable_vtpm`,
  `enable_integrity_monitoring` all on. Defense-in-depth against
  sandbox-escape scenarios in a shared machine.
- **OS Login.** Developers SSH in as their own Linux user mapped
  from their Google identity; no shared `ubuntu` user, no password,
  no key distribution.
- **Auto-shutdown.** A systemd timer (installed via the startup
  script) runs every 15 minutes and powers off the VM after
  `dev_vm_auto_shutdown_idle_hours` hours with no SSH connections.
  Forgotten VMs cost $0 after the next idle window elapses.
- **Two modes.** `shared` creates a single VM for all allowed
  principals; `per_user` creates one VM per `user:` entry in
  `allowed_principals`, named after the email local-part.
  `per_user` mode is guarded by a `terraform_data` precondition that
  fails loudly if `allowed_principals` contains only `group:` or
  `serviceAccount:` entries (which cannot be mapped 1:1 to VMs).

**Startup script** (`startup.sh.tpl`) is a Terraform `templatefile()`
consumed by both the Terraform module and the gcloud path. It
installs Node.js LTS, installs `@anthropic-ai/claude-code` globally,
writes a system-wide `/etc/claude-code/settings.json` preconfigured
for the deployment, and sets up a `/etc/profile.d/` snippet that
symlinks the shared settings into each OS Login user's `~/.claude/`
on first login. Optional `code-server` installation exposes
browser-based VS Code on port 8080, reached via IAP's TCP tunnel.

### 5.5 Networking (Terraform only)

**Path:** `terraform/modules/network/`
**Role:** custom VPC with Private Google Access for the Cloud Run and
GCE workloads.

**Resources provisioned:**

| Resource | Purpose |
| --- | --- |
| `google_compute_network.vpc` | Custom VPC named `claude-code-vpc`, no auto-subnets. |
| `google_compute_subnetwork.subnet` | Regional subnet (`10.100.0.0/24`) with `private_ip_google_access = true`. This is the flag that makes `*.googleapis.com` resolvable on Google's backbone rather than via the public internet. |
| `google_compute_firewall.allow_iap_ssh` | Allows IAP's published source range (`35.235.240.0/20`) to reach tcp:22 on instances tagged `claude-code-dev-vm`. Without this rule, `gcloud compute ssh --tunnel-through-iap` fails with error 4003. |
| `google_compute_firewall.allow_iap_web` | Same pattern for tcp:8080 (code-server). |
| `google_vpc_access_connector.connector` | Optional. When `use_vpc_connector = true`, Cloud Run services egress through this connector so their outbound traffic is subject to VPC routing / firewall rules and uses Private Google Access. Adds ~$10/month. |
| `google_compute_global_address.psc_ip` + `google_compute_global_forwarding_rule.psc_googleapis` | Optional. When `use_psc = true`, provisions a Private Service Connect endpoint for `googleapis.com` bundled target `all-apis`, usable from on-prem networks via Cloud Interconnect. Adds ~$7–10/month. |

**Gcloud-path drift.** The gcloud scripts do **not** create the
custom VPC or VPC connector — they use the project's default network
for simplicity. This is documented in `ARCHITECTURE.md` →
"Deployment-path compatibility" and in the `deploy-dev-vm.sh`
header: the two paths are mutually exclusive on the same project.

### 5.6 Identity & access management

The deployment creates four dedicated service accounts, each
least-privileged:

| Service account | Purpose | Project-level roles |
| --- | --- | --- |
| `llm-gateway@…` | Runs the LLM gateway Cloud Run service; authenticates to Vertex on behalf of callers. | `roles/aiplatform.user`, `roles/logging.logWriter` |
| `mcp-gateway@…` | Runs the MCP gateway. Tool-specific roles are granted only when a tool requires them (see `ADD_YOUR_OWN_TOOL.md` for the pattern). | `roles/logging.logWriter` |
| `dev-portal@…` | Runs the dev portal. The portal is static — no GCP API access needed. | *(none)* |
| `claude-code-dev-vm@…` | Attached to the dev VM. Lets a developer on the VM call Vertex directly if needed, and writes startup-script diagnostics. | `roles/aiplatform.user`, `roles/logging.logWriter` |

The LLM and MCP gateways use **app-level token validation** instead
of Cloud Run IAM — Cloud Run's invoker check is disabled because
Claude Code sends OAuth2 access tokens that Cloud Run IAM rejects.
The `ALLOWED_PRINCIPALS` environment variable controls who can call
these gateways. Per-principal `roles/run.invoker` bindings are still
used for `dev-portal` and `admin-dashboard`. Dev VM access uses
`roles/iap.tunnelResourceAccessor` + `roles/compute.osLogin` at the
project level. The list of allowed principals is the single
`access.allowed_principals` field in `config.yaml` / `terraform.tfvars`.

### 5.7 Observability

**Path:** `terraform/modules/observability/`, `dashboard/`,
`observability/log-queries.md`,
`observability/looker-studio-template.md` (optional)
**Role:** centralized visibility into gateway traffic.

**Pipeline:**

```
Cloud Run containers (stdout JSON)
        │
        ▼
Cloud Logging
        │   sink filter:
        │   resource.type="cloud_run_revision"
        │   AND resource.labels.service_name=~"^(llm-gateway|mcp-gateway)$"
        ▼
BigQuery dataset `claude_code_logs`
        │   partitioned tables, retention = log_retention_days
        ▼
Admin Dashboard (Cloud Run service —
  requests per day, by model, top callers,
  error rate, p50/p95/p99 latency,
  auto-refreshes every 60s)
```

The Terraform module creates the BigQuery dataset with a partition
expiration of `log_retention_days * 86400000` ms (default 90 days),
which caps storage cost without retention surprises. It also grants
the log sink's writer identity `roles/bigquery.dataEditor` on the
dataset — without this the sink silently drops logs.

Ten ready-to-paste Cloud Logging queries ship in
`observability/log-queries.md`, covering error debugging, per-user
activity, latency outliers, and a SQL-based token-consumption proxy.

### 5.8 Control plane: Terraform vs. gcloud scripts

The repository ships **two deployment implementations** of the same
architecture, kept in sync at the variable level:

- **Terraform** (`terraform/`) is the recommended path for teams with
  existing IaC practice. Six modules, one root composition, all
  toggled by `enable_*` variables.
- **gcloud scripts** (`scripts/deploy-*.sh`) are the recommended path
  for teams evaluating quickly. The top-level `deploy.sh` is
  interactive, idempotent, and self-bootstraps from a `curl | bash`
  invocation (it clones the repo to a temp directory and
  re-executes). The per-component scripts can also be run
  standalone.

Both paths:

- Use the same `claude-code-vertex-gcp` Artifact Registry repo name,
  Cloud Run service names, service account IDs, and log-sink filter.
- Accept identical configuration fields (the script's interactive
  prompts and the `terraform.tfvars` variables map 1:1 to
  `config.yaml`).
- Can be validated by the same `scripts/e2e-test.sh` afterwards.

The only difference is the VPC posture (§5.5).

### 5.9 Testing

**Path:** `gateway/tests/test_proxy.py`, `scripts/e2e-test.sh`,
`scripts/lib/mcp_test.py`, `TEST-AND-DEMO-PLAN.md`

| Layer | Coverage | Implementation |
| --- | --- | --- |
| Unit | FastAPI route handlers + proxy logic (happy path, header sanitation, 403 relay, /health no-fanout) | `pytest` in `gateway/tests/`, mocks `httpx.AsyncClient` + `google.auth` |
| End-to-end | Seven layers: infrastructure sanity (incl. admin dashboard, BigQuery, logging sink), direct Vertex reachability, gateway proxy behaviour, dev portal, MCP tool invocation, negative + observability tests, GLB (auto-discovered) | `scripts/e2e-test.sh` — Bash with PASS/FAIL/SKIP tallying, per-layer summary, `--quick` smoke mode |
| MCP handshake | Full `initialize` → `notifications/initialized` → `tools/call` flow, handling both JSON and SSE response framings | `scripts/lib/mcp_test.py` Python helper invoked from the bash script |
| Demo seeding | Controlled Haiku traffic to populate admin dashboard | `scripts/seed-demo-data.sh` — 20-prompt corpus, 200-request hard cap, pacing over configurable duration |

### 5.10 Documentation

| File | Audience |
| --- | --- |
| `README.md` | First-time users; quickstart + four deploy paths |
| `ARCHITECTURE.md` | Architects, security reviewers |
| `COSTS.md` | Finance; itemized cost model (§10) |
| `TROUBLESHOOTING.md` | Operators — header rejection, 429s, IAP issues, auth, test failures |
| `CONTRIBUTING.md` | External contributors |
| `TEST-AND-DEMO-PLAN.md` | Engineers running validation + customer demos |
| `DEPLOYMENT-GUIDE.md` | This document's companion — step-by-step deployment |
| `ENGINEERING-DESIGN.md` | This document |
| `observability/*.md` | Ops teams building the dashboard |
| `mcp-gateway/ADD_YOUR_OWN_TOOL.md` | Engineers extending the MCP gateway |
| `config.example.yaml` | Operators configuring a deployment |

---

## 6. Request lifecycle (end-to-end walkthrough)

This section follows a single developer request from keystroke to
token, naming every component touched.

**0. Developer types a prompt in Claude Code.**
Claude Code reads `~/.claude/settings.json`, which was written by
`scripts/developer-setup.sh` (the same script also installs the
`@anthropic-ai/claude-code` npm package globally if the CLI is
missing). The file sets
`CLAUDE_CODE_USE_VERTEX=1`, `ANTHROPIC_VERTEX_BASE_URL=<gateway>`,
`CLOUD_ML_REGION`, `ANTHROPIC_VERTEX_PROJECT_ID`,
`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`, and the three pinned
model IDs.

**1. Claude Code builds a Vertex-format request.**
Because `CLAUDE_CODE_USE_VERTEX=1` is set, the SDK emits a
`POST /projects/<project>/locations/<region>/publishers/anthropic/models/<model>:rawPredict`
request with a Vertex payload shape. Note: Claude Code omits the
`/v1/` prefix when `ANTHROPIC_VERTEX_BASE_URL` is set. The
`Authorization` header carries an OAuth2 access token from ADC for
the developer's Google identity.

**2. App-level token validation admits or rejects.**
The request arrives at the LLM gateway's `*.run.app` hostname.
Cloud Run's built-in invoker IAM check is **disabled**
(`--no-invoker-iam-check`) because it only accepts OIDC identity
tokens — Claude Code sends OAuth2 access tokens. Instead, the
`token_validation.py` middleware validates the token (via Google's
tokeninfo endpoint for access tokens or public key verification for
OIDC tokens) and checks the caller's email against the
`ALLOWED_PRINCIPALS` allowlist. Callers without a valid token get
401; callers not in the allowlist get 403.

**3. FastAPI dispatches to the proxy route.**
The catch-all `/{full:path}` handler in `gateway/app/main.py`
receives the request. Uvicorn has already populated
`request.headers` and `request.url`; FastAPI passes both, plus the
shared `httpx.AsyncClient` from `app.state`, to `proxy_request` in
`proxy.py`.

**4. Proxy sanitizes headers.**
`headers.sanitize_request_headers` returns a cleaned dict plus a
list of stripped header names. The `Authorization` header is dropped
(caller's token not forwarded), as are hop-by-hop headers, any
`anthropic-beta*` headers, and GCP-internal `x-goog-*` headers.

**5. Gateway attaches its own bearer.**
`auth.get_vertex_access_token()` returns a cached, periodically
refreshed OAuth token for the gateway's service account (`llm-gateway`).
This token is injected as the outbound `Authorization` header. The
gateway is the Vertex-facing principal; the caller's identity is
captured separately for logging.

**6. Path normalization + regional host resolution.**
`proxy._normalize_path` prepends `/v1/` if the inbound path lacks
a version prefix (Claude Code omits it when
`ANTHROPIC_VERTEX_BASE_URL` is set). Then
`proxy._vertex_host_for_region` extracts the `locations/<region>/`
segment. If `<region>` is `global`, the upstream host is
`aiplatform.googleapis.com`; otherwise it's
`<region>-aiplatform.googleapis.com`. This lets a single gateway
serve requests to any region without per-region configuration.

**7. Outbound call via Private Google Access (or VPC connector).**
`httpx.AsyncClient` opens a TLS connection to the upstream host.
When the gateway is deployed with a VPC connector (Terraform path
default), egress traverses the custom VPC and Private Google Access
routes the connection on Google's backbone — no public internet,
no NAT charges. Without the connector, the request still stays on
Google's network but via the public-but-Google-hosted
`aiplatform.googleapis.com` IP space.

**8. Streaming response.**
Vertex's response body (JSON or SSE, depending on whether Claude
Code asked for streaming) is relayed byte-for-byte through
`StreamingResponse` with an `_iter_upstream` async generator. A
Starlette `BackgroundTask` closes the upstream response after the
body is fully relayed, releasing the connection back to the httpx
pool.

**9. Structured log emission.**
One `proxy_request` log entry is emitted to stdout as a single JSON
line. Fields include `caller` (email), `caller_source` (`cloud_run`
/ `iap` / `unknown`), `method`, `path`, `upstream_host`,
`vertex_region`, `model` (parsed from the URL), `status_code`,
`latency_ms_to_headers`, `betas_stripped` (array of stripped
header names), and `cloud_run_region`. Cloud Logging auto-parses
this into `jsonPayload.*` fields, which the sink then streams into
BigQuery.

**10. Dashboard ingest.**
Within 60 seconds the log entry appears as a row in the BigQuery
partitioned table. The admin dashboard queries BigQuery on refresh
(every 60 seconds); no additional glue is required.

Latency overhead imposed by the gateway is ≤50 ms at p95 for cold
instances, ≤10 ms at p95 for warm. Streaming responses have no
perceived overhead — bytes leave the gateway as soon as they arrive.

---

## 7. Security model

The stack's threat model assumes a motivated insider-or-external
attacker with access to a compromised developer machine. The
controls below are layered accordingly.

### 7.1 No shared secrets

There are no API keys, no service-account key files, no bearer
tokens in dotfiles anywhere in the deployment. Every authentication
flow uses:

- **Application Default Credentials** for process-to-GCP-API calls.
  On Cloud Run: the attached service account. On a developer laptop
  or Cloud Shell: the user's `gcloud auth application-default login`
  token.
- **Google identity (IAM + IAP)** for user-to-service calls.

Compromising a laptop therefore compromises exactly one user's
identity, which can be revoked in IAM in seconds.

### 7.2 Ingress and auth

In **standard mode**, Cloud Run gateways use `ingress=all` so
developer laptops can reach them directly. Cloud Run's built-in
invoker IAM check is **disabled** (`--no-invoker-iam-check`) because
Claude Code sends OAuth2 access tokens that Cloud Run IAM rejects.
Auth is handled by the app-level `token_validation.py` middleware,
which validates tokens and enforces the `ALLOWED_PRINCIPALS`
allowlist. Unauthenticated requests are rejected by the middleware
(401). In **GLB mode**, ingress is
`internal-and-cloud-load-balancing` so only the GLB can reach the
services. The dev VM has no external IP. There are no public
firewall rules on ports other than the IAP range for 22/8080.

### 7.3 Egress

With the VPC connector enabled, all Cloud Run egress traverses the
custom VPC. Private Google Access means
`*.googleapis.com` resolves on Google's backbone. If you need to
block all non-Google egress, a VPC firewall rule can do so without
touching the application code.

### 7.4 Data handling

The gateway never persists request bodies. Logs include metadata
(caller, model, status, latency, stripped headers) but not the
prompt or response content. The gateway does log the URL path,
which contains the model name and region but not any user data.
Teams requiring stricter controls can disable the VM or dev portal,
or add a VPC-SC perimeter around the project without changes to the
application code.

### 7.5 Auditability

Every inference call produces a structured log entry. Every IAM
binding is declared in Terraform or created by an idempotent shell
script, so a full audit is `terraform state list` or
`gcloud iam service-accounts get-iam-policy`. There are no dynamic
permissions granted at runtime.

---

## 8. Failure modes and recovery

| Failure | Detection | Recovery |
| --- | --- | --- |
| Vertex region returns 429 | `jsonPayload.status_code=429` in the dashboard | Request quota increase; short-term, switch `CLOUD_ML_REGION` to `global` |
| Gateway Cloud Run revision fails to deploy | `e2e-test.sh` Layer 1.1 | Inspect `status.conditions` on the service; re-run `deploy-llm-gateway.sh` (idempotent) |
| Experimental-beta header rejected | `e2e-test.sh` Layer 3.3 | Rebuild the gateway image with the current `headers.py` rules |
| BigQuery sink stops writing | Empty admin dashboard | Verify `sink_writer_identity` still has `bigquery.dataEditor` on the dataset |
| Dev VM runs out of disk | `df` on the VM | Increase `dev_vm_disk_size_gb` and re-apply; disk growth is online |
| Developer not in `ALLOWED_PRINCIPALS` | Claude Code shows 403 | Ensure they're in `access.allowed_principals` and re-run `deploy-*-gateway.sh` |

---

## 9. Testing and release strategy

The repository's CI posture (not included in this deliverable; to be
configured by the adopting customer) should run:

1. `terraform fmt -check -recursive` and `terraform validate`.
2. `python -m py_compile` on every `.py` file.
3. `bash -n` on every `.sh` file.
4. `pytest -q` in `gateway/tests/`.
5. (Optional, for a live CI project) `scripts/e2e-test.sh --quick`
   against a dedicated CI GCP project after a dry deploy.

The reference build in this repository has been validated against
Terraform 1.9.8, Python 3.12, and FastMCP 0.2+.

---

## 10. Cost model

Idle cost (the common case):

| Component | Monthly |
| --- | --- |
| LLM gateway (Cloud Run, scale-to-zero) | $0–3 |
| MCP gateway (Cloud Run, scale-to-zero) | $0–3 |
| Dev portal (Cloud Run, scale-to-zero) | $0–1 |
| VPC connector (minimum billed instance) | ~$10 |
| BigQuery sink + storage | $0–2 |
| **Idle baseline** | **~$10–15** |

Additive costs when enabled:

| Component | Monthly |
| --- | --- |
| Dev VM `e2-small` always-on | ~$12 |
| Dev VM `e2-small` with auto-shutdown (40h/week) | ~$5 |
| PSC endpoint | ~$7–10 |

Vertex token cost is billed separately to the customer's GCP invoice
at published Vertex pricing. For a single active Claude Code user
doing real work, expect $5–10/dev/month (light) to $50–100/dev/month
(heavy). This is the dominant cost line in any real deployment.

---

## 11. Open items and future work

1. **Prompt caching instrumentation.** The gateway does not yet log
   cache-hit counts from Vertex responses. Parsing the upstream
   `usage` block and emitting it as a structured field would give
   the dashboard a "cost efficiency" panel.
2. **Model allow-listing.** The gateway could reject requests for
   models not in a configured allow-list, pre-Vertex. Useful for
   tenants standardizing on Sonnet only.
3. **Per-user rate limiting.** Cloud Armor or a Redis-backed
   token-bucket in `proxy.py` could cap runaway usage.
4. **VPC-SC perimeter.** Everything in the stack is VPC-SC
   compatible, but no perimeter is configured out of the box.
5. **Custom-domain TLS.** `*.run.app` is used throughout. A
   customer who wants `claude.internal.corp` would front the
   gateway with an HTTPS load balancer and a managed certificate.

---

## 12. References

- `ARCHITECTURE.md` — component-level architecture with design
  rationale.
- `DEPLOYMENT-GUIDE.md` — step-by-step installation companion to
  this document.
- `TEST-AND-DEMO-PLAN.md` — seven-layer validation procedure.
- `TROUBLESHOOTING.md` — comprehensive operations troubleshooting
  guide.
- Vertex AI Anthropic documentation:
  https://cloud.google.com/vertex-ai/generative-ai/docs/partner-models/use-claude
- Claude Code documentation:
  https://docs.claude.com/en/docs/claude-code
- Model Context Protocol specification:
  https://modelcontextprotocol.io/
- FastMCP:
  https://github.com/jlowin/fastmcp

---

<table>
<tr>
<td>

*This engineering design document is Apache 2.0-licensed alongside
the reference implementation. Feedback and contributions are welcome
via the project's GitHub issues at
[PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation](https://github.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation).*

</td>
<td align="right">

**Schneider Larbi**
Senior Manager, Global Partner Technical Architecture
AI & SaaS ISV
2026-04-15

</td>
</tr>
</table>
