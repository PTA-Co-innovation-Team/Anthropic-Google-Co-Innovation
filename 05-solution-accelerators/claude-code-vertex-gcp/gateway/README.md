# LLM Gateway

A ~150-line FastAPI reverse proxy that sits between Claude Code and the
Vertex AI Anthropic endpoint. Runs on Cloud Run.

Its **only jobs** are:

1. Let Cloud Run's IAM layer authenticate the caller
   (`roles/run.invoker`).
2. Strip Anthropic-only beta headers Vertex doesn't accept.
3. Replace the caller's bearer token with the gateway service account's
   token (obtained via ADC).
4. Forward the request to the right Vertex regional host, stream the
   response back.
5. Emit a structured JSON log entry per request.

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

The tests mock out Google credentials and the upstream HTTP call; they
run offline in ~1 second.

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
          │  (Cloud Run enforces roles/run.invoker)
          ▼
┌────────────────────┐
│  app/main.py       │  Catch-all route, dispatches to proxy_request
│  app/proxy.py      │  * Extracts caller email (from x-goog- headers)
│                    │  * Strips anthropic-beta, Authorization, hop-by-hop
│                    │  * Fetches fresh bearer via google-auth
│                    │  * Streams to Vertex with httpx.AsyncClient
│  app/headers.py    │  * Header sanitation rules
│  app/auth.py       │  * Caller-identity extraction + ADC token
│  app/logging_config│  * JSON-to-stdout for Cloud Logging
└─────────┬──────────┘
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
