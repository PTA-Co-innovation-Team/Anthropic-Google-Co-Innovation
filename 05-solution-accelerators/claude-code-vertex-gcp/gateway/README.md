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

## Deployment settings

The deploy scripts set the Cloud Run service up like this:

| Setting | Standard mode | GLB mode | VPC internal mode | Why |
| --- | --- | --- | --- | --- |
| Ingress | `all` | `internal-and-cloud-load-balancing` | `internal` | Standard: laptops reach directly. GLB: only GLB can reach it. VPC internal: only VPC clients can reach it. |
| Auth | `--no-invoker-iam-check` | *(same)* | *(same)* | Cloud Run IAM disabled; app-level token validation handles auth. |
| Env: `ENABLE_TOKEN_VALIDATION` | `1` | `1` | `1` | Activates `token_validation.py` middleware (always on). |
| Env: `ALLOWED_PRINCIPALS` | comma-separated emails | *(same)* | *(same)* | Restricts which Google identities can call the gateway. |
| VPC Connector | optional | optional | **forced on** | Required for Private Google Access egress in VPC internal mode. |
| Service account | dedicated SA with `roles/aiplatform.user` + `roles/logging.logWriter` | *(same)* | *(same)* | Least privilege. |

VPC internal mode is mutually exclusive with GLB mode.

---

## Extending

This gateway is intentionally minimal. Places to extend:

* **Per-user rate limiting.** Use Cloud Armor or add a simple Redis-backed
  token-bucket in `proxy.py`.
* **Prompt auditing.** Hash the request body (don't log it in clear text —
  it contains user source code) and emit the hash in the structured log.
* **Model whitelisting.** Reject requests whose `model` doesn't match an
  allowlist — add the check in `proxy.py` before forwarding.

Anything heavier than that probably belongs in a separate service rather
than in the pass-through proxy.
