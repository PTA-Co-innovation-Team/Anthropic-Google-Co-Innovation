# MCP Gateway

A [FastMCP](https://github.com/jlowin/fastmcp) server running on Cloud
Run, hosting shared [Model Context Protocol](https://modelcontextprotocol.io/)
tools for your team's Claude Code users.

Transport: **Streamable HTTP** (the March 2025 MCP spec standard — **not**
deprecated SSE).

Ships with one example tool: `gcp_project_info`. Add your own by
following [ADD_YOUR_OWN_TOOL.md](ADD_YOUR_OWN_TOOL.md).

## Endpoints

| Path | Method | Auth | Purpose |
| --- | --- | --- | --- |
| `/health` | GET | Cloud Run IAM (`roles/run.invoker` required) | Liveness probe for the e2e test script and Cloud Monitoring uptime checks. App-layer is open; the platform IAM check runs first. |
| `/mcp` | POST / GET / DELETE | Cloud Run IAM (`roles/run.invoker`) | MCP Streamable HTTP endpoint (JSON-RPC, session-based) |

> Need an *anonymous* external uptime probe? That isn't possible with
> the current ingress/auth posture — see the repo README's
> "External uptime probes" section for the SA-based Cloud Monitoring
> pattern.

The server is a **FastAPI app with FastMCP mounted at `/mcp`**. This
lets us serve an unauthenticated `/health` alongside the MCP endpoint
without forking FastMCP. The FastAPI+FastMCP lifespan is propagated
correctly so FastMCP's internal task manager starts on boot.

---

## How Claude Code talks to it

Claude Code can register HTTP MCP servers. The deploy script writes this
into each developer's Claude Code config:

```json
{
  "mcpServers": {
    "gcp-tools": {
      "type": "http",
      "url": "https://mcp-gateway-<hash>-uc.a.run.app/mcp"
    }
  }
}
```

Cloud Run's IAM invoker check means the developer's ADC token gets
attached automatically by Claude Code's MCP client — no additional
setup.

---

## Local development

Prereqs: Python 3.12, `uv` (`pip install uv`), `gcloud auth
application-default login` already run.

```bash
cd mcp-gateway
uv sync                 # installs deps into .venv/
uv run python server.py # starts the server on :8080
```

Quick sanity checks with `curl`:

```bash
# 1. Health probe — no auth required.
curl -s http://localhost:8080/health
# -> {"status":"ok","component":"mcp_gateway"}

# 2. Tool list through the MCP endpoint.
TOKEN=$(gcloud auth application-default print-access-token)
curl -s -X POST http://localhost:8080/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

You should see `gcp_project_info` in the tool list.

---

## Building and pushing the image

```bash
export REGION=us-east5
export PROJECT_ID=$(gcloud config get-value project)

gcloud builds submit \
  --tag "$REGION-docker.pkg.dev/$PROJECT_ID/claude-code-vertex-gcp/mcp-gateway:latest"
```

Or use the provided `scripts/deploy-mcp-gateway.sh`, which also
provisions the Artifact Registry repo + Cloud Run service + IAM on
first run.

---

## Deployment settings

The deploy scripts set the Cloud Run service up like this:

| Setting | Value | Why |
| --- | --- | --- |
| Ingress | `internal-and-cloud-load-balancing` | No public surface. |
| Auth | `--no-allow-unauthenticated` | IAM enforces `roles/run.invoker`. |
| Service account | dedicated SA with **only** the roles its tools need | Least privilege. |
| CPU | 1 | Tools are I/O-bound. |
| Memory | 512Mi | FastMCP + a few GCP clients fit easily. |
| Min instances | 0 | Scales to zero when idle. |
| Concurrency | 80 | Default; tools are stateless. |

---

## Extending

See [ADD_YOUR_OWN_TOOL.md](ADD_YOUR_OWN_TOOL.md) for a step-by-step
walkthrough of adding a new tool (worked example: "list GCS buckets").

Rough shape: drop a file under `tools/`, import + decorate in
`server.py`, grant the service account any needed IAM roles, redeploy.

---

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Claude Code doesn't see the server | `mcpServers.gcp-tools.url` in `~/.claude/settings.json` matches the Cloud Run URL |
| `403` on tool calls | Caller is missing `roles/run.invoker` on the service |
| Tool returns `{"error": "credentials_unavailable"}` locally | `gcloud auth application-default login` not yet run |
| Tool returns `PERMISSION_DENIED` in prod | Service account needs the GCP role for whatever API the tool hits |
