# Deployment Guide

<table>
<tr>
<td>

**Claude Code on Google Cloud via Vertex AI**
Step-by-step deployment procedure

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
| **Companion document** | [ENGINEERING-DESIGN.md](../../04-best-practice-guides/claude-code-vertex-gcp/ENGINEERING-DESIGN.md) |
| **License** | Apache 2.0 |

---

This guide takes you from a bare GCP project to a fully validated
Claude-Code-on-Vertex deployment in about an hour. It assumes no
prior experience with Cloud Run, Terraform, or Claude Code. Every
step explains what it is doing and why.

For the architecture rationale, component catalog, and security
model, read the companion [ENGINEERING-DESIGN.md](../../04-best-practice-guides/claude-code-vertex-gcp/ENGINEERING-DESIGN.md)
first.

---

## 1. Before you begin

### 1.1 What you are about to deploy

When this procedure completes your GCP project will contain:

- An **LLM Gateway** on Cloud Run — the single entry point all
  Claude Code traffic flows through.
- An **MCP Gateway** on Cloud Run — shared host for Model Context
  Protocol tools.
- A **Dev Portal** on Cloud Run — self-service onboarding page for
  your developers.
- *(optional)* A **Dev VM** on GCE — shared cloud dev environment
  reached via IAP TCP tunnel.
- *(optional)* An **observability pipeline** — log sink to BigQuery
  with a built-in admin dashboard showing usage, callers, errors,
  and latency.
- Supporting infrastructure — custom VPC with Private Google Access,
  Artifact Registry repository, dedicated service accounts with
  least-privilege IAM, and IAP firewall rules.

### 1.2 Prerequisites

Check each box before starting.

- [ ] A **Google Cloud project** where you have `Owner` or `Editor`.
      If you need to create one:
      https://console.cloud.google.com/projectcreate
- [ ] A **billing account** linked to that project. Idle monthly cost
      is roughly $10–15 (see
      [COSTS.md](../../04-best-practice-guides/claude-code-vertex-gcp/COSTS.md) for the full table).
- [ ] Access to the **Anthropic Claude models on Vertex AI**. Open
      the Model Garden, search for "Claude", and click **Enable** on
      the models you intend to use:
      https://console.cloud.google.com/vertex-ai/model-garden
- [ ] A local machine with:
  - `gcloud` CLI ≥ 450 — https://cloud.google.com/sdk/docs/install
  - `git`
  - For the Terraform path: `terraform` ≥ 1.6 (1.9+ recommended)
  - For the notebook path: nothing — a browser is enough

> **New to GCP?** Every script in this repository is interactive. It
> tells you exactly what it is about to do before doing it, writes a
> displayed configuration file you can review, and requires an
> explicit "yes" before it creates any resource. You can always
> answer "no" and nothing gets created.

### 1.3 Authentication setup (required for all paths)

Run once on whichever machine will drive the deployment:

```bash
# Log in as a GCP user. This opens a browser.
gcloud auth login

# Set the target project as the default.
gcloud config set project <YOUR_PROJECT_ID>

# Generate Application Default Credentials (ADC). This is what the
# scripts and Terraform use when making API calls.
gcloud auth application-default login
```

---

## 2. Choose a deployment path

| Path | When to use | Time |
| --- | --- | --- |
| **A. Interactive script** | Fastest hands-on deploy. Recommended default. | 15–25 min |
| **B. One-line curl-to-bash** | Same as A, but no `git clone` first. | 15–25 min |
| **C. Terraform** | Teams with established IaC practice. | 20–30 min |
| **D. Jupyter notebook** | Colab / Vertex Workbench users; visual step-through. | 20–30 min |

All four paths result in the same resources. Pick one and follow the
matching section below.

---

## 3. Path A — Interactive script (recommended)

### 3.1 Clone the repository

```bash
git clone https://github.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation.git
cd Anthropic-Google-Co-Innovation/05-solution-accelerators/claude-code-vertex-gcp
```

### 3.2 Run the interactive deployer

```bash
./scripts/deploy.sh
```

The script walks through five prompts:

1. **GCP project ID** — defaults to your current gcloud config.
2. **Vertex region** — interactive picker with `global` (recommended
   default), `us-east5`, `europe-west3`, etc. You can also type any
   region string by hand.
