# Troubleshooting

Common problems and their fixes. If you hit something not listed here, open
an issue with the full error text and the output of
`gcloud config list --format=json`.

---

## Header rejection: `Unknown beta header: <name>`

**Symptom.** Claude Code prints a request error and the gateway log shows
the upstream Vertex response contained `Unknown beta header` or similar.

**Cause.** Claude Code sometimes sets an `anthropic-beta:` header for an
experimental feature that Anthropic's direct API supports but Vertex does
not. Vertex strict-rejects unknown beta headers.

**Fix.** Two layers, both should be on:

1. **Client-side.** `~/.claude/settings.json` must contain:
   ```json
   {
     "env": {
       "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
     }
   }
   ```
   `scripts/developer-setup.sh` writes this for you.
2. **Server-side.** The LLM gateway strips `anthropic-beta:` headers before
   forwarding. This is implemented in `gateway/app/headers.py`. If you've
   customized the gateway and removed that logic, put it back.

Verify by tailing the gateway log during a request:
```bash
gcloud logging read \
  'resource.type=cloud_run_revision AND resource.labels.service_name=llm-gateway' \
  --limit 20 --format json
```
You should see `"betas_stripped": ["..."]` on requests where a beta header
came in.

---

## HTTP 429: quota exceeded

**Symptom.** `Resource exhausted` or HTTP 429 from Vertex; Claude Code shows
rate-limit errors.

