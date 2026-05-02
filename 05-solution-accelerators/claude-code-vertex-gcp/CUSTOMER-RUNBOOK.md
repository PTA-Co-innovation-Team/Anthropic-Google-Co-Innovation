# Claude Code on Google Cloud — Customer Runbook

> **First-time install? Use [`INSTALLATION.md`](./INSTALLATION.md) instead** — it's
> the focused walkthrough covering prerequisites, the install command,
> and the verify step. This runbook is for the *operations* you do
> after install: switching models on the fly, adding users, rotating
> versions, and tearing down.

The runbook below covers both the install path (for completeness) and
day-2 operations. Every command is idempotent — re-running is safe.

---

## What you're installing

A small set of GCP resources in your project that route Claude Code's
inference calls through Vertex AI:

- **LLM Gateway** (Cloud Run) — pass-through proxy to Vertex AI.
- **MCP Gateway** (Cloud Run) — hosts shared MCP tools.
- **Dev Portal** (Cloud Run) — self-service setup page for your team.
- **Admin Dashboard** + BigQuery log sink — usage observability.

No traffic egresses to `api.anthropic.com`. All caller identity is
asserted via Google credentials.

Idle cost: **~$0–5/month**. Light use (a few developers): ~$10–30/month.

---

## Prerequisites (do these once)

### 1. A GCP project with billing
Create at https://console.cloud.google.com/projectcreate. Link billing.

You need **Owner or Editor** on the project.

### 2. Enable Anthropic Claude models in Vertex AI Model Garden
Open https://console.cloud.google.com/vertex-ai/model-garden, search
"Claude", click **Enable** on:
- **Claude Haiku 4.5** — required (used by the smoke test).
- **Claude Sonnet 4.6** — recommended.
- **Claude Opus 4.6** — recommended.

> This is a one-time per-project click. Without it, deploy will succeed but
> inference returns 404. The preflight check below catches this.

### 3. Local CLIs
- `gcloud` — https://cloud.google.com/sdk/docs/install
- `git`, `python3`, `curl` — usually already on your machine.
- `terraform ≥ 1.6` — only if you choose the IaC path.

### 4. Authenticate
```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project <YOUR_PROJECT_ID>
```

---

## Install

```bash
cd claude-code-vertex-gateway
./INSTALL.sh
```

You'll be prompted for project ID, region, components, and the list of
Google identities allowed to use the gateway. Confirm; deploy runs end
to end. Takes ~5–8 minutes.

### Common variations

```bash
./INSTALL.sh --dry-run    # validate everything without creating resources
./INSTALL.sh --glb        # add the Global HTTP(S) Load Balancer (~$18/month)
./INSTALL.sh --yes        # auto-confirm prompts (CI / scripted use)
```

---

## Connect Claude Code on a developer laptop

```bash
./scripts/developer-setup.sh
```

This:
1. Runs `gcloud auth application-default login` if needed.
2. Installs `@anthropic-ai/claude-code` via `npm` if missing.
3. Auto-discovers the gateway URL.
4. Writes `~/.claude/settings.json` with the right env vars.
5. Pings `/health` to prove the round-trip works.

Then run `claude` — you're on Vertex AI.

---

## Verify

```bash
./scripts/e2e-test.sh           # full 7-layer suite
./scripts/e2e-test.sh --quick   # 5 smoke checks, <30 seconds
```

Expected: all PASS or SKIP, exit 0.

---

## Observability — Admin Dashboard

When `observability` is enabled (default), the deploy creates a Cloud Run
service called **`admin-dashboard`** that serves real-time usage charts
out of a BigQuery dataset (`claude_code_logs`) populated by a Cloud
Logging sink.

The deploy script prints the dashboard URL when it finishes; to
re-discover it later:

```bash
gcloud run services describe admin-dashboard \
  --project <PROJECT_ID> --region us-central1 \
  --format='value(status.url)'
```

Open the URL in your browser as any user listed in
`allowed_principals` and you'll see:

- Requests per day (last 30 days)
- Request volume by model (Opus / Sonnet / Haiku)
- Top callers (by email)
- Error-rate trend
- p50 / p95 / p99 latency to Vertex
- A live feed of the most recent 50 requests (timestamp, caller, model, status, latency)

The page auto-refreshes every 60 seconds. **First data appears ~60s
after the first gateway request flows through Cloud Logging into
BigQuery.**

> Looker Studio variant — only if you specifically want it.
> An advanced markdown walkthrough lives at
> `observability/looker-studio-template.md`. ~10 min of clicks to set
> up. The Admin Dashboard above renders the same panels with no extra
> setup — most teams will skip Looker entirely.

---

## Switching models on the fly

Four runtime knobs on the LLM gateway, all editable without rebuilding
the container:

