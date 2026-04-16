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
| **Dev Portal** | Cloud Run static site, IAP-protected | Self-service setup instructions for your developers |
| **Dev VM** *(optional, off by default)* | GCE VM with VS Code Server, accessed via IAP | Cloud dev environment for teams that don't want local installs |
| **Observability** | Log sink → BigQuery + a Looker Studio template | Admin dashboard: who is using Claude, how much, errors, top models |

All Cloud Run services use **internal-only ingress**. The Dev VM has **no public
IP** and is reached via IAP TCP tunneling. There is no public surface area.

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
3. Write `~/.claude/settings.json` with the right environment variables
   (Claude Code reads from here). It asks before overwriting an existing file.
4. Send a test request through the gateway to prove the round-trip works.

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

Right after `deploy.sh` (or `terraform apply`) finishes, run the
end-to-end test script to confirm everything is wired up correctly:

```bash
./scripts/e2e-test.sh
```

This runs six layers of checks — infrastructure sanity, direct Vertex
reachability, gateway proxy behavior, MCP tool invocation, and
negative tests (unauth rejection, no public IP on the dev VM). It
prints a PASS/FAIL/SKIP summary and exits non-zero on any failure.

For a faster smoke test (5 checks, <30 seconds):

```bash
./scripts/e2e-test.sh --quick
```

See [TEST-AND-DEMO-PLAN.md](../../03-demos/claude-code-vertex-gcp/TEST-AND-DEMO-PLAN.md) for the full
validation procedure, including the manual Layer 4 (laptop) and Layer
6 (negative identity) tests that can't be automated from a single
machine.

### External uptime probes

Both gateways expose a `GET /health` endpoint, but note the **auth
posture**: Cloud Run is deployed with `--no-allow-unauthenticated`
and `ingress=internal-and-cloud-load-balancing`, so even the unauth
app-layer `/health` handler is gated by IAM at the platform layer.
An anonymous external HTTP probe **cannot reach it**.

To run a Cloud Monitoring uptime check against `/health`:

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

### Demo prep

After a fresh deploy the Looker Studio dashboard is empty. To populate
it with realistic-looking traffic before a screenshot or live demo:

```bash
./scripts/seed-demo-data.sh --users 5 --requests-per-user 10
```

The seeder issues small Haiku requests (~$0.001 each, hard-capped at
200 total). All requests are attributed to **your** identity — the
"top callers" panel will show only you.

---

## Cost summary

Idle is the common case. Typical monthly costs:

| Configuration | Estimated cost |
| --- | --- |
| **Default, idle** (LLM gateway + MCP gateway + portal, no dev VM, Private Google Access) | **~$0–5/month** |
| **Default, light use** (a few developers) | **~$10–30/month** (Vertex tokens dominate) |
| **Everything on** (incl. shared dev VM `e2-small`, log sink to BigQuery) | **~$25–50/month** |

See [COSTS.md](../../04-best-practice-guides/claude-code-vertex-gcp/COSTS.md) for the line-by-line breakdown.

Token costs for Claude on Vertex follow
[Google's published Vertex AI pricing](https://cloud.google.com/vertex-ai/generative-ai/pricing)
— they are billed to your GCP project, not to Anthropic.

---

## Troubleshooting

If setup or a request fails, check [TROUBLESHOOTING.md](../../04-best-practice-guides/claude-code-vertex-gcp/TROUBLESHOOTING.md)
first — it covers the common issues (region availability, experimental-beta
header rejections, IAP tunnel problems, quota 429s, gcloud auth).

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