**Cause.** The project's
[Vertex AI quota](https://console.cloud.google.com/iam-admin/quotas) for
Anthropic models is capped. Default quotas for new projects are low.

**Fix.**
1. Open the quotas page, filter by `Vertex AI API` and `Anthropic`.
2. Find the quota that's maxing out — typically "Online prediction requests
   per minute per region per base model".
3. Click **Edit Quotas** and request an increase. Approval is usually
   minutes to hours.

**Short-term workaround.** Switch `CLOUD_ML_REGION=global` if you were on a
specific region — the multi-region endpoint has its own, usually higher,
pool.

---

## "Model not available in region"

**Symptom.** Request fails with a message like
`Model claude-opus-4-6 is not available in region europe-west2`.

**Cause.** Not every Claude model is in every region. Availability is
published on the
[Model Garden](https://console.cloud.google.com/vertex-ai/model-garden)
(filter by "Anthropic").

**Fix.**
1. If on a specific region, switch to `global` in `~/.claude/settings.json`:
   ```json
   { "env": { "CLOUD_ML_REGION": "global" } }
   ```
2. Or set a per-model region override for the specific model that's
   unavailable in your primary region. Example:
   ```json
   {
     "env": {
       "CLOUD_ML_REGION": "europe-west3",
       "VERTEX_REGION_CLAUDE_HAIKU_4_5": "us-east5"
     }
   }
   ```
3. Also make sure the model is **enabled** in your project via the Model
   Garden — click the model and press **Enable**. Enabling is per-project.

---

## IAP tunnel refuses to connect

**Symptom.** `gcloud compute ssh --tunnel-through-iap <vm>` hangs or errors
with `4003: failed to connect to backend`.

**Causes and fixes.**

| Cause | Fix |
| --- | --- |
| Caller lacks `roles/iap.tunnelResourceAccessor` | Grant it: `gcloud projects add-iam-policy-binding PROJECT --member=user:YOU --role=roles/iap.tunnelResourceAccessor` |
| IAP source ranges blocked by firewall | Ensure the TF-created `allow-iap-ssh` firewall rule exists (source range `35.235.240.0/20`, tcp:22). Re-apply Terraform if missing. |
| OS Login not enabled / caller missing `roles/compute.osLogin` | `gcloud projects add-iam-policy-binding PROJECT --member=user:YOU --role=roles/compute.osLogin` |
| VM is stopped (auto-shutdown kicked in) | `gcloud compute instances start <vm> --zone=<zone>` |

---

## Dev VM is missing after `deploy.sh` completed

**Symptom.** `config.yaml` has `components.dev_vm: true` and the main
`deploy.sh` ran without visible errors, but `gcloud compute instances list`
shows no `claude-code-dev-shared` instance and the service account
`claude-code-dev-vm@<project>.iam.gserviceaccount.com` does not exist.

**Cause.** `scripts/deploy-dev-vm.sh` was either skipped by the orchestrator
or failed partway through (most commonly: a transient auth/proxy error or
the user pressed Ctrl+C mid-run). Because the step creates the service
account first, a missing SA is a reliable indicator the script did not
complete.

**Fix.** Run `deploy-dev-vm.sh` standalone. It is idempotent — any resources
that already exist (IAM bindings, firewall rule) are detected and skipped.

```bash
PROJECT_ID=<your-project> \
REGION=<vertex-region> \
FALLBACK_REGION=<cloud-run-region> \
PRINCIPALS=user:<[email protected]> \
bash scripts/deploy-dev-vm.sh
```

`PROJECT_ID`, `REGION`, and `FALLBACK_REGION` must match the values in your
`config.yaml`. `PRINCIPALS` is a comma-separated list of IAM members who
should be granted `roles/iap.tunnelResourceAccessor` and
`roles/compute.osLogin` so they can SSH in via IAP.

**Verify.** The script prints an SSH command at the end; run it:
```bash
gcloud compute ssh --tunnel-through-iap \
  --project=<your-project> --zone=<region>-a claude-code-dev-shared
```
The first boot's startup log (installs Node.js, Claude Code, settings)
is at `/var/log/claude-code-bootstrap.log` on the VM.

---

## `gcloud` auth issues during setup

### "Application Default Credentials not found"

Run:
```bash
gcloud auth application-default login
```
Claude Code uses ADC (not `gcloud auth login`) when talking to Vertex. These
are two different credential stores on your machine.

### "Reauthentication failed" / expired session

```bash
gcloud auth application-default revoke
gcloud auth application-default login
```

### Multiple gcloud configs interfering

Check: `gcloud config configurations list`. If you have the wrong
configuration active, switch: `gcloud config configurations activate NAME`.

---

## Cloud Run 403 when Claude Code calls the gateway

**Symptom.** Gateway returns `403 Forbidden` immediately; logs show
`iam permission denied on resource`.

**Cause.** The calling identity does not have `roles/run.invoker` on the
gateway service.

**Fix.**
```bash
gcloud run services add-iam-policy-binding llm-gateway \
  --region=<REGION> \
  --member=user:<YOUR_EMAIL> \
  --role=roles/run.invoker
```

Or add the user to the Google group you listed in
`access.allowed_principals` and re-run `deploy.sh` — the script is
idempotent and will reconcile IAM.

---

## Cloud Run 401 / ADC token not sent

**Symptom.** `401 Unauthorized` from the gateway when Claude Code calls it.

**Cause.** Claude Code didn't attach a bearer token to the outbound request
because no ADC is set up in the shell it's running from.

**Fix.**
```bash
gcloud auth application-default login
gcloud auth application-default print-access-token  # should print a token
```
Then restart Claude Code so it re-reads credentials.

---

## "Billing is not enabled for this project"

**Symptom.** `aiplatform.googleapis.com` or `run.googleapis.com` enablement
fails during deploy with a billing error.

**Fix.**
1. Go to https://console.cloud.google.com/billing
2. Link a billing account to the project.
3. Re-run `deploy.sh`.

---

## Terraform says `Error acquiring the state lock`

**Symptom.** A previous `terraform apply` was interrupted.

**Fix.** If you're **sure** no other apply is running:
```bash
terraform force-unlock <LOCK_ID>
```
The lock ID is shown in the error message.

---

## Still stuck?

1. Re-read `ARCHITECTURE.md` to confirm the component in question is doing
   what you think.
2. Run `scripts/developer-setup.sh` again — it runs a self-test that hits
   the gateway and prints the first error in full.
3. File an issue with:
   - The exact command and its output.
   - `gcloud config list --format=json`
   - The last ~20 lines of `gcloud logging read` for the relevant service.
   - Your `~/.claude/settings.json` (redact the project ID if sensitive).

---

## Test failures (`scripts/e2e-test.sh`)

When the end-to-end script reports a FAIL, check the table below
**first** — most failures have one obvious cause.

| Test | Typical cause | First thing to check |
| --- | --- | --- |
| **1.1** Cloud Run services READY | Image didn't build, or Cloud Run is still provisioning | `gcloud run services describe <svc> --region=<r>` — look at `status.conditions` for the real error |
| **1.2** no external IP addresses | Someone manually attached a static IP to a VM | `gcloud compute addresses list --filter="addressType=EXTERNAL"` |
| **1.3** gateway service accounts | Deploy script failed midway | Re-run `scripts/deploy-llm-gateway.sh` — it's idempotent |
| **1.4** subnet Private Google Access | Custom VPC created without PGA | `gcloud compute networks subnets list --format='value(name,privateIpGoogleAccess)'` — the flag must be True |
| **1.5** required APIs enabled | APIs disabled after deploy | `gcloud services enable aiplatform.googleapis.com run.googleapis.com iap.googleapis.com compute.googleapis.com` |
| **2.1** direct Vertex inference | Quota or model not enabled in region | Open Model Garden, confirm Claude Haiku 4.5 is enabled; check quotas page for 429s |
| **3.1** gateway inference | IAM: caller missing `roles/run.invoker` | `gcloud run services add-iam-policy-binding llm-gateway --member=user:YOU --role=roles/run.invoker` |
| **3.2** structured log emitted | Gateway isn't actually reached (ingress issue) or logs lagging | Wait another minute and re-run; if still fails, check `gcloud logging read` filter matches service name |
| **3.3** anthropic-beta stripped | Old gateway image without `headers.py` sanitation | Rebuild + redeploy the LLM gateway |
| **5.1** MCP /health responds | **401/403**: caller missing `roles/run.invoker` (`/health` is IAM-gated despite being app-layer unauth — see README "External uptime probes"). **404**: pre-addendum image without the FastAPI composition — rebuild + redeploy. |
| **5.2** MCP tool invocation | Handshake session lost / wrong path | Check `mcp-gateway/server.py` mount path matches `/mcp`; try `curl -i <url>/mcp` directly |
| **6.1** unauth rejected | Cloud Run ingress set to `all` + `--allow-unauthenticated` | Re-deploy with `--no-allow-unauthenticated` |
| **6.2** VM has no external IP | Someone created the VM outside the deploy scripts | Either delete + re-create via `scripts/deploy-dev-vm.sh`, or manually remove the access config |

### Failure triage flow

1. **Start with the lowest-numbered failing layer.** A Layer 1 failure
   often causes cascading failures in Layers 2–5 — fix it first.
2. **Re-run with `--verbose`** to see the exact gcloud/curl commands.
3. **For any 4xx from the gateway**, run
   `gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=llm-gateway' --limit=5 --format=json`
   and inspect the last few entries for auth or header errors.
4. **For MCP failures**, test the plain `/health` endpoint first
   (Layer 5.1). If that passes but 5.2 fails, the tool itself or the
   handshake is the problem, not the gateway.
5. **Layer 4 (laptop) and the negative-identity subset of Layer 6**
   must be tested manually with a second account — see
   [TEST-AND-DEMO-PLAN.md](../../03-demos/claude-code-vertex-gcp/TEST-AND-DEMO-PLAN.md).
