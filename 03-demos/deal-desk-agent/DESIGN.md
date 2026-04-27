# Deal Desk Agent — Engineering Design Document

**Multi-Agent FSI Client Onboarding System**

| Field | Value |
|---|---|
| Version | 1.1 |
| Last updated | April 2026 |
| Status | Production (NEXT 2026 demo) |
| Owners | Partner Technical Architecture |
| Audience | Engineers, SREs, security reviewers |

---

## Table of Contents

1. [Overview and goals](#1-overview-and-goals)
2. [System architecture](#2-system-architecture)
3. [Data model](#3-data-model)
4. [Agent pipeline design](#4-agent-pipeline-design)
5. [Security and auth model](#5-security-and-auth-model)
6. [Deployment topology](#6-deployment-topology)
7. [Operational runbook](#7-operational-runbook)
8. [Learnings and best practices](#8-learnings-and-best-practices)
9. [Known limitations](#9-known-limitations)
10. [Future work](#10-future-work)

---

## 1. Overview and Goals

The Deal Desk Agent is a multi-agent AI system that automates FSI client onboarding end-to-end: from natural-language intake through research, compliance, risk scoring, deal package synthesis, BigQuery persistence, and live Salesforce Opportunity creation via browser automation.

### 1.1 Goals

- Demonstrate Claude on Vertex AI orchestrated by Google ADK in a production-realistic FSI workflow
- Show model tiering: Opus for reasoning, Sonnet for structured tasks, Haiku for fast computation
- Integrate Computer Use API on Vertex AI to drive a real Salesforce instance
- Expose the agent via A2A protocol for Gemini Enterprise discovery
- Keep operational footprint small enough to run as a booth demo

### 1.2 Non-goals

- Production-grade throughput (single-tenant demo system)
- Salesforce login automation (Computer Use cannot reliably handle login/MFA flows)
- Multi-region failover (single region `us-central1` for infra, `us-east5` for models)
- Persistent user sessions (ephemeral `InMemorySessionService` for the ADK runner)

### 1.3 Key design decisions

- **Claude on Vertex AI over direct Anthropic API** — Demo objective is Anthropic + Google Cloud integration. Vertex AI provides IAM, VPC-SC, logging, billing in one place.
- **ADK over custom orchestration** — ADK's `ParallelAgent` / `SequentialAgent` primitives map directly to the pipeline structure. Event streaming is built-in.
- **Cloud Run for backend + frontend** — Serverless scale-to-zero between demos. 15-minute request timeout covers the full pipeline.
- **GCE VM for browser automation** — Cloud Run cannot run persistent browser processes. GCE gives us Xvfb + Chrome + noVNC in one container.
- **`type: "custom"` for Computer Use on Vertex** — The native `computer_20250124` tool type returns 400 on Vertex `rawPredict`; `anthropic-beta` header is rejected. Discovered via the `/test-vertex` diagnostic.
- **Shared-secret auth for backend→VM** — Cloud Run egress IPs are dynamic — firewall IP allow-listing is not viable. App-layer shared secret is the minimum viable auth for this hop.

---

## 2. System Architecture

### 2.1 Component diagram

```
  Browser (user)
        |
        | HTTPS
        v
  +------------------------------+
  |  deal-desk-frontend          |    Cloud Run, us-central1
  |  (React + Vite + Nginx)      |    Static SPA, 512MiB, 1 vCPU
  +---------------+--------------+
                  |
                  | SSE (POST /api/chat, /api/run)
                  v
  +------------------------------+
  |  deal-desk-backend           |    Cloud Run, us-central1
  |  (FastAPI + ADK + httpx)     |    2GiB, 2 vCPU, 900s timeout
  |                              |
  |  - Conversational chat loop  |
  |  - ADK pipeline runner       |
  |  - A2A protocol handler      |
  |  - Salesforce trigger proxy  |
  +----+----------+---------+----+
       |          |         |
       |          |         | POST /run + X-Agent-Secret
       v          v         v
   Vertex AI   BigQuery   +------------------------------+
   (us-east5) (US multi)  |  deal-desk-browser           |  GCE us-central1-a
   Claude     clients     |  (Ubuntu 24.04 + Chrome)     |  e2-standard-4, 30GB
   Opus 4.5   compliance  |                              |  static IP 35.223.98.125
   Sonnet 4.6 intel       |  - Xvfb :1 (virtual display) |  tags: deal-desk-browser
   Haiku 4.5  deals       |  - Fluxbox WM                |
                          |  - x11vnc :5900              |
                          |  - noVNC :6080 (fw: /32s)    |
                          |  - agent_server :8090        |
                          |    (fw: 0.0.0.0/0 + secret)  |
                          |                              |
                          |   Claude Sonnet 4.6 +        |
                          |   Computer Use drives        |
                          |   Chrome → Salesforce        |
                          +------------------------------+
                                   |
                                   v
                          Live Salesforce Lightning
```

### 2.2 Request lifecycle — full onboarding

1. User types prompt in React UI
2. Frontend POSTs to backend `/api/chat` (SSE response)
3. Backend's conversational loop (Claude Sonnet) calls `run_deal_pipeline` tool
4. Backend runs ADK pipeline: `ParallelAgent` (research + compliance) then `SequentialAgent` (risk → synthesis)
5. Each agent streams events back through SSE: `tool_call`, `tool_result`, `agent_start`, `agent_complete`
6. Synthesis agent writes `deal_package` row to BigQuery
7. Backend looks up client in BigQuery and POSTs to GCE `/run` with `X-Agent-Secret` header
8. GCE `agent_server` verifies secret, runs `salesforce_browser_agent` loop
9. Computer Use loop: screenshot → Claude analysis → action (click/type) → repeat
10. Agent writes `TASK_COMPLETE` when Opportunity is saved
11. GCE streams SSE events back through Cloud Run to frontend
12. Frontend renders browser agent events live; noVNC lets user watch in parallel

---

## 3. Data Model

BigQuery dataset: `cpe-slarbi-nvd-ant-demos.deal_desk_agent` (US multi-region).

### 3.1 Tables

| Table | Key columns | Purpose |
|---|---|---|
| `clients` | `name, aum_millions, strategy, domicile, fee_structure, relationship_status, primary_contact, primary_contact_title, onboard_date` | Source of truth for client profiles. Read by Research; updated by Synthesis. |
| `compliance_records` | `client_name, kyc_status, aml_status, sanctions_status, finra_registration, risk_tier, last_review_date, notes` | Read by Compliance agent. Values: `VERIFIED/CLEAR/PENDING/REVIEW/FAILED`. |
| `market_intelligence` | `client_name, source, intel_type, summary, date, relevance_score` | SEC filings, news, hiring signals. Read by Research. |
| `deal_packages` | `deal_id, client_name, aum_millions, strategy, mandate_type, fee_structure, compliance_status, risk_tier, risk_score, primary_contact, primary_contact_title, salesforce_opportunity_id, status, created_by, created_at, notes` | Audit trail. Written by Synthesis; stamped with SF opportunity ID by browser agent (via `update_deal_with_sf_opportunity`). |

### 3.2 Query patterns

All queries use BigQuery parameterized queries (`bigquery.ScalarQueryParameter`) to prevent injection. See `backend/tools/bigquery_tools.py`.

```python
sql = f"""
    SELECT * FROM `{PROJECT_ID}.{DATASET}.clients`
    WHERE LOWER(name) LIKE LOWER(@search_term)
"""
params = [bigquery.ScalarQueryParameter("search_term", "STRING", f"%{name}%")]
```

The `PROJECT_ID` and `DATASET` are injected via f-string from env vars, not user input — these are trusted configuration. Only user-supplied values flow through parameterized bindings.

### 3.3 Deal state machine

`deal_packages.status` transitions:

```
[INSERT] -> PENDING_SF_ENTRY
            |
            | update_deal_with_sf_opportunity()
            v
          COMPLETED

Alternate paths:
  PENDING_SF_ENTRY -> ON_HOLD     (if compliance blocker detected pre-insert)
  PENDING_SF_ENTRY -> ESCALATED   (if risk_tier=HIGH with blockers)
```

---

## 4. Agent Pipeline Design

### 4.1 Model tiering

| Agent | Model | Rationale |
|---|---|---|
| Research | Opus 4.5 | Synthesizes unstructured intel across multiple sources — reasoning-heavy |
| Compliance | Sonnet 4.6 | Structured verification against KYC/AML/sanctions fields — precision over reasoning |
| Risk Scoring | Haiku 4.5 | Extracts params from upstream outputs and calls a deterministic scorer — latency-sensitive |
| Synthesis | Opus 4.5 | Assembles final deal package from three agent outputs — reasoning-heavy |
| Salesforce Browser | Sonnet 4.6 | Visual navigation via Computer Use — Sonnet is Anthropic's recommended tier for CU |

### 4.2 Pipeline topology (ADK)

```python
deal_desk_pipeline = SequentialAgent(
    sub_agents=[
        ParallelAgent(sub_agents=[research_agent, compliance_agent]),  # concurrent
        SequentialAgent(sub_agents=[risk_agent, synthesis_agent]),     # serial (risk needs both parallel outputs)
    ]
)
```

`ParallelAgent` runs research and compliance concurrently because they are independent (both read BigQuery, neither depends on the other's output). Risk scoring depends on both parallel outputs via ADK shared state (`research_output`, `compliance_output` keys), so it runs serially after the parallel stage. Synthesis depends on `risk_output`.

### 4.3 Shared state via `output_key`

ADK agents communicate via named slots in session state:

```
research_agent:   output_key="research_output"
compliance_agent: output_key="compliance_output"
risk_agent:       output_key="risk_output"   (reads {research_output}, {compliance_output})
synthesis_agent:  output_key="deal_package"  (reads all three)
```

### 4.4 Computer Use on Vertex AI

The native `computer_20250124` tool type is **not** supported on Vertex `rawPredict`. The `anthropic-beta` header is also rejected. This was discovered by building the `/test-vertex` diagnostic endpoint that tries every combination.

Working pattern: `type: "custom"` with a full JSON Schema `input_schema` enumerating all computer use actions. Display dimensions go in the tool description, not as tool fields.

```python
COMPUTER_TOOL = {
    "type": "custom",
    "name": "computer",
    "description": f"Control a computer with a {W}x{H} screen... (actions and semantics)",
    "input_schema": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["click", "double_click", "type", "key",
                                                   "scroll", "screenshot", "move", "wait"]},
            "coordinate": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2},
            "text": {"type": "string"},
            "key": {"type": "string"},
            # ... button, direction, amount, duration
        },
        "required": ["action"]
    }
}
```

---

## 5. Security and Auth Model

### 5.1 Auth layers

| Hop | Transport | Auth mechanism |
|---|---|---|
| User → Frontend | HTTPS to Cloud Run | None (public demo) |
| Frontend → Backend | HTTPS to Cloud Run | None (CORS allowed, `--allow-unauthenticated`) |
| Backend → Vertex AI | HTTPS to `us-east5-aiplatform` | ADC (service account token, `roles/aiplatform.user`) |
| Backend → BigQuery | gRPC via `google-cloud-bigquery` | ADC (`roles/bigquery.dataEditor`, `roles/bigquery.jobUser`) |
| Backend → GCE `/run` | HTTP to static IP | Shared secret in `X-Agent-Secret` header |
| Operator → noVNC `:6080` | HTTP/WebSocket | Firewall /32 allow-list (no app-layer auth) |
| GCE VM → Vertex AI | HTTPS to `us-east5-aiplatform` | Instance service account (`cloud-platform` scope) |

### 5.2 Shared-secret design

The backend-to-VM hop is the one link where neither party is a managed Google service, so IAM-based authentication isn't directly available. We use a 32-byte hex shared secret:

- Generated with `openssl rand -hex 32` (256 bits of entropy)
- Stored on operator laptop at `~/Documents/deal-desk-agent/.agent-secret` (mode `600`)
- Injected into GCE via `--container-env AGENT_SECRET=$(cat .agent-secret)`
- Injected into Cloud Run via `--set-env-vars AGENT_SECRET=$(cat .agent-secret)`
- Loaded at module import time by both backend and `agent_server`
- Compared via `secrets.compare_digest` (constant-time, timing-attack safe)
- Rotating: redeploy both services; backoff is manual (no atomic swap)

### 5.3 Endpoint auth matrix

| Endpoint | Auth | Reason |
|---|---|---|
| `/health` | None | GCE and uptime checks need unauthenticated probes |
| `/run` | `X-Agent-Secret` required | Expensive operation; drives a real browser |
| `/test-vertex` | `X-Agent-Secret` required | Leaks Vertex AI error details |

### 5.4 Fail-closed behavior

If `AGENT_SECRET` env var is unset at module load, the server logs a warning but does not crash (so `/health` still works). All secret-gated endpoints then return **503 "Server misconfigured"** rather than 401 — distinguishable from a bad client credential and easier to debug in logs.

### 5.5 Firewall rules

| Rule | Port | Source | Target tag |
|---|---|---|---|
| `deal-desk-browser-novnc` | 6080 | `108.48.162.9/32, 34.48.48.58/32` | `deal-desk-browser` |
| `deal-desk-browser-agent` | 8090 | `0.0.0.0/0` | `deal-desk-browser` |

Port 6080 must be restricted at the network layer because noVNC has no app-layer auth in our setup. Port 8090 is internet-reachable because Cloud Run's egress addresses are not stable — the shared secret is the gate.

### 5.6 IAM inventory

| Principal | Role | Purpose |
|---|---|---|
| `deal-desk-agent-sa` | `roles/aiplatform.user` | Invoke Claude models on Vertex AI |
| `deal-desk-agent-sa` | `roles/bigquery.dataEditor` | Read/write tables in `deal_desk_agent` |
| `deal-desk-agent-sa` | `roles/bigquery.jobUser` | Execute BigQuery queries |
| GCE VM default SA | `cloud-platform` scope | Invoke Vertex AI from browser VM |

---

## 6. Deployment Topology

### 6.1 Regions

| Resource | Region | Reason |
|---|---|---|
| Claude models (Vertex AI) | `us-east5` | Anthropic model availability on Vertex |
| Cloud Run (backend, frontend) | `us-central1` | Infra region; calls `us-east5` for models |
| GCE browser VM | `us-central1-a` | Co-located with Cloud Run for low backend→VM latency |
| BigQuery dataset | US multi-region | Default; no regulatory constraint for demo data |
| Artifact Registry | `us-central1` | Co-located with compute |

### 6.2 Container images

- `us-central1-docker.pkg.dev/.../deal-desk-agent/backend:latest` — Python 3.12-slim, FastAPI, ADK, `anthropic[vertex]`
- `us-central1-docker.pkg.dev/.../deal-desk-agent/frontend:latest` — Multi-stage Node 20 build, Nginx Alpine serve
- `us-central1-docker.pkg.dev/.../deal-desk-agent/computer-use:latest` — Ubuntu 24.04, Xvfb, Chrome, noVNC, Python venv

### 6.3 Environment variables

| Variable | Backend | GCE VM | Purpose |
|---|---|---|---|
| `PROJECT_ID` | yes | yes | GCP project |
| `REGION` | yes | yes | Model region (`us-east5`) |
| `BQ_DATASET` | yes | no | BigQuery dataset name |
| `MODEL_PROVIDER` | yes | no | `claude` or `gemini` |
| `OPUS_MODEL` / `SONNET_MODEL` / `HAIKU_MODEL` | yes | partial (Sonnet only) | Vertex AI model strings |
| `AGENT_SECRET` | yes | yes | Shared secret for backend↔VM |
| `BROWSER_AGENT_URL` | yes | no | `http://<VM-IP>:8090` |
| `GOOGLE_CLOUD_PROJECT` / `GOOGLE_CLOUD_LOCATION` | yes | no | ADK import-time config |

### 6.4 Deploy sequence (from scratch)

1. Enable APIs: `aiplatform, bigquery, run, cloudbuild, artifactregistry, compute`
2. Create service account `deal-desk-agent-sa` with 3 roles
3. Create Artifact Registry repo `deal-desk-agent` in `us-central1`
4. `bq mk` dataset + `bq query` to populate 4 tables
5. `gcloud builds submit` for all 3 containers
6. Reserve static IP for GCE VM
7. Create firewall rules (novnc /32-restricted, agent `0.0.0.0/0`)
8. Generate `AGENT_SECRET`: `openssl rand -hex 32 > .agent-secret; chmod 600`
9. `gcloud compute instances create-with-container` with `AGENT_SECRET` in `--container-env`
10. `gcloud run deploy` backend with `AGENT_SECRET` + `BROWSER_AGENT_URL`
11. `gcloud run deploy` frontend (no secret needed)
12. Manually log into Salesforce via noVNC (one-time)

---

## 7. Operational Runbook

### 7.1 Rotating `AGENT_SECRET`

```bash
# 1. Generate new secret
openssl rand -hex 32 > ~/Documents/deal-desk-agent/.agent-secret

# 2. Redeploy both services concurrently (brief mismatch window is unavoidable)
SECRET=$(cat ~/Documents/deal-desk-agent/.agent-secret)

gcloud run services update deal-desk-backend \
    --region=us-central1 \
    --update-env-vars="AGENT_SECRET=${SECRET}"

gcloud compute instances update-container deal-desk-browser \
    --zone=us-central1-a \
    --container-env=AGENT_SECRET=${SECRET},PROJECT_ID=...,REGION=...,SONNET_MODEL=...

# 3. Verify
curl -X POST http://35.223.98.125:8090/run -H "X-Agent-Secret: ${SECRET}" \
    -H "Content-Type: application/json" -d '{"deal_package":{"client_name":"Test"}}'
```

### 7.2 Rebuilding after a code change

**Backend:**

```bash
cd backend/
gcloud builds submit --tag=us-central1-docker.pkg.dev/.../backend:latest \
    --region=us-central1 --timeout=600
gcloud run services update deal-desk-backend --region=us-central1 \
    --image=us-central1-docker.pkg.dev/.../backend:latest
```

**Browser VM:**

```bash
cd computer-use/
gcloud builds submit --tag=us-central1-docker.pkg.dev/.../computer-use:latest \
    --region=us-central1 --timeout=600
gcloud compute instances update-container deal-desk-browser \
    --zone=us-central1-a \
    --container-image=us-central1-docker.pkg.dev/.../computer-use:latest \
    --container-env=AGENT_SECRET=$(cat ~/Documents/deal-desk-agent/.agent-secret),...
```

### 7.3 Demo reset (between booth runs)

The backend exposes `POST /api/reset` which: deletes `deal_packages` rows created in the last hour; resets `ACME Capital Management` to `'Returning'`; resets other prospects back to `'Prospect'`.

### 7.4 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `POST /run` → 401 | `AGENT_SECRET` mismatch | Rotate via 7.1 to resynchronize |
| `POST /run` → 503 "Server misconfigured" | `AGENT_SECRET` env var missing on VM | Re-run `update-container` with the env var |
| noVNC connection refused | Operator IP not in allow-list | Check `curl ifconfig.me` vs /32s in `deal-desk-browser-novnc` |
| Chrome shows login page mid-demo | Salesforce session expired | VNC in, re-login manually |
| Cloud Run 504 | Pipeline exceeded timeout | Verify `--timeout=900s`; check Vertex AI latency |
| Backend import error on startup | ADK env vars unset before import | `GOOGLE_CLOUD_PROJECT`/`LOCATION` must be in `--set-env-vars` |
| Unexpected VM behavior (elevated CPU, unfamiliar processes) | Possible unauthorized access | Stop VM; rebuild image from source; generate a new `AGENT_SECRET`; redeploy backend and VM; rotate GCP service-account keys |

---

## 8. Learnings and Best Practices

This section captures the engineering lessons from building this system — framed as actionable guidance for anyone adapting similar patterns. Each subsection pairs **Do** (what worked / what's recommended) with **Don't** (antipatterns to avoid).

### 8.1 Authentication between managed services and custom VMs

**Do:**

- **Use an app-layer shared secret on any custom endpoint Cloud Run (or another serverless product) must call.** Cloud Run's egress IP pool is not stable, so firewall-level source-IP allow-listing is not a viable primary control for this hop.
- **Compare secrets with `secrets.compare_digest`** or an equivalent constant-time primitive. Timing variation from a naive `==` comparison can leak the secret byte-by-byte.
- **Load the secret once at module import time** and keep it in a module-level variable. Re-reading from env on every request adds latency for no security benefit.
- **Return 503 (not 401) when the secret env var is missing on the server side.** 503 means "the server is misconfigured"; 401 means "the client's credential is wrong." Conflating them makes incident triage slower.
- **Inject the secret through platform-native mechanisms** — `--container-env` for GCE, `--set-env-vars` for Cloud Run, or Secret Manager references for production systems.

**Don't:**

- **Don't rely on firewall IP allow-listing alone** when the caller is a managed service with dynamic egress. The allow-list will either silently break when egress ranges rotate, or you'll be forced to open it to `0.0.0.0/0` and lose the control entirely.
- **Don't use `==` for secret comparison.** Timing-attack safety is free when you reach for `secrets.compare_digest`; there is no reason to hand-roll this.
- **Don't embed secrets in code, container images, or git-tracked config files.** The only acceptable locations are: platform env vars, secret managers, or operator-held files excluded by `.gitignore`.
- **Don't log the secret value**, even at DEBUG level. A single log line persisted to Cloud Logging or a terminal scrollback is a full compromise.
- **Don't authenticate `/health`.** GCE and most uptime-check systems cannot inject custom headers reliably, and a failing `/health` endpoint is how real outages get detected. Keep it open.

### 8.2 Network posture for internet-adjacent VMs

**Do:**

- **Pair every exposed port with an authoritative control.** Either restrict at the network layer (firewall source ranges) OR gate at the application layer (auth header, mTLS) — pick one per port and make it explicit in the deployment config.
- **Document which control is load-bearing for each port** in your design doc. For this system: port 6080 relies on firewall allow-listing (because noVNC has no auth in our setup); port 8090 relies on the shared secret (because Cloud Run's egress is dynamic).
- **Use target tags on firewall rules** so rules are scoped to the specific VMs they protect, not to every instance in the VPC.

**Don't:**

- **Don't open a port to `0.0.0.0/0` without an app-layer authentication check in place first.** If you must open a port for operational reasons, validate the app-layer gate works (unit test, curl test) *before* relaxing the firewall.
- **Don't combine unrelated ports in a single firewall rule** if their auth postures differ. In this system, 6080 and 8090 have different threat profiles and need different source ranges — two rules, not one.
- **Don't assume a firewall and an auth header are redundant.** They defend against different threats: firewall stops opportunistic port scanners from spending compute on your VM; auth header stops anyone who reaches the port from triggering expensive operations.

### 8.3 Fail-closed design

**Do:**

- **Fail closed on missing configuration.** If a required env var is absent, refuse to serve protected endpoints rather than silently degrading to "no authentication."
- **Emit a clear warning at startup** if security-critical configuration is missing, so the problem shows up in logs immediately rather than only on the first authenticated request.
- **Keep the unauthenticated surface minimal** — for this system, only `/health`.

**Don't:**

- **Don't crash the process when security config is missing.** The `/health` endpoint needs to keep working so operators can see that the VM is alive-but-misconfigured, rather than alive-and-unreachable.
- **Don't treat "no secret configured" as "any secret accepted."** That is fail-open and is exactly the mistake that lets an ops change silently remove authentication.

### 8.4 Secret lifecycle

**Do:**

- **Generate secrets with a CSPRNG** (`openssl rand -hex 32` is 256 bits of entropy, more than enough).
- **Store secrets on operator machines with mode 600** and keep them out of git via `.gitignore`.
- **Commit templates, not values.** `.env.example` with placeholder strings lets new contributors bootstrap without exposing real credentials.
- **Rotate by redeploy.** Both the caller and callee should read the secret from env vars that can be updated via the platform's deploy tooling.

**Don't:**

- **Don't commit `.env` files containing real values.** Even if today's values are non-secret (project IDs, URLs), future additions will include secrets — so establish the "env files are local-only" rule early.
- **Don't hand-edit secrets into running pods/VMs** without also updating the deployment source of truth. The next redeploy will overwrite your manual change and cause confusing outages.

### 8.5 Defense in depth

**Do:**

- **Map every trust boundary to a control** and write it down. For this system, the audit table in §5.1 names exactly one control per hop.
- **Accept that managed services** (BigQuery, Vertex AI) **are adequately protected by IAM alone** — you don't need to wrap them in additional auth layers. Google runs the mature access governance; adding your own is often worse than relying on theirs.
- **Design assuming any single control will fail** — firewall rules get relaxed, secrets get leaked, IAM bindings get loosened. If the system is still safe under one-control-removed, the architecture is sound.

**Don't:**

- **Don't rely on obscurity** (unusual port numbers, unlisted URLs, undocumented endpoints) as a control. Port scanners find everything exposed to the public internet within hours.
- **Don't skip the threat model.** Even a one-page "what are we protecting from whom" document catches most of the mistakes before they ship.

### 8.6 Operational observability (recommended for any non-demo deployment)

**Do:**

- **Alert on VM CPU > 80% sustained for > 5 minutes** — unauthorized workloads (mining, spam relays, credential scanning) show up as CPU anomalies long before other signals.
- **Track 401 counts on protected endpoints as a metric.** A spike indicates someone is probing your auth layer.
- **Enable VPC Flow Logs** for VMs that host anything with internet exposure, and query them regularly for unexpected inbound traffic.
- **Pin container images by SHA digest** in production manifests (`image@sha256:abc...`), not by mutable tags like `:latest`. This prevents silent image drift during pull-on-restart.

**Don't:**

- **Don't deploy `:latest` tags to production** — you lose the ability to reason about what code is actually running.
- **Don't treat health-check green as evidence that auth works.** `/health` is unauthenticated by design. Test the auth path with a synthetic probe that sends a bad secret and asserts a 401 response.
- **Don't wait until an incident to build the dashboards.** The graphs that tell you "the system is behaving normally" are the same graphs that tell you "something is wrong" — build them early.

---

## 9. Known Limitations

- **Single-tenant** — no session isolation between concurrent users. Two simultaneous demos will collide in the Chrome profile.
- **No Salesforce login automation** — must be done manually via noVNC at deploy time and after session expiry
- **ADK sessions are in-memory** (`InMemorySessionService`). Restarting the backend loses all in-flight pipeline state.
- **Secret rotation has a brief mismatch window** (Cloud Run and GCE updates are not atomic)
- **No structured audit log** for `/run` calls — only Cloud Run request logs
- **Frontend hardcodes the backend URL at build time**; must rebuild to point at a new backend
- **Computer Use may click wrong coordinates** if Salesforce UI changes; no visual regression tests
- **No rate limiting on `/run`** — a leaked secret + valid header would allow unlimited abuse

---

## 10. Future Work

- **Secret Manager integration** — Replace env-var injection with Cloud Secret Manager references. Rotating becomes atomic; secrets never appear in deployment configs.
- **Workload Identity for Cloud Run → GCE** — Replace shared secret with IAM-authenticated calls using Cloud Run's workload identity token, verified server-side via `google-auth`.
- **Vertex AI Agent Engine deployment** — Move the ADK pipeline to Agent Engine for managed hosting, memory bank, and tracing. `agent_deploy/` directory has scaffolding.
- **Gemini model swap** — `MODEL_PROVIDER=gemini` toggles all agents to Gemini 2.5 Pro/Flash/Flash-Lite. Already implemented in `deal_desk_swarm.py`; needs end-to-end test.
- **LoopAgent for synthesis review** — Wrap `synthesis_agent` in ADK `LoopAgent` for self-critique before committing to BigQuery.
- **MCP Toolbox integration** — Replace direct BigQuery client with MCP Toolbox for standardized tool definitions across agents.
- **Structured audit logging** — Write every `/run` invocation to BigQuery with caller identity, timestamp, deal package, and outcome.
- **Rate limiting** — Add per-IP rate limit on `/run` via `slowapi` or Cloud Armor.
- **Incident response playbook** — Document procedures for responding to suspected unauthorized access: full container image rebuild from source (not just redeploy), service-account key rotation, new `AGENT_SECRET` generation, and forensic log review.
