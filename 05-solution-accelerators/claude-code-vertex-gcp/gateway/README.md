# LLM Gateway

A ~150-line FastAPI reverse proxy that sits between Claude Code and the
Vertex AI Anthropic endpoint. Runs on Cloud Run.

Its **only jobs** are:

1. Authenticate the caller — via app-level token validation middleware
   (`token_validation.py`), which accepts both OAuth2 access tokens and
   OIDC identity tokens. Cloud Run's built-in invoker IAM check is
   disabled (`--no-invoker-iam-check`) because Claude Code sends access
   tokens, which Cloud Run IAM rejects.
2. Strip Anthropic-only beta headers Vertex doesn't accept.
3. Replace the caller's bearer token with the gateway service account's
   token (obtained via ADC).
4. Normalize URL paths — auto-prepend `/v1/` when Claude Code omits it
   (which it does when `ANTHROPIC_VERTEX_BASE_URL` is set).
5. Forward the request to the right Vertex regional host, stream the
   response back.
6. Emit a structured JSON log entry per request.

**It is not a format translator.** Claude Code with
`CLAUDE_CODE_USE_VERTEX=1` already emits Vertex-format requests. We just
pass them through.

---

## Local development

Prereqs: Python 3.12+, a GCP project with Vertex enabled, `gcloud auth
application-default login` already run on your machine.

```bash
cd gateway
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
pip install pytest  # for the test suite

# Point the gateway at your project; "global" is the default region.
export GOOGLE_CLOUD_PROJECT=your-project-id
export VERTEX_DEFAULT_REGION=global

# Run locally on port 8080.
uvicorn app.main:app --host 0.0.0.0 --port 8080 --reload
```

Then hit it with curl (using your own ADC token — the caller identity
check is satisfied automatically when run behind Cloud Run; locally we
just skip it):

```bash
TOKEN=$(gcloud auth application-default print-access-token)
curl -X POST "http://localhost:8080/v1/projects/$GOOGLE_CLOUD_PROJECT/locations/us-east5/publishers/anthropic/models/claude-haiku-4-5:rawPredict" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "anthropic_version": "vertex-2023-10-16",
    "messages": [{"role":"user","content":"Say hello."}],
    "max_tokens": 64
  }'
```

## Running the tests

```bash
cd gateway
pip install pytest httpx  # httpx is already a dep, pytest is test-only
pytest -q
```

The test suite includes `test_proxy.py` (proxy behavior) and
`test_token_validation.py` (middleware unit tests covering health
bypass, access-token and OIDC-token validation, 401/403 rejection,
and `ALLOWED_PRINCIPALS` enforcement). All tests mock out Google
credentials and upstream HTTP calls; they run offline in ~1 second.

## Building the container

```bash
docker build -t llm-gateway:local .
docker run --rm -p 8080:8080 \
  -v ~/.config/gcloud:/home/app/.config/gcloud:ro \
  -e GOOGLE_CLOUD_PROJECT=$GOOGLE_CLOUD_PROJECT \
  llm-gateway:local
```

The ADC mount is only needed for local runs. On Cloud Run, ADC is
provided by the attached service account automatically.

## How it works inside

```
┌────────────────────┐
│  Claude Code       │  Sends Vertex-format request with caller ADC
└─────────┬──────────┘
          │  Cloud Run invoker IAM disabled (--no-invoker-iam-check)
          │  App-level token_validation.py handles auth instead
          ▼
┌─────────────────────────┐
│  app/main.py            │  Catch-all route, dispatches to proxy_request
│  app/token_validation.py│  * Validates access + OIDC tokens
│                         │  * Enforces ALLOWED_PRINCIPALS
│  app/proxy.py           │  * Normalizes path (prepends /v1/ if missing)
│                         │  * Extracts caller email (headers or middleware)
│                         │  * Strips anthropic-beta, Authorization, hop-by-hop
│                         │  * Fetches fresh bearer via google-auth
│                         │  * Streams to Vertex with httpx.AsyncClient
│  app/headers.py         │  * Header sanitation rules
│  app/auth.py            │  * Caller-identity extraction + ADC token
│  app/logging_config     │  * JSON-to-stdout for Cloud Logging
└─────────┬───────────────┘
          ▼
┌────────────────────┐
│  Vertex AI         │  us-east5-aiplatform.googleapis.com / aiplatform...
└────────────────────┘
```