| Variable | Purpose |
|---|---|
| `RATE_LIMIT_PER_MIN` | Per-caller request cap (off when unset). |
| `RATE_LIMIT_BURST` | Per-caller burst capacity (defaults to PER_MIN). |
| `TOKEN_LIMIT_PER_MIN` | Per-caller LLM-token cap, input + output combined. Off when unset. **Use this for budget control** — a single 80k-token Opus request consumes 80,000 tokens regardless of how many requests it is. |
| `TOKEN_LIMIT_BURST` | Per-caller token-bucket burst capacity. |
| `ALLOWED_MODELS` | CSV allowlist; requests for any other model return 403. |
| `MODEL_REWRITE` | CSV of `from=to` rules; gateway swaps the model in the URL before forwarding. |

### Two GUI options

**Admin Dashboard's Settings tab** (single pane of glass, recommended):
1. Open the Admin Dashboard URL.
2. Click the **Settings** tab.
3. Update one or more of the six values. Empty field = remove the env var.
4. Click **Save & Deploy New Revision**. Live in ~30 seconds.

The Settings tab is read-only by default; opt in editors via the
`EDITORS` env var on the dashboard service (CSV of emails). Without
`EDITORS` set, the tab loads but is not interactive.

**Cloud Run console** (fallback / for non-editor admins):
1. Open https://console.cloud.google.com/run for your project.
2. Click `llm-gateway`.
3. **Edit & Deploy New Revision** (top of page).
4. **Variables & Secrets** tab.
5. Add or update one of the variables above.
6. **Deploy**. New revision is live in ~30 seconds.

Both surfaces produce Cloud Run admin-activity log entries. The
dashboard additionally emits a `policy_change` log naming the IAP-
authenticated human, giving you a clean audit trail when investigating
"who turned the cap on at 2 AM."

### Worked example — "Opus is offline, route everyone to Sonnet"

When a model is unavailable (Vertex outage, quota burst, deprecation),
flip every developer's Opus traffic to Sonnet at the gateway:

```bash
gcloud run services update llm-gateway \
  --update-env-vars 'MODEL_REWRITE=claude-opus-4-6=claude-sonnet-4-6' \
  --project <PROJECT_ID> --region us-central1
```

Or in the console: add `MODEL_REWRITE=claude-opus-4-6=claude-sonnet-4-6`
to the env vars and Deploy. From the next request onward, every Opus
call is silently rewritten to Sonnet.

When Opus is back, **remove the rule manually** — the gateway does not
auto-detect:

```bash
gcloud run services update llm-gateway \
  --remove-env-vars 'MODEL_REWRITE' \
  --project <PROJECT_ID> --region us-central1
```

Multiple rules at once:

```
MODEL_REWRITE="claude-opus-4-6=claude-sonnet-4-6,claude-opus-4-5=claude-sonnet-4-6"
```

> **This is manual swap, not automatic failover.** Every Opus request
> becomes Sonnet for as long as the rule is set, regardless of whether
> Opus is healthy. Predictable; no flapping; reversible.

---

## When something fails

`INSTALL.sh` is split into three phases. Read the failing-phase log
(`/tmp/install-<phase>-<timestamp>.log`) and consult this table:

| Phase fails | Most likely cause | Fix |
|---|---|---|
| `preflight` | Vertex Claude models not enabled | Open Model Garden link above; click Enable. |
| `preflight` | Billing not enabled | Link billing account in console. |
| `preflight` | `gcloud` not authenticated | `gcloud auth login && gcloud auth application-default login` |
| `deploy` | First Cloud Build is slow / times out | Re-run `INSTALL.sh` — Cloud Build is idempotent. |
| `deploy` | "API not enabled" | Re-run `INSTALL.sh`; deploy.sh enables APIs at the top. |
| `deploy` | IAM propagation race ("invalid argument") | Re-run `INSTALL.sh` — `wait_for_sa` handles this. |
| `e2e` | 401 unauthorized | Caller's email is not in `ALLOWED_PRINCIPALS` — re-run with the right value. |
| `e2e` | 404 from Vertex | Model not enabled in Model Garden. |
| `e2e` | 429 quota exceeded | Request a Vertex quota bump. |
| (runtime) | A specific model is offline / hitting quota / deprecated | Set `MODEL_REWRITE=<offline-model>=<fallback-model>` on the gateway via the Cloud Run console. See "Switching models on the fly" above for the worked example. Remove the env var when the upstream issue clears. |

For anything else, see `04-best-practice-guides/claude-code-vertex-gcp/TROUBLESHOOTING.md`
in the upstream tree.

---

## Tear down

```bash
./scripts/teardown.sh
```

Interactive — you have to type the project ID twice. Removes the
gateways, VM (if deployed), and IAM bindings. Preserves the BigQuery
dataset (in case you want the historical logs) and the Artifact
Registry repo.

---

## Support boundaries

This package is a redistribution of the open-source reference architecture
at `github.com/PTA-Co-innovation-Team/Anthropic-Google-Co-Innovation`,
licensed Apache 2.0. It is **not** a supported product of Google or
Anthropic — operating it is your responsibility.

For issues with the gateway code, file at the upstream repository.
For Vertex AI / Cloud Run / IAM issues, open a Google Cloud support case.
For Claude Code CLI issues, file at `github.com/anthropics/claude-code`.
