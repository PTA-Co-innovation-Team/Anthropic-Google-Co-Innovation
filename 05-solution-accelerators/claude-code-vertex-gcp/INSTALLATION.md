# Installation Guide

This is the focused install walkthrough — about ten minutes from zero
to a working Claude Code → Vertex AI gateway in your GCP project. For
day-2 operations (rotating users, switching models, troubleshooting,
teardown) see [`CUSTOMER-RUNBOOK.md`](./CUSTOMER-RUNBOOK.md). For full
architectural depth, the long-form
[user guide](./docs/claude-code-vertex-gcp-user-guide.md) and
[engineering design doc](./docs/claude-code-vertex-gcp-engineering-design.md)
are in the `docs/` folder.

---

## Prerequisites checklist

Tick all five before running the installer. The preflight script will
re-check most of them and fail loudly if any are missing.

### 1. A GCP project with billing
- Create at https://console.cloud.google.com/projectcreate or use an existing project.
- Link a billing account: **console → Billing → Linked billing account**.
- Confirm you have **Owner** or **Editor** on the project.

### 2. Anthropic Claude models enabled in Vertex AI Model Garden
Open the Model Garden for your project and click **Enable** on each:

| Model | Vertex Model ID | Required? |
|---|---|---|
| Claude Haiku 4.5 | `claude-haiku-4-5@20251001` | **Yes** — used by the e2e smoke test |
| Claude Sonnet 4.6 | `claude-sonnet-4-6` | Recommended |
| Claude Opus 4.6 | `claude-opus-4-6` | Recommended |

Direct link, substitute your project ID:
`https://console.cloud.google.com/vertex-ai/model-garden?project=<PROJECT_ID>`

> Without this step, deploy succeeds but inference returns 404. The
> preflight check catches it before any GCP resource is created.