3. **Component toggles** — one y/N per component (LLM gateway, MCP
   gateway, dev portal, dev VM, observability).
4. **Allowed principals** — comma-separated IAM members (e.g.
   `user:[email protected],group:[email protected]`). Defaults to
   your own email.
5. **Confirmation** — the script writes `config.yaml` to the current
   directory, displays it, and asks you to confirm before creating
   any resources.

### 3.3 What happens after you confirm

1. `gcloud config set project` is run for the chosen project.
2. The twelve required APIs are enabled (idempotent — already-
   enabled APIs are no-ops).
3. Each selected component script runs in sequence, building and
   pushing its container image via Cloud Build and deploying the
   Cloud Run service.
4. At the end, the script prints the gateway URLs and the next
   step.

Expected output on success:

```
==> done
[info] next: run scripts/developer-setup.sh on each developer's laptop.
```

### 3.4 Validate the deployment

```bash
./scripts/e2e-test.sh
```

Full validation: ~90 seconds, 3 Haiku inference requests, exit code
0 on success. See §7 for details.

Proceed to §8 (developer onboarding) once this is green.

---

## 4. Path B — One-line curl-to-bash

Fastest way to kick the tires. The deployer self-bootstraps by
cloning the repository to a temporary directory and re-executing
from there.

```bash
curl -fsSL https://raw.githubusercontent.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation/main/05-solution-accelerators/claude-code-vertex-gcp/scripts/deploy.sh | bash
```

> **Security note.** Piping `curl` to `bash` runs untrusted code on
> your machine. If your organization requires code review before
> execution, use Path A instead. To inspect before running:
> `curl -fsSL <URL> | less`

After the bootstrap clones the repo and re-invokes `deploy.sh`, the
flow is identical to Path A.

---

## 5. Path C — Terraform

### 5.1 Overview

Terraform provisions the full infrastructure but starts with
**placeholder container images**. A second step (either running the
component scripts or setting the `*_image` variables) attaches real
gateway images. This two-phase pattern avoids the chicken-and-egg
problem where Terraform would otherwise need the Artifact Registry
repository to exist *before* it could create that repository.

### 5.2 Phase 1 — infrastructure + placeholder images

```bash
git clone https://github.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation.git
cd Anthropic-Google-Co-Innovation/05-solution-accelerators/claude-code-vertex-gcp/terraform

# Copy the example tfvars and edit at minimum project_id and
# allowed_principals.
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# First apply — creates the VPC, Cloud Run services, service
# accounts, BigQuery sink, and Artifact Registry repo. Cloud Run
# services run a "hello" placeholder image.
terraform init
terraform apply
```

Expected output ends with:

```
Apply complete! Resources: ~39 added, 0 changed, 0 destroyed.

Outputs:
llm_gateway_url = "https://llm-gateway-xxx-uc.a.run.app"
mcp_gateway_url = "https://mcp-gateway-xxx-uc.a.run.app"
...
```

### 5.3 Phase 2 — build and attach real images

From the repository root:

```bash
PROJECT_ID=$(terraform -chdir=terraform output -raw project_id) \
REGION=$(terraform -chdir=terraform output -raw region) \
FALLBACK_REGION=us-central1 \
PRINCIPALS="user:[email protected],group:[email protected]" \
  bash scripts/deploy-llm-gateway.sh

# Repeat for the MCP gateway and the dev portal:
PROJECT_ID=... REGION=... FALLBACK_REGION=us-central1 PRINCIPALS=... \
  bash scripts/deploy-mcp-gateway.sh

PROJECT_ID=... REGION=... FALLBACK_REGION=us-central1 PRINCIPALS=... \
  bash scripts/deploy-dev-portal.sh
```

Each script builds + pushes the image, then deploys a new Cloud Run
revision referencing it. The Cloud Run URLs do not change.

### 5.4 (Optional) Let Terraform track the real image tags

If you want `terraform apply` to reproduce the exact running image
in future runs, set these in `terraform.tfvars` and re-apply:

