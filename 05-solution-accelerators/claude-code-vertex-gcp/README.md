# Claude Code on GCP via Vertex AI

**A production-quality reference architecture and deployment kit for running
[Claude Code](https://docs.claude.com/en/docs/claude-code) on Google Cloud
with all model inference routed through [Vertex AI](https://cloud.google.com/vertex-ai).**

No traffic to `api.anthropic.com`. Google identity everywhere. Near-zero cost
when idle. Built for teams whose security reviewers will actually read the
diagram.

```
                                   ┌─────────────────────┐
   Developer Laptop ──gcloud──▶    │  LLM Gateway        │ ──▶ Vertex AI (Claude)
   (claude CLI)                    │  Cloud Run · FastAPI│
                                   ├─────────────────────┤
                                   │  MCP Gateway        │ ──▶ Your custom tools
                                   │  Cloud Run · FastMCP│
                                   ├─────────────────────┤
                                   │  Admin Dashboard    │ ──▶ BigQuery (usage)
                                   │  Cloud Run · charts │
                                   └─────────────────────┘
```

---

## Quickstart

```bash
tar xzf claude-code-vertex-gateway.tar.gz
cd claude-code-vertex-gateway
./INSTALL.sh
```

That's it. The wrapper validates your project (preflight), deploys the
four Cloud Run services, runs a smoke test, and prints the gateway URL.
~10 minutes on a fresh project. Idle cost ~$0–5/month.

For the proper walkthrough — prerequisites, model-garden setup,
authentication, what to do next — read **[`INSTALLATION.md`](./INSTALLATION.md)**.

---

## What's in this repo

| Path | Purpose |
|---|---|
| **[`INSTALLATION.md`](./INSTALLATION.md)** | **Start here.** Single-page install walkthrough with prereqs and verify steps. |
| [`CUSTOMER-RUNBOOK.md`](./CUSTOMER-RUNBOOK.md) | Day-2 operations: switching models on the fly, adding users, troubleshooting, teardown. |
| [`docs/claude-code-vertex-gcp-user-guide.md`](./docs/claude-code-vertex-gcp-user-guide.md) | Long-form user guide — 12 sections, brand-themed diagrams. Same content as the .docx counterpart. |
| [`docs/claude-code-vertex-gcp-engineering-design.md`](./docs/claude-code-vertex-gcp-engineering-design.md) | Architectural reference — what each component does, how they interoperate, why the design choices were made. |
| [`HANDOVER-PACKET.md`](./HANDOVER-PACKET.md) | Internal notes for the partner-success team handing this to a customer. |
| [`BLESS.md`](./BLESS.md) | Pre-handover verification checklist — what to test on a real project before stamping it for a customer. |
| [`INSTALL.sh`](./INSTALL.sh) | The single-command installer (preflight → deploy → e2e). |
| [`scripts/`](./scripts/) | Per-component deploy scripts, preflight, e2e tests, teardown, developer-setup. |
| [`gateway/`](./gateway/), [`mcp-gateway/`](./mcp-gateway/), [`dashboard/`](./dashboard/), [`dev-portal/`](./dev-portal/) | The four Cloud Run service sources. |
| [`terraform/`](./terraform/) | IaC alternative to the bash deploy scripts; modules mirror them 1:1. |
| [`observability/`](./observability/) | Cloud Logging queries + an optional Looker Studio walkthrough. |
| [`gateway/tests/`](./gateway/tests/) | 52 pytest unit tests covering proxy, token validation, rate limit, model policy, and token cap. |

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

## What gets deployed

When the installer finishes, your GCP project will contain:

| Component | What it is | Why it exists |
|---|---|---|
| **LLM Gateway** | Cloud Run service — small FastAPI reverse proxy | Single point for auth, logging, header sanitation, rate limiting, and model policy in front of Vertex AI |
| **MCP Gateway** | Cloud Run service — FastMCP over Streamable HTTP | Place to host your organization's custom MCP tools (ships with four examples) |
| **Dev Portal** | Cloud Run static site | Self-service setup instructions for your developers |
| **Admin Dashboard** | Cloud Run service — Chart.js + BigQuery | Real-time usage panels, optionally a Settings tab for editing traffic policy from the browser |
| **Dev VM** *(optional, off by default)* | GCE VM with no public IP, accessed via IAP TCP tunneling | Cloud dev environment for teams that don't want local installs |
| **Observability** | Cloud Logging sink → BigQuery dataset `claude_code_logs` | Where the structured logs land; the dashboard reads from here |

---

## Built-in traffic policy controls

The LLM Gateway ships with four configurable controls, all off by
default. Enable them by setting environment variables on the Cloud
Run service (via Cloud Run console, the dashboard's Settings tab, or
Terraform). See the
[user guide §9](./docs/claude-code-vertex-gcp-user-guide.md) for the
full reference.

| Variable | Behavior |
|---|---|
| `RATE_LIMIT_PER_MIN` | Per-caller request cap, 429 + Retry-After when exceeded. |
| `TOKEN_LIMIT_PER_MIN` | Per-caller LLM-token cap (input + output combined). For real budget control. |
| `ALLOWED_MODELS` | CSV allowlist. Requests for any other model return 403. |
| `MODEL_REWRITE` | CSV of `from=to` rules. Manual model swap when one is offline. |

---

## License

Apache 2.0 — see [`LICENSE`](./LICENSE) and [`NOTICE`](./NOTICE) for
attribution. The package is a redistribution of the open-source
reference architecture at
[github.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation](https://github.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation).
