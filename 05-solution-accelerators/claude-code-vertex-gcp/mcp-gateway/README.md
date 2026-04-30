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
| `/health` | GET | Open (bypasses token validation). | Liveness probe for the e2e test script, Cloud Monitoring uptime checks, and GLB health probes. |
| `/mcp` | POST / GET / DELETE | App-level token validation (`token_validation.py`) — accepts both OAuth2 access tokens and OIDC identity tokens. | MCP Streamable HTTP endpoint (JSON-RPC, session-based) |

> Cloud Run's invoker IAM check is **disabled** (`--no-invoker-iam-check`)
> because Claude Code sends OAuth2 access tokens, which Cloud Run IAM
> rejects. Auth is handled by the `token_validation.py` middleware,
> which enforces an `ALLOWED_PRINCIPALS` allowlist. In **standard mode**,
> ingress is `all`; in **GLB mode**, ingress is
> `internal-and-cloud-load-balancing` (only the GLB can reach the service);
> in **VPC internal mode**, ingress is `internal` (only clients within the
> VPC can reach the service).

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

In standard mode, Cloud Run's IAM invoker check means the developer's
ADC token gets attached automatically by Claude Code's MCP client. In
GLB mode, the URL points to the GLB (e.g. `https://<glb-ip>/mcp`) and
the app-level middleware validates the token instead.

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

| Setting | Standard mode | GLB mode | VPC internal mode | Why |
| --- | --- | --- | --- | --- |
| Ingress | `all` | `internal-and-cloud-load-balancing` | `internal` | Standard: laptops reach directly. GLB: only GLB can reach it. VPC internal: only VPC clients can reach it. |
| Auth | `--no-invoker-iam-check` | *(same)* | *(same)* | Cloud Run IAM disabled; app-level token validation handles auth. |
| Env: `ENABLE_TOKEN_VALIDATION` | `1` | `1` | `1` | Activates `token_validation.py` middleware (always on). |
| Env: `ALLOWED_PRINCIPALS` | comma-separated emails | *(same)* | *(same)* | Restricts which Google identities can call the gateway. |
| VPC Connector | optional | optional | **forced on** | Required for Private Google Access egress in VPC internal mode. |
| Service account | dedicated SA with **only** the roles its tools need | *(same)* | *(same)* | Least privilege. |
| CPU | 1 | *(same)* | *(same)* | Tools are I/O-bound. |
| Memory | 512Mi | *(same)* | *(same)* | FastMCP + a few GCP clients fit easily. |
| Min instances | 0 | *(same)* | *(same)* | Scales to zero when idle. |
| Concurrency | 80 | *(same)* | *(same)* | Default; tools are stateless. |

VPC internal mode is mutually exclusive with GLB mode.

### Token validation middleware

`token_validation.py` is registered conditionally in `server.py` when
`ENABLE_TOKEN_VALIDATION=1`. It validates both OAuth2 access tokens
(via Google's `tokeninfo` endpoint with 30s TTL cache) and OIDC
identity tokens (via `google.oauth2.id_token.verify_oauth2_token`).
Health endpoints (`/health`, `/healthz`) bypass validation so GLB
probes work without a token.

> **Sync requirement:** `mcp-gateway/token_validation.py` is a copy of
> `gateway/app/token_validation.py`. The pre-deploy check script
> (`scripts/pre-deploy-check.sh`) verifies the two files are in sync.
> When editing one, update the other.

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
| Claude Code doesn't see the server | `mcpServers.gcp-tools.url` in `~/.claude/settings.json` matches the Cloud Run URL (or GLB URL in GLB mode) |
| `401` on tool calls | Token is missing or invalid. Check `ENABLE_TOKEN_VALIDATION` is `1` and the token is a valid Google credential |
| `403` on tool calls | Token is valid but the caller's email is not in `ALLOWED_PRINCIPALS` |
| Tool returns `{"error": "credentials_unavailable"}` locally | `gcloud auth application-default login` not yet run |
| Tool returns `PERMISSION_DENIED` in prod | Service account needs the GCP role for whatever API the tool hits |