```hcl
llm_gateway_image = "us-central1-docker.pkg.dev/PROJECT/claude-code-vertex-gcp/llm-gateway:YYYYMMDD-HHMMSS"
mcp_gateway_image = "us-central1-docker.pkg.dev/PROJECT/claude-code-vertex-gcp/mcp-gateway:YYYYMMDD-HHMMSS"
dev_portal_image  = "us-central1-docker.pkg.dev/PROJECT/claude-code-vertex-gcp/dev-portal:YYYYMMDD-HHMMSS"
```

Get the exact tags from the Artifact Registry UI or from `gcloud
artifacts docker images list`.

### 5.5 Validate

```bash
cd ..
./scripts/e2e-test.sh
```

---

## 6. Path D — Jupyter notebook (self-contained)

### 6.1 Open the notebook

- In **Google Colab**:
  https://colab.research.google.com/ → **File → Open notebook → GitHub
  → `PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation` →
  `01-tutorials/claude-code-vertex-gcp/deploy.ipynb`**.
- In **Vertex Workbench**: clone the repository into your workbench
  instance and open `01-tutorials/claude-code-vertex-gcp/deploy.ipynb`.

> **Self-contained.** The notebook embeds all source code (Dockerfiles,
> Python services, HTML, CSS) directly in its cells. It does **not**
> require cloning this repository — just open the notebook and run.

### 6.2 Step through the cells

The notebook has 28 cells (14 code, 14 markdown) covering:

1. Settings — edit project ID, region, component toggles, allowed
   principals directly in the code cell.
2. Authentication — Colab-aware `authenticate_user()` helper,
   `gcloud config set project`, helper functions.
3. API enablement.
4. **Explicit input() confirmation** — last chance to back out.
5. Artifact Registry creation (shared across all components).
6–7. LLM Gateway — writes source files to a temp dir, builds and deploys.
8–9. MCP Gateway — writes source files, builds and deploys.
10–11. Dev Portal — writes source files with URL substitution, builds and deploys.
12–13. Dev VM (optional) — renders startup script, creates GCE instance.
14. Deployment summary with all URLs and the SSH command.
15. Teardown (commented out by default).
16. Temp file cleanup.

### 6.3 Validate

From a terminal (Colab's built-in terminal or your local shell with
the cloned repo):

```bash
./scripts/e2e-test.sh
```

---

## 7. Post-deploy validation

### 7.1 End-to-end test script

Right after any successful deploy, run:

```bash
./scripts/e2e-test.sh
```

This covers six validation layers. Each test records PASS, FAIL, or
SKIP.

| Layer | Tests | What it proves |
| --- | --- | --- |
| 1. Infrastructure | Cloud Run READY, no external IPs, SAs exist, subnet PGA, required APIs | The stack was provisioned correctly |
| 2. Network path | 1 Haiku request direct to Vertex | Vertex is reachable from your project with ADC |
| 3. Gateway proxy | Gateway inference, log correlation, header stripping | Gateway works, logs correctly, strips betas |
| 5. MCP | /health GET, gcp_project_info tool call | MCP handshake and tool invocation work |
| 6. Negative | Unauth → 403/401, no external IP on dev VM | Security posture is intact |

Expected final block:

```
================================================================
  E2E Test Results
================================================================
  Layer 1: Infrastructure              [5/5 PASS]
  Layer 2: Network Path                [1/1 PASS]
  Layer 3: Gateway Proxy               [3/3 PASS]
  Layer 5: MCP Tools                   [2/2 PASS]
  Layer 6: Negative                    [2/2 PASS]
----------------------------------------------------------------
  TOTAL: 13 PASS, 0 FAIL, 0 SKIPPED
================================================================
```

Flags worth knowing:
- `--quick` — Layer 1.1, 2.1, 3.1, 3.2, 5.1 only (~30 seconds,
  2 Haiku requests).
- `--verbose` — echo every command.
- `--project`, `--gateway-url`, `--mcp-url`, `--cr-region` — override
  auto-discovery.

### 7.2 Manual validation tasks

Two scenarios cannot be tested from the deployer's machine:

**Layer 4 — developer laptop.** On a **separate** machine, clone the
repo and run `scripts/developer-setup.sh`. Open `claude` and ask a
trivial question. Details in
[TEST-AND-DEMO-PLAN.md](../../03-demos/claude-code-vertex-gcp/TEST-AND-DEMO-PLAN.md).

