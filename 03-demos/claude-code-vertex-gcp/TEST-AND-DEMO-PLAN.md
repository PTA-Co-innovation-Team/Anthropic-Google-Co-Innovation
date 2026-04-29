# Test & Demo Plan (quick reference)

This is the engineer-facing companion to the formal Test & Demo Plan
document. It covers the essentials: what the seven validation layers
check, the exact smoke-test commands to paste after a deploy, the
five-minute customer demo outline, and the failure triage table.

For the **full** test procedure — including staffing, pre-flight
gates, success criteria, and risk commentary — see the PDF Test &
Demo Plan supplied out-of-band.

---

## The seven validation layers

| # | Layer | What it proves | Automated by `e2e-test.sh`? |
| --- | --- | --- | --- |
| 1 | **Infrastructure** | Services exist and are READY, no public IPs, required IAM + APIs, Private Google Access on subnet, admin dashboard ready, BigQuery dataset exists, logging sink exists | ✅ yes |
| 2 | **Network path** | Vertex is reachable with the project's own identity (independent of gateway) | ✅ yes |
| 3 | **Gateway proxy** | LLM gateway forwards, strips beta headers, emits structured logs | ✅ yes |
| 4 | **Dev portal + laptop** | Portal responds, placeholders substituted. Laptop test (`developer-setup.sh` produces a working `~/.claude/settings.json`) | Portal: ✅ yes; laptop: ❌ manual |
| 5 | **MCP tools** | `/health` responds; `gcp_project_info` tool is invocable over Streamable HTTP | ✅ yes |
| 6 | **Negative + observability** | Unauth is rejected, no external IPs, admin dashboard health + API respond, non-allowed identities can't invoke gateway (last part is manual) | Partially |
| 7 | **GLB** *(when configured)* | Health via access token, inference via access + OIDC tokens, direct Cloud Run blocked, unauth rejected through GLB | ✅ yes (auto-discovered) |

---

## Smoke test (one command after any deploy)

```bash
./scripts/e2e-test.sh --quick
```

Runs Layer 1.1, 2.1, 3.1, 3.2, 5.1 — about 30 seconds, two Haiku
requests (~$0.002), exits non-zero if anything broke. Paste this into
your deploy runbook.

Full validation:

```bash
./scripts/e2e-test.sh
```

About 90 seconds, 3 Haiku requests, plus the 30-second log-ingestion
wait for Layer 3.2.

---

## Manual tests you still have to run yourself

### Layer 4 — Developer laptop

From a **second machine** (not the one that deployed):

```bash
git clone https://github.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation.git
cd Anthropic-Google-Co-Innovation/05-solution-accelerators/claude-code-vertex-gcp
./scripts/developer-setup.sh --yes
claude --print "Say hello in 4 words."
```

Expected: Claude replies. Failure modes: ADC not logged in, caller
lacks `roles/run.invoker`, VPN/ingress blocks the Cloud Run URL.

### Layer 6 — Non-allowed identity can't invoke gateway

From a Google account **not** in your deployment's
`allowed_principals`:

```bash
gcloud auth application-default login  # as the non-allowed user
TOKEN=$(gcloud auth application-default print-access-token)
curl -sS -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  "$LLM_GATEWAY_URL/v1/projects/…/locations/global/publishers/anthropic/models/claude-haiku-4-5@20251001:rawPredict"
```

Expected: `403`. A `200` means your IAM is too broad.

---

## 5-minute customer demonstration script

Goal: prove to a GCP customer that Claude Code runs entirely on their
infrastructure, paid to their GCP bill, with their identities.

| Time | Beat | What you show |
| --- | --- | --- |
| 0:00 | **The setup** | Open the dev portal in a browser. "Here's the self-service page. A new developer hits this URL and is done in 3 commands." |
| 0:30 | **The handshake** | Live-run `developer-setup.sh` on a laptop. Point out: no API keys, just ADC. Show the resulting `~/.claude/settings.json`. |
| 1:30 | **The request** | Start `claude`, ask for a code change. Observe response latency. |
| 2:00 | **The receipts** | Open the admin dashboard (ideally pre-seeded via `scripts/seed-demo-data.sh` — empty charts ruin the narrative). Point to: the user's own email in "top callers", Vertex region in the host breakdown, zero entries in the "betas stripped" panel. |
| 3:30 | **The proof** | In a second browser tab, try the same request from an **unauthenticated** curl against the gateway URL — show it returns 403. Mention Layer 6 coverage. |
| 4:30 | **The invoice** | Show the GCP billing page filtered to Vertex AI. "Every Claude token is on this invoice. No second vendor relationship." |

