# Deal Desk Agent

**FSI Deal Desk Pipeline — Anthropic + Google Cloud: Better Together**

Built for Google Cloud NEXT 2026. A multi-agent system that automates FSI client onboarding using Claude models on Vertex AI, orchestrated by Google ADK.

---

> ## ⚠️ Disclaimer — Use At Your Own Risk
>
> This repository exists to demonstrate the **art of the possible** with Claude on Vertex AI, Google ADK, and Computer Use. It is **not production-ready software** and is **not supported**. It is single-tenant, drives a Salesforce Developer Edition sandbox, uses in-memory ADK sessions, and carries the known limitations documented in [`DESIGN.md` §9](./DESIGN.md). Sample BigQuery data is synthetic and does not represent real clients.
>
> **Do not deploy this against real client data, production Salesforce orgs, or regulated workloads.** If you choose to adapt any part of it, **use at your own risk** and **review it thoroughly before any deployment** — including but not limited to: IAM-based auth in place of the shared-secret pattern (see `DESIGN.md` §10), persistent session storage, rate limiting on `/run`, structured audit logging, secret rotation via a dedicated secret manager, network-layer controls such as VPC Service Controls, and a full independent security review.
>
> Code is provided **as-is, without warranty of any kind**, express or implied. The authors accept no liability for any damages arising from its use.

---

## Architecture

User Prompt (React UI, Cloud Run)
  -> FastAPI Backend (Cloud Run, us-central1)
       |
       +-> ParallelAgent (Research Agent [Opus 4.5] + Compliance Agent [Sonnet 4.6])
       +-> Risk Scoring Agent [Haiku 4.5]
       +-> Synthesis Agent [Opus 4.5]
       |
       +-> POST /run (X-Agent-Secret header) -> GCE Browser VM
                                                  |
                                                  +-> Salesforce Browser Agent [Sonnet 4.6, Computer Use]
                                                  +-> Xvfb + Chrome + noVNC
                                                  +-> Live Salesforce Lightning

The backend-to-VM hop is authenticated by a shared secret (AGENT_SECRET) loaded
at module import time. See Security section below.

## Models

| Agent | Model | Vertex AI String | Role |
|-------|-------|-----------------|------|
| Research | Claude Opus 4.5 | claude-opus-4-5@20251101 | Client and market intelligence |
| Compliance | Claude Sonnet 4.6 | claude-sonnet-4-6@default | KYC/AML/sanctions checks |
| Risk | Claude Haiku 4.5 | claude-haiku-4-5@20251001 | Quantitative risk scoring |
| Synthesis | Claude Opus 4.5 | claude-opus-4-5@20251101 | Deal package assembly |
| Salesforce | Claude Sonnet 4.6 | claude-sonnet-4-6@default | Browser-based CRM entry |

Region: us-east5 | Project: cpe-slarbi-nvd-ant-demos

## GCP Services

Vertex AI, BigQuery, Cloud Run, Compute Engine, Artifact Registry, Agent Engine, ADK

## Security

The browser VM's agent server (port 8090) accepts requests from the public internet
but requires a valid `X-Agent-Secret` header on `/run` and `/test-vertex`. The
comparison uses `secrets.compare_digest` to prevent timing attacks. The `/health`
endpoint stays unauthenticated so GCE uptime checks work.

Secret management:
- 32-byte hex secret generated with `openssl rand -hex 32`
- Injected into the GCE container via `--container-env AGENT_SECRET=...`
- Injected into Cloud Run via `--set-env-vars AGENT_SECRET=...`
- Both services must carry the same value; rotating means redeploying both

Firewall topology:
- Port 6080 (noVNC) — restricted to operator laptop IPs only (no app-layer auth)
- Port 8090 (agent API) — open to 0.0.0.0/0 (Cloud Run has dynamic egress IPs),
  gated by `X-Agent-Secret` at the application layer

Design rationale: Cloud Run egress addresses are not stable, which rules out
firewall IP allow-listing for the backend→VM hop. The shared-secret pattern is
the minimum viable app-layer authentication for that link. See `DESIGN.md` §5
for the full auth model.

## Project Structure

deal-desk-agent/
  backend/
    agents/ — ADK agent definitions, computer use loop, A2A agent card
    tools/ — BigQuery read/write tools, risk scoring engine
    main.py — FastAPI backend with SSE streaming
    Dockerfile, requirements.txt
  frontend/
    src/App.jsx — React command center UI
    Dockerfile, package.json, vite.config.js
  computer-use/
    Dockerfile — Browser VM (Xvfb + Chrome + noVNC)
    entrypoint.sh, supervisord.conf
  deploy/
    deploy.sh — Cloud Run deployment
    agent_engine_deploy.py — Agent Engine deployment
  docker-compose.yaml — Local development
  .env — Environment config

## Quick Start

### Local Development

  gcloud auth application-default login

  # Bootstrap your environment from the templates
  cp .env.example .env
  cp agent_deploy/.env.example agent_deploy/.env
  # Edit both files with your PROJECT_ID, models, Salesforce URL, etc.

  # Generate the shared secret for backend↔browser VM auth
  openssl rand -hex 32 > .agent-secret && chmod 600 .agent-secret

  docker compose up --build

  Frontend:  http://localhost:3000
  Backend:   http://localhost:8080
  noVNC:     http://localhost:6080

### Deploy to GCP

  cd deploy && ./deploy.sh

### Deploy to Agent Engine

  cd deploy && python agent_engine_deploy.py

## Demo Runbook (Google NEXT Booth)

### Before the Conference
1. Deploy all services via deploy.sh
2. Deploy browser VM on GCE
3. Pre-authenticate Salesforce in the browser VM
4. Test the full flow end-to-end
5. Record a backup video of the demo

### Each Demo (3-5 minutes)
1. Click a preset scenario or type a custom prompt
2. Narrate as agents appear in the activity feed
3. Point out parallel execution (Research + Compliance)
4. Highlight the deal package summary
5. Watch the Salesforce agent drive the browser in real time
6. Click into Salesforce to verify the Opportunity

### Between Demos
- Click Reset to clean up demo data
- This deletes recent deal packages and resets client statuses

### If Something Breaks
- Backend down: Check Cloud Run logs
- Browser VM frozen: SSH into GCE and restart container
- Salesforce session expired: VNC into browser VM and re-login
- `POST /run` returns 401: `AGENT_SECRET` mismatch between Cloud Run and GCE
  (redeploy both with the same value from `.agent-secret`)
- `POST /run` returns 503 "AGENT_SECRET not set": container env var missing
  (re-run `gcloud compute instances update-container ... --container-env=AGENT_SECRET=...`)
- Nuclear option: Play the backup video