**Non-allowed-identity negative test.** From a Google account **not**
in `allowed_principals`, attempt to call the gateway. Expected: 403.
Details also in the test & demo plan.

---

## 8. Onboarding developers

### 8.1 Send them the dev portal URL

After the deploy, share the portal URL (printed by `deploy.sh` or
visible in `terraform output dev_portal_url`). The portal has
copy-paste setup instructions for macOS, Linux, and Windows (WSL2).

### 8.2 Or have them run the setup script directly

On the developer's laptop:

```bash
git clone https://github.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation.git
cd Anthropic-Google-Co-Innovation/05-solution-accelerators/claude-code-vertex-gcp
./scripts/developer-setup.sh
```

The script:

1. Verifies `gcloud` is installed and authenticated.
2. Runs `gcloud auth application-default login` (opens a browser).
3. Prompts for project, gateway URL, MCP URL, region (or reads them
   from the environment).
4. Writes `~/.claude/settings.json`, backing up any existing file
   with a timestamped `.bak` suffix.
5. Hits the gateway `/health` with the developer's ADC token to
   confirm the round-trip works.

The developer then runs `claude` and is on Vertex.

### 8.3 Flags

- `--yes` — non-interactive (uses env defaults).
- `--diagnose` — print the current gcloud auth state and
  `~/.claude/settings.json` without modifying anything.

---

## 9. Demo and monitoring

### 9.1 Populate the admin dashboard

A fresh deployment has an empty dashboard. To seed it with
realistic-looking traffic:

```bash
./scripts/seed-demo-data.sh --users 5 --requests-per-user 10 --duration-minutes 15
```

This issues 50 small Haiku requests (~$0.005 total) spread over 15
minutes using a curated 20-prompt corpus of developer questions.

Cost safety:
- Hard cap at 200 total requests; override with
  `--i-know-what-im-doing`.
- Confirmation prompt when `users × requests-per-user > 50`.
- All requests are attributed to **your** identity (it is not
  possible to forge principals from a client). This is documented
  in the script's help text.

Give Cloud Logging ~60 seconds to flush, then open the dashboard.

### 9.2 (Optional) Build a Looker Studio dashboard

The built-in admin dashboard covers most use cases. If you need a
more customizable dashboard, follow
[observability/looker-studio-template.md](../../05-solution-accelerators/claude-code-vertex-gcp/observability/looker-studio-template.md).
Approximately 10 minutes:

1. Create a Looker Studio data source pointing at the
   `claude_code_logs` BigQuery dataset.
2. Add six panels following the step-by-step instructions: requests
   per day, by model, top callers, error rate (calculated field),
   p50/p95/p99 latency scorecards, betas-stripped audit.

### 9.3 External uptime probes

Cloud Run's ingress + IAM means anonymous external probes **cannot**
reach the gateway `/health` endpoints. To run a Cloud Monitoring
uptime check:

1. Create a service account:
   ```bash
   gcloud iam service-accounts create uptime-probe \
     --project=$PROJECT_ID \
     --display-name="Cloud Monitoring uptime-probe"
   ```
2. Grant it `roles/run.invoker` on each gateway:
   ```bash
   for svc in llm-gateway mcp-gateway; do
     gcloud run services add-iam-policy-binding $svc \
       --project=$PROJECT_ID --region=$REGION \
       --member="serviceAccount:uptime-probe@$PROJECT_ID.iam.gserviceaccount.com" \
       --role="roles/run.invoker"
   done
   ```
