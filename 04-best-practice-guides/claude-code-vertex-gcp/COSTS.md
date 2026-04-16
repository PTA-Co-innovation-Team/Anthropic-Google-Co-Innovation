# Cost Breakdown

All figures are **rough estimates** in US dollars at list price for
`us-east5`, checked against the GCP pricing pages at time of writing. Your
actual bill will vary. Use this as a sanity check, not a quote.

---

## TL;DR

| Configuration | Idle | Light use (~5 devs) | Heavy use (~20 devs) |
| --- | --- | --- | --- |
| Minimum (LLM gateway + portal only) | **~$0** | **~$5** | **~$15** |
| Default (+ MCP gateway + observability) | **~$0–5** | **~$10–30** | **~$30–80** |
| Everything on (+ shared dev VM) | **~$15–25** | **~$25–50** | **~$50–150** |

**Vertex token costs are not included above.** They dominate any active
usage and are charged separately — see the final section.

---

## Per-component monthly cost (infrastructure only)

### LLM Gateway (Cloud Run)

| Item | Cost |
| --- | --- |
| Cloud Run CPU/memory (scale-to-zero when idle) | **$0 idle**; ~$0.000024/vCPU-second when active |
| Cloud Run requests | $0.40 per million |
| Network egress (stays on Google backbone via PGA) | ~$0 |

Realistic: **$0–3/month** at small-team scale.

### MCP Gateway (Cloud Run)

Identical profile to the LLM gateway. **$0–3/month** at small-team scale.

### Dev Portal (Cloud Run, nginx)

Static files, almost never invoked. **$0–1/month**.

### Dev VM (GCE, only when enabled)

| Machine type | On-demand hourly | 730 hr/month if always on |
| --- | --- | --- |
| `e2-small` (2 vCPU burst, 2 GB) — default | ~$0.017 | **~$12** |
| `e2-medium` (2 vCPU, 4 GB) | ~$0.033 | ~$24 |
| `e2-standard-4` (4 vCPU, 16 GB) | ~$0.135 | ~$98 |

Plus:
- Boot disk: 30 GB standard persistent disk ≈ **$1.20/month**
- IAP tunneling / OS Login: **free**
- No public IP (we don't attach one), so **no IP charges**

With auto-shutdown (default 2 hr idle) and a team using it ~40 hr/week, a
shared `e2-small` realistically costs **~$5/month**.

### Observability (log sink to BigQuery)

| Item | Cost |
| --- | --- |
| Cloud Logging ingestion (first 50 GB/month free) | $0 for most setups |
| BigQuery streaming inserts | $0.01 per 200 MB |
| BigQuery storage (first 10 GB/month free) | ~$0 |
| Looker Studio | **Free** |

Typical: **~$0–2/month**.

### Networking (default — Private Google Access)

| Item | Cost |
| --- | --- |
| VPC + subnet | Free |
| PGA enablement | Free |
| Serverless VPC connector (required for Cloud Run → VPC) | ~$10/month per connector (minimum `e2-micro` instance billed continuously) |

**Realistic: ~$10/month** — this is the single biggest fixed cost in the
stack. Consider whether you actually need the VPC connector; for pure
public-Vertex-endpoint calls you can skip it and save the $10.

> 💡 **Cost-saving toggle:** `networking.use_vpc_connector: false` routes the
> Cloud Run services to Vertex via Google's public endpoint instead of via
> the VPC. Traffic still never leaves Google's network, but it doesn't count
> as "private" for compliance reviews.

### Networking (PSC, opt-in only)

Add ~$7–10/month for the PSC forwarding rule. Only enable if you need
on-prem clients to hit this deployment privately.

---

## Vertex AI token costs (the real expense)

These are paid to Google, not Anthropic, and they scale with use.

Published list prices per 1M tokens on Vertex (check
[the pricing page](https://cloud.google.com/vertex-ai/generative-ai/pricing)
for current values):

| Model | Input | Output |
| --- | --- | --- |
| Claude Opus 4.6 | ~$15 | ~$75 |
| Claude Sonnet 4.6 | ~$3 | ~$15 |
| Claude Haiku 4.5 | ~$0.80 | ~$4 |

Ballpark for a single Claude Code developer doing real work (mix of Sonnet
for code edits, occasional Opus for planning):

- **Light use** (~100K input / 20K output tokens per day): **~$5–10/dev/month**
- **Heavy use** (~1M input / 200K output tokens per day): **~$50–100/dev/month**

Prompt caching and the gateway's request-aware model routing can cut this
significantly. Plan for "Vertex tokens are the biggest bill, by far."

---

## How to keep costs down

1. **Leave the dev VM off** unless you need it. This saves ~$12/month.
2. **Skip the VPC connector** if you don't have a compliance reason to
   require private egress. Saves ~$10/month.
3. **Turn on prompt caching** — Claude Code does this automatically for
   long-context conversations. Vertex passes through the cache discount.
4. **Pin models** (the default) — avoids accidental upgrades to a more
   expensive default.
5. **Set BigQuery log sink retention** to something short (30–90 days).
   The TF module sets 90 days by default.
6. **Use `CLOUD_ML_REGION=global`** — no regional premium and auto-routing.

---

## How to track costs

1. Enable the
   [GCP Billing Budget](https://console.cloud.google.com/billing/budgets)
   for your project with a monthly cap and email alerts at 50/80/100%.
2. Use the
   [Cost Breakdown report](https://console.cloud.google.com/billing/reports)
   with filters `service:Vertex AI` and `service:Cloud Run`.
3. The Looker Studio dashboard this repo installs has a "tokens per user"
   tab so you can see *who* is driving the bill.