## Environment variables (runtime)

| Name | Purpose | Default |
| --- | --- | --- |
| `PORT` | Port to bind. Set by Cloud Run. | `8080` |
| `GOOGLE_CLOUD_PROJECT` | Project ID (logged in entries; also consulted by google-auth). | *(none; set by Cloud Run)* |
| `VERTEX_DEFAULT_REGION` | Fallback Vertex region when the request path doesn't encode one. | `global` |
| `VERTEX_PROJECT_ID` | Override for `GOOGLE_CLOUD_PROJECT` if logs need a different value. | *(unset)* |
| `ENABLE_TOKEN_VALIDATION` | Set to `1` to enable app-level token validation middleware. Always enabled in production (`1`). When `0`, middleware is not registered (local dev only). | `1` |
| `ALLOWED_PRINCIPALS` | Comma-separated emails allowed to call the gateway (e.g. `user@example.com,sa@proj.iam.gserviceaccount.com`). Only checked when token validation is enabled. Empty = any valid Google token accepted. | *(empty)* |
| `RATE_LIMIT_PER_MIN` | Per-caller request cap, requests per minute. 0 / unset disables. Implemented in `app/rate_limit.py`. | `0` |
| `RATE_LIMIT_BURST` | Per-caller burst capacity. Defaults to `RATE_LIMIT_PER_MIN` if unset. | `RATE_LIMIT_PER_MIN` |
| `TOKEN_LIMIT_PER_MIN` | Per-caller LLM-token cap (input + output) per minute. 0 / unset disables. Implemented in `app/token_limit.py`. Pre-charge based on input-token estimate; post-charge debit reads `usage` from Vertex's response. First-over-cap request passes; next is blocked. | `0` |
| `TOKEN_LIMIT_BURST` | Per-caller token-bucket burst capacity. Defaults to `TOKEN_LIMIT_PER_MIN`. | `TOKEN_LIMIT_PER_MIN` |
| `ALLOWED_MODELS` | CSV allowlist of full model strings (e.g. `claude-sonnet-4-6,claude-haiku-4-5`). Requests for any other model return 403 `model_not_allowed`. Empty = no restriction. Implemented in `app/model_policy.py`. | *(empty)* |
| `MODEL_REWRITE` | CSV of `from=to` rules (e.g. `claude-opus-4-6=claude-sonnet-4-6`). Gateway swaps the model in the URL before forwarding. Useful for forced migrations and manual swap when a model is offline. Empty = no rewrites. | *(empty)* |

> **Editing these on a running deployment.** All four are env vars on
> the Cloud Run service, so an operator can change them via the
> [Cloud Run console](https://console.cloud.google.com/run) (Edit &
> Deploy New Revision → Variables & Secrets) or via
> `gcloud run services update --update-env-vars`. Cloud Run rolls a
> new revision in ~30 sec; the audit-log entry naming the operator is
> automatic. See the user guide section 9.6 for the canonical
> "Opus is offline → reroute to Sonnet" runbook.

## Extending

This gateway is intentionally minimal. The four traffic-policy controls
above are shipped; the items below are anticipated future extensions:

* **Cross-instance rate limiting.** Replace the in-process LRU in
  `rate_limit.py` with Cloud Memorystore (Redis) for exact per-caller
  enforcement at scale. Hot path is one INCR + one EXPIRE.
* **Automatic failover.** Try the requested model; on 429/503 retry
  against a configured fallback. Distinct from the shipped manual
  `MODEL_REWRITE` because the fallback only kicks in on upstream
  error. Touches the streaming-response path; needs careful design.
* **Prompt auditing.** Hash the request body (don't log it in clear
  text — it contains user source code) and emit the hash in the
  structured log.

Anything heavier than that probably belongs in a separate service
rather than in the pass-through proxy.
