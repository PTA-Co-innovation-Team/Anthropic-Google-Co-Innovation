"""
Browser Agent Server — runs on the GCE VM alongside the virtual desktop.
Accepts a deal package via POST, triggers the Salesforce browser agent,
and streams events back via SSE.
"""
import os
import sys
import json
import asyncio
import logging
import secrets
from datetime import datetime, timezone
from fastapi import FastAPI, Request, Header, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse, JSONResponse

sys.path.insert(0, "/opt/venv")
from salesforce_browser_agent import run_salesforce_agent

logger = logging.getLogger("agent-server")
logging.basicConfig(level=logging.INFO)

# ─── Shared-secret auth ───
# Loaded at module-import time. If unset, /run and /test-vertex will reject all
# requests (fail-closed) but /health stays open so GCE/uptime checks still work.
AGENT_SECRET = os.environ.get("AGENT_SECRET", "")
if not AGENT_SECRET:
    logger.warning(
        "AGENT_SECRET is not set — /run and /test-vertex will reject all requests. "
        "Set AGENT_SECRET via --container-env to enable authenticated calls."
    )


def verify_secret(x_agent_secret: str = Header(None)):
    """Constant-time comparison of the X-Agent-Secret header against AGENT_SECRET."""
    if not AGENT_SECRET:
        raise HTTPException(status_code=503, detail="Server misconfigured: AGENT_SECRET not set")
    if not x_agent_secret or not secrets.compare_digest(x_agent_secret, AGENT_SECRET):
        raise HTTPException(status_code=401, detail="Invalid or missing X-Agent-Secret header")
    return True


app = FastAPI(title="Browser Agent Server")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health():
    return {"status": "healthy", "service": "browser-agent-server"}


@app.get("/test-vertex", dependencies=[Depends(verify_secret)])
async def test_vertex():
    """Minimal rawPredict call to diagnose 400 errors. Returns raw Vertex response."""
    import httpx
    import google.auth
    import google.auth.transport.requests

    PROJECT_ID = os.environ.get("PROJECT_ID", "cpe-slarbi-nvd-ant-demos")
    REGION = os.environ.get("REGION", "us-east5")
    MODEL = os.environ.get("SONNET_MODEL", "claude-sonnet-4-6@default")

    url = (
        f"https://{REGION}-aiplatform.googleapis.com/v1/"
        f"projects/{PROJECT_ID}/locations/{REGION}/"
        f"publishers/anthropic/models/{MODEL}:rawPredict"
    )

    credentials, _ = google.auth.default()
    credentials.refresh(google.auth.transport.requests.Request())
    token = credentials.token

    payload = {
        "anthropic_version": "vertex-2023-10-16",
        "max_tokens": 256,
        "system": "Say hello.",
        "messages": [
            {"role": "user", "content": "Hi"}
        ],
        "tools": [
            {
                "type": "computer_20250124",
                "name": "computer",
                "display_width_px": 1280,
                "display_height_px": 800,
                "display_number": 1,
            }
        ],
    }

    results = {}

    # Test A: beta = computer-use-2025-01-24
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(url, headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "anthropic-beta": "computer-use-2025-01-24",
        }, json=payload)
        results["test_A_beta_jan"] = {"status": resp.status_code, "body": resp.text[:2000]}

    # Test B: beta = computer-use-2025-10-01
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(url, headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "anthropic-beta": "computer-use-2025-10-01",
        }, json=payload)
        results["test_B_beta_oct"] = {"status": resp.status_code, "body": resp.text[:2000]}

    # Test C: no beta header
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(url, headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }, json=payload)
        results["test_C_no_beta"] = {"status": resp.status_code, "body": resp.text[:2000]}

    # Test D: no tools (baseline)
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(url, headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }, json={
            "anthropic_version": "vertex-2023-10-16",
            "max_tokens": 256,
            "system": "Say hello.",
            "messages": [{"role": "user", "content": "Hi"}],
        })
        results["test_D_no_tools_baseline"] = {"status": resp.status_code, "body": resp.text[:2000]}

    return results


@app.post("/run", dependencies=[Depends(verify_secret)])
async def run_agent(request: Request):
    body = await request.json()
    deal_package = body.get("deal_package", {})
    if not deal_package:
        return JSONResponse(status_code=400, content={"error": "deal_package is required"})

    async def event_stream():
        async for event in run_salesforce_agent(deal_package):
            payload = json.dumps({
                **event,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            })
            yield f"data: {payload}\n\n"

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8090)