### 3. Local CLIs
- `gcloud` — install via the [Cloud SDK](https://cloud.google.com/sdk/docs/install)
- `git`, `python3`, `curl` — usually already on your machine
- `terraform` ≥ 1.6 — only required if you choose the IaC path

### 4. Authenticate
```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project <YOUR_PROJECT_ID>
```

> If `gcloud auth login` returns `Error 400: invalid_request` (some
> Cloud Identity / Workspace orgs lock interactive OAuth), use a
> service account key instead:
> ```
> gcloud auth activate-service-account --key-file=key.json
> ```
> Delete the key file once the deploy completes.

### 5. Decide on optional components
The defaults are sensible. Decide upfront if you want any of these
extras — each is a yes/no answer at deploy time:

- **Dev VM** (off by default) — adds a no-public-IP GCE VM with Claude Code pre-installed; useful for teams that can't install locally. ~$1–3/month with auto-shutdown.
- **GLB + IAP** (off by default) — adds a Global HTTPS Load Balancer with browser-OAuth in front of the dashboard and dev portal. ~$18/month.

---

## Install

One command. The wrapper runs three phases in order: **preflight → deploy → smoke test.**

```bash
cd claude-code-vertex-gateway
./INSTALL.sh
```

You'll be prompted for:

| Prompt | Typical answer |
|---|---|
| GCP project ID | the one you authenticated against |
| Vertex region | `global` |
| Components — LLM gateway | `yes` (required) |
| Components — MCP gateway | `yes` (recommended) |
| Components — Dev portal | `yes` |
| Components — Dev VM | `no` unless you've decided otherwise |
| Components — Observability (BQ + admin dashboard) | `yes` |
| IAP for browser services | `no` unless you want GLB+IAP |
| Allowed principals (CSV) | `user:[email protected]` and any group/SA you want to grant access |

After your `yes` confirmation, the deploy creates the resources, runs the smoke test, and prints the gateway URL.

### Useful flags

```bash
./INSTALL.sh --dry-run    # validate everything without creating resources
./INSTALL.sh --glb        # enable GLB + IAP
./INSTALL.sh --yes        # auto-confirm all prompts (CI / scripted use)
./INSTALL.sh --quick      # smoke test in --quick mode (under 30s)
```

### What gets deployed (defaults)

| Resource | Purpose |
|---|---|
| `llm-gateway` (Cloud Run) | The pass-through proxy to Vertex AI |
| `mcp-gateway` (Cloud Run) | Hosts shared MCP tools for your developers' Claude Code |
| `dev-portal` (Cloud Run, nginx) | One-page setup site for new developers |
| `admin-dashboard` (Cloud Run) | Observability + (optionally) settings tab |
| `claude_code_logs` (BigQuery dataset) | Where structured logs land |
| 4 service accounts | One per service, each with least-privilege IAM |
| 1 Cloud Logging sink | Routes gateway logs into BigQuery |

Idle cost: **~$0–5/month**. Light use: **~$10–30/month**.

---

## Connect Claude Code on each developer's laptop

Run on the developer's machine (not on the GCP project):

```bash
./scripts/developer-setup.sh
```

This:
1. Verifies `gcloud` is authenticated.
2. Installs `@anthropic-ai/claude-code` via `npm` if missing.
3. Auto-discovers the gateway URL.
4. Writes `~/.claude/settings.json` with the right env variables.
5. Pings the gateway's `/health` endpoint to prove the round-trip works.

Then run `claude` — every Claude Code call now flows through your gateway → Vertex AI. **No code change in Claude Code itself.**

---

## Verify

Hit the gateway from your machine to confirm it works:

```bash
TOKEN=$(gcloud auth application-default print-access-token)
GATEWAY_URL=$(gcloud run services describe llm-gateway \
  --project <PROJECT_ID> --region us-central1 \
  --format='value(status.url)')

# Health
curl -sS -H "Authorization: Bearer $TOKEN" "${GATEWAY_URL}/health"
# → {"status":"ok","component":"llm_gateway","version":"0.1.0"}

# Live Claude Haiku call through the gateway
curl -sS --compressed -X POST \
  "${GATEWAY_URL}/v1/projects/<PROJECT_ID>/locations/global/publishers/anthropic/models/claude-haiku-4-5:rawPredict" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"anthropic_version":"vertex-2023-10-16","messages":[{"role":"user","content":"hi"}],"max_tokens":10}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['content'][0]['text'])"
```

If both return cleanly you're done. The Admin Dashboard URL prints at the end of the deploy; open it in your browser to see usage charts (~60 seconds after the first request).

---

## Common errors

| Symptom | Cause | Fix |
|---|---|---|
| Preflight FAIL on Vertex Claude probe | Models not enabled in Model Garden | Open the Model Garden link in step 2 above and click Enable. |
| Preflight FAIL on billing | Billing not linked | Console → Billing → Link billing account. |
| Deploy fails on Cloud Build | First build cold-starts slowly | Re-run `./INSTALL.sh` — Cloud Build is idempotent. |
| `gcloud auth login` returns Error 400 | Workspace OAuth restriction | Use a service account key (see step 4 callout). |
| Gateway returns 401 invalid_token | Caller's email not in `ALLOWED_PRINCIPALS` | Re-run with the right email, or add via `gcloud run services update`. |
| Gateway returns 404 from Vertex | Specific model not enabled | Enable in Model Garden. |
| Gateway returns 429 quota exceeded | Vertex AI default quota hit | Console → IAM & Admin → Quotas → request bump on Vertex. |

For deeper troubleshooting (especially around IAP, GLB, dev VM
networking, and the dashboard's Settings tab), see the
[user guide §11 Troubleshooting](./docs/claude-code-vertex-gcp-user-guide.md).

---

## What to do next

After install, you've got two ongoing surfaces to know about:

1. **Admin Dashboard** — usage charts, error rate, latency percentiles, token consumption, and (when EDITORS is configured) a Settings tab to change rate limits / model policy / token caps from the browser. URL is printed at deploy time.
2. **`CUSTOMER-RUNBOOK.md`** — the operations cookbook. Switching models on the fly when one is offline. Adding/removing users. Rotating model versions. Tearing down.

For changes that need real engineering, the
[engineering design doc](./docs/claude-code-vertex-gcp-engineering-design.md)
is the authoritative architectural reference.

---

## Tear down

```bash
./scripts/teardown.sh
```

Interactive — type the project ID twice to confirm. Removes the
gateways, dev VM (if deployed), Cloud NAT, IAM bindings, IAP wiring,
and the log sink. Preserves the BigQuery dataset and Artifact Registry
repo by default; `gcloud artifacts repositories delete` and
`bq rm -r -f -d <PROJECT>:claude_code_logs` if you want a fully empty
project.