Keep it under 5 minutes. If the customer wants more depth, pivot to
[ARCHITECTURE.md](../../04-best-practice-guides/claude-code-vertex-gcp/ARCHITECTURE.md) and walk the topology diagram.

---

## Failure triage

When a test fails, start with the **lowest-numbered** failing layer —
a Layer 1 failure usually cascades.

| Test | Typical cause | First fix to try |
| --- | --- | --- |
| 1.1 Cloud Run not READY | Build failed or still provisioning | `gcloud run services describe <svc> --region=<r>` — read `status.conditions` |
| 1.2 external IPs present | Manual address allocation | `gcloud compute addresses list --filter="addressType=EXTERNAL"` — GLB IPs are whitelisted |
| 1.3 service accounts missing | Deploy script died midway | Re-run the relevant `deploy-*.sh`; they're idempotent |
| 1.4 no Private Google Access | Custom VPC without PGA | Turn on PGA on the subnet |
| 1.5 APIs disabled | Admin disabled them | `gcloud services enable aiplatform.googleapis.com run.googleapis.com …` |
| 1.6 admin dashboard not READY | Observability not deployed, or image build failed | Re-run `scripts/deploy-observability.sh` |
| 1.7 BigQuery dataset missing | Observability not deployed | Re-run `scripts/deploy-observability.sh` |
| 1.8 logging sink missing | Observability not deployed, or sink manually deleted | Re-run `scripts/deploy-observability.sh` |
| 2.1 direct Vertex 403/404 | Model not enabled, quota, wrong region | Model Garden → enable Claude Haiku 4.5; check quotas |
| 3.1 gateway returns 403 | Caller lacks `roles/run.invoker` (standard) or not in `ALLOWED_PRINCIPALS` (GLB) | Grant invoker or update principals; redeploy |
| 3.2 no log entry | Ingestion lag, or gateway never reached | Wait + retry; check `gcloud logging read` filter |
| 3.3 beta header not stripped | Old gateway image | Rebuild + redeploy LLM gateway |
| 4.1 portal not responding | Dev portal not deployed, or IAM missing | Re-run `scripts/deploy-dev-portal.sh` |
| 4.2 portal has raw placeholders | Portal deployed before gateways (URLs not substituted) | Re-deploy portal after gateways are up |
| 5.1 MCP /health 401/403 | Caller lacks `roles/run.invoker` on mcp-gateway | Grant invoker; note /health is IAM-gated despite being app-layer unauth |
| 5.1 MCP /health 404 | Pre-addendum image (no `/health` route mounted) | Rebuild + redeploy MCP gateway |
| 5.2 MCP tool call fails | Handshake path / session ID mismatch | `curl -i <mcp-url>/mcp` to see raw response |
| 6.1 unauth request succeeds | `--allow-unauthenticated` was used (should only be GLB mode, which has app-level validation) | Redeploy with `--no-allow-unauthenticated` (standard mode) |
| 6.2 dev VM has external IP | VM created outside scripts | Delete + recreate via `scripts/deploy-dev-vm.sh` |
| 6.3 dashboard /health fails | Dashboard not deployed, or caller missing `roles/run.invoker` | Re-run `scripts/deploy-observability.sh` |
| 6.4 dashboard API fails | Dashboard SA missing BigQuery roles | Check SA has `roles/bigquery.dataViewer` + `roles/bigquery.jobUser` |
| 7.1–7.3 GLB inference fails | GLB not deployed, backends unhealthy, or SSL cert not provisioned | Run `scripts/validate-glb-demo.sh` for detailed diagnostics |
| 7.4 direct Cloud Run not blocked | Ingress not set to `internal-and-cloud-load-balancing` | Re-deploy gateways with `ENABLE_GLB=true` |
| 7.5 GLB unauth not rejected | Token validation middleware not enabled | Check `ENABLE_TOKEN_VALIDATION=1` in gateway env vars |
| Layer 4 laptop fails | ADC not logged in / VPN blocks LB | `gcloud auth application-default login`; check network |
| Layer 6 non-allowed identity 200s | IAM too broad (e.g., allUsers granted) | Audit policy, remove over-broad bindings |

See [TROUBLESHOOTING.md](../../04-best-practice-guides/claude-code-vertex-gcp/TROUBLESHOOTING.md) for the comprehensive
operational troubleshooting guide.

---

## What this quick-reference does **not** cover

- Load testing / soak testing
- Failover behavior when Vertex returns 5xx
- Multi-region failover
- Compliance audit procedures (VPC-SC perimeter tests, org-policy
  verification)
- Cost-controls validation (budget alerts, quota caps)

All of those live in the formal Test & Demo Plan document.
