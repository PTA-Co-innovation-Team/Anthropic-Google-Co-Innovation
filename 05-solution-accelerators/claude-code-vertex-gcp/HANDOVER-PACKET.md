# Handover Packet — Internal Partner Team

This document is for the partner-success team handing the gateway
package to an Anthropic / Claude Code customer. It documents what the
package contains, what is *not* in scope, and the escalation path.

---

## Package contents

| Path | What it is |
|---|---|
| `INSTALL.sh` | Single-command wrapper: preflight → deploy → smoke test. |
| `CUSTOMER-RUNBOOK.md` | Hand to the customer. ~15-min self-service runbook. |
| `HANDOVER-PACKET.md` | This file. **Internal — do not include in customer-facing tarball if confidentiality matters.** |
| `BLESS.md` | Pre-handover checklist (what to verify on a real GCP project before stamping it for a customer). |
| `LICENSE` / `NOTICE` | Apache 2.0; required attribution preserved. |
| `gateway/`, `mcp-gateway/`, `dashboard/`, `dev-portal/` | The four Cloud Run services (verbatim from upstream). |
| `terraform/` | IaC path (verbatim from upstream). |
| `scripts/` | Deploy + ops scripts; `preflight.sh` is new in this delivery. |
| `observability/` | Cloud Logging queries + Looker template. |

---

## Licensing

- Apache 2.0 throughout.
- Upstream attribution is preserved in `LICENSE`, `NOTICE`, every
  source file header, and every README.
- Customers may modify, redistribute, and use commercially per Apache 2.0.

---

## What you can promise the customer

- **Works against a real GCP project.** This package was deployed end-to-end
  against a sandbox before being handed to you (see `BLESS.md` for the
  results).
- **Idle cost ≈ $0–5/month.** Cloud Run scales to zero; BigQuery storage is
  capped via partition expiration.
- **No traffic to `api.anthropic.com`.** All inference goes through
  Vertex AI; the gateway adds an `Authorization: Bearer` from the gateway
  service account before forwarding.
- **Idempotent.** Every script and Terraform module is safe to re-run.

## What you cannot promise

- **Production support.** Apache 2.0 "as-is, no warranty." Customers needing
  paid support should buy Google Cloud support and engage Anthropic's
  enterprise channel directly.
- **API drift.** If Vertex changes its `rawPredict` schema, the pass-through
  proxy will surface upstream errors — the customer would need to take a
  fresh upstream pull.
- **Multi-cloud or on-prem.** This is GCP-only.

---

## Telemetry expectations

When `observability` is on (default):
- Each gateway request emits a structured JSON log line with caller email,
  model, status, latency, and dropped-beta-headers (no body).
- Logs flow to a customer-owned BigQuery dataset (`claude_code_logs`).
- The Admin Dashboard (Cloud Run) reads from that dataset.

**Nothing leaves the customer's GCP project.** The package does not phone home.

---

## Escalation path

| Issue type | Where it goes |
|---|---|
| Gateway code bug | Upstream repo: `github.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation` |
| Cloud Run / Vertex / IAM behaviour | Google Cloud Support (use the customer's existing entitlement) |
| Claude Code CLI behaviour | `github.com/anthropics/claude-code/issues` |
| Anthropic model behaviour / quotas | Anthropic enterprise contact |
| GCP billing / quota | Google Cloud Support |

---

## Versioning

- This package was assembled from upstream branch `feat/token-validation-auth-model-and-docs`.
- For a fresh upstream pull, see `BLESS.md` for the verification steps.
- Upstream releases are not formal-versioned; pin to a git SHA when
  delivering to enterprise customers.

---

## Common customer questions

**"Can we use this with a private VPC / on-prem developers?"**
Yes — turn on `use_psc=true` (Terraform) or the equivalent in `config.yaml`.
Costs ~$7–10/month extra for the PSC endpoint.

**"Can we use a custom domain?"**
Yes — pass `--glb` and provide `glb_domain`. Requires the parent zone
in Cloud DNS in the same project. ~$18/month for the GLB.

**"How do we restrict which models the gateway forwards?"**
Set `ALLOWED_MODELS=claude-haiku-4-5,claude-sonnet-4-6,...` on the LLM
gateway's Cloud Run service. Requests for any other model return 403
`{"error":"model_not_allowed"}`. Default empty = no restriction. See
user guide section 9.2.

**"Can we rate-limit per developer?"**
Yes — set `RATE_LIMIT_PER_MIN` (and optionally `RATE_LIMIT_BURST`) on
the LLM gateway. In-process token bucket per caller email; 429 with
`Retry-After` when exceeded. See user guide section 9.1. For
cross-instance exact enforcement (vs the in-process approximation),
swap to a Redis-backed limiter — documented in engineering design
section 15.5.

**"Can we cap per-developer token / cost spend, not just request count?"**
Yes — set `TOKEN_LIMIT_PER_MIN` (combined input + output tokens). This
is the right control for **budget protection**, where rate limiting
counts requests regardless of size. The gateway pre-checks the input
estimate (rejects too-large requests immediately), forwards to Vertex,
extracts the actual `usage` from the response, and debits the bucket
post-completion. First over-cap request passes; the next is blocked.
See user guide section 9.1.1.

**"Can our admins change these limits without using gcloud?"**
Yes — the Admin Dashboard has a Settings tab (with the same six
controls listed above). Read-only by default; opt in editors via the
dashboard service's `EDITORS` env var. Editors edit values in the
form, click Save, and the dashboard mutates llm-gateway via the
Cloud Run admin API. Audit log captures both the dashboard SA (Cloud
Run admin-activity) and the human editor (a `policy_change` log
emitted by the dashboard).

**"What if a model goes offline (Vertex outage, quota burst, deprecation)?"**
Set `MODEL_REWRITE=<offline-model>=<fallback-model>` on the LLM
gateway via the Cloud Run console. The gateway silently rewrites every
matching request to the fallback model. Developers see no
interruption. When the upstream issue clears, **remove the env var
manually** — the gateway does not auto-detect. Worked example: see
user guide section 9.6.1.

> Important to set expectations: this is **manual swap**, not
> automatic failover-on-error. If a customer needs automatic failover,
> that's a separate feature documented in engineering design section
> 15 as an extension point — not shipped today. The manual MODEL_REWRITE
> covers planned migrations and short-term outages cleanly.

**"Can we share the dashboard with non-engineers?"**
Yes — point Looker Studio at the same `claude_code_logs` BigQuery
dataset. Template at `observability/looker-studio-template.md`.

**"What if our org policy blocks `--no-invoker-iam-check`?"**
You'll need to wrap Claude Code so it sends OIDC tokens instead of
OAuth2 access tokens. That is a non-trivial fork of the CLI; recommend
the customer buy a quota exception or accept the security review of
`token_validation.py`.