3. In the
   [Cloud Monitoring console](https://console.cloud.google.com/monitoring/uptime),
   create a new uptime check. Under **Advanced options → Authentication**,
   pick **Service account authentication** and select the
   `uptime-probe` SA. Target URL:
   `https://<gateway-url>/health`, method GET, expected 200.

---

## 10. Common tasks

### 10.1 Add a new developer

1. Add their Google identity to `config.yaml`'s
   `access.allowed_principals` (or `allowed_principals` in
   `terraform.tfvars`).
2. Re-run `./scripts/deploy.sh` (or `terraform apply`) — both are
   idempotent and only adjust IAM.
3. Send them the dev portal URL.

### 10.2 Add a new MCP tool

Follow
[mcp-gateway/ADD_YOUR_OWN_TOOL.md](../../05-solution-accelerators/claude-code-vertex-gcp/mcp-gateway/ADD_YOUR_OWN_TOOL.md).
Summary:

1. Drop a new file under `mcp-gateway/tools/` containing a Python
   function with type hints and a docstring.
2. Import + decorate in `mcp-gateway/server.py`.
3. Grant the `mcp-gateway` service account any IAM roles the tool
   needs.
4. Run `./scripts/deploy-mcp-gateway.sh` to rebuild and redeploy.

Claude Code will see the new tool on its next session.

### 10.3 Change the Vertex region

1. Edit `region` in `config.yaml` or `region` in `terraform.tfvars`.
2. Re-run the deploy.
3. On each developer's laptop, re-run
   `./scripts/developer-setup.sh --yes` so their settings.json
   reflects the new region.

### 10.4 Pin or unpin model versions

Edit the `models.*` block in `config.yaml` or `model_opus` /
`model_sonnet` / `model_haiku` in `terraform.tfvars`, redeploy, and
re-run `developer-setup.sh` on each laptop.

### 10.5 Seed more demo data before a presentation

```bash
./scripts/seed-demo-data.sh --users 3 --requests-per-user 8 --duration-minutes 10
```

---

## 11. Troubleshooting quick index

Full coverage is in [TROUBLESHOOTING.md](../../04-best-practice-guides/claude-code-vertex-gcp/TROUBLESHOOTING.md). The
top hits:

| Symptom | First thing to check |
| --- | --- |
| `Unknown beta header` from Vertex | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` in `~/.claude/settings.json`; rebuild gateway if stripping logic is missing |
| HTTP 429 from the gateway | Vertex quota — request increase; short-term switch `CLOUD_ML_REGION=global` |
| "Model not available in region" | Enable the model in Model Garden; or switch to `global`; or use `VERTEX_REGION_CLAUDE_*` per-model override |
| `gcloud compute ssh --tunnel-through-iap` hangs | Caller lacks `roles/iap.tunnelResourceAccessor`; VM is stopped; or IAP firewall rule missing |
| Gateway returns 403 | Caller not in `allowed_principals`; re-run deploy to reconcile IAM |
| Gateway returns 401 | Caller has no ADC — run `gcloud auth application-default login` |
| `terraform apply` fails with billing error | Link a billing account to the project |
| `terraform` state lock error | `terraform force-unlock <LOCK_ID>` after confirming no other apply is running |

---

## 12. Tear down

Removes Cloud Run services, the dev VM, the IAP firewall rule, and
the four service accounts. Does **not** remove the Artifact Registry
repo (keeps built images for a fast re-deploy), the BigQuery dataset
(may contain historical logs of value), or the enabled APIs.

```bash
./scripts/teardown.sh
```

The script prompts for the project ID and requires you to type it
a second time to confirm. There is no `--yes` flag for teardown —
this is intentional.

For full removal including the Artifact Registry repo and BigQuery
dataset:

```bash
gcloud artifacts repositories delete claude-code-vertex-gcp \
  --project=$PROJECT_ID --location=$REGION
bq rm -r -f $PROJECT_ID:claude_code_logs
```

---

## 13. Support

- **Issues & PRs:** https://github.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation/issues
- **Reference architecture rationale:** [ENGINEERING-DESIGN.md](../../04-best-practice-guides/claude-code-vertex-gcp/ENGINEERING-DESIGN.md)
- **Test & demo procedure:** [TEST-AND-DEMO-PLAN.md](../../03-demos/claude-code-vertex-gcp/TEST-AND-DEMO-PLAN.md)
- **Cost model:** [COSTS.md](../../04-best-practice-guides/claude-code-vertex-gcp/COSTS.md)
- **Claude Code docs:** https://docs.claude.com/en/docs/claude-code
- **Vertex AI Anthropic docs:**
  https://cloud.google.com/vertex-ai/generative-ai/docs/partner-models/use-claude

---

<table>
<tr>
<td>

*This deployment guide is Apache 2.0-licensed alongside the reference
implementation.*

</td>
<td align="right">

**Schneider Larbi**
Senior Manager, Global Partner Technical Architecture
AI & SaaS ISV
2026-04-15

</td>
</tr>
</table>
