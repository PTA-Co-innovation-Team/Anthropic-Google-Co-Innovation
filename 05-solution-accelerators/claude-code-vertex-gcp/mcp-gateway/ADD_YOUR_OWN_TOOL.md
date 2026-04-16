# Adding your own MCP tool

This walkthrough adds a **new tool** that lists Google Cloud Storage
buckets in the current project. You'll end up with a tool Claude Code
can call as `list_gcs_buckets()`.

Zero prior MCP knowledge assumed. Takes about 10 minutes.

---

## What an MCP tool is (30 seconds)

A tool is **a Python function you register with the MCP server**.
Claude Code discovers it, reads its docstring and type hints as the
"schema," and can decide to call it during a conversation. When it
calls, Claude sends the arguments, your function runs, and the return
value is shown back to Claude.

All the protocol wire-up is handled by [FastMCP](https://github.com/jlowin/fastmcp).
You write a function; the library makes it callable by Claude.

---

## Step 1 — Add the GCS client to dependencies

Open `pyproject.toml`, find the `dependencies` array, and add one line:

```toml
dependencies = [
  "fastmcp>=0.2,<1.0",
  "google-auth>=2.34,<3.0",
  "google-cloud-storage>=2.18,<3.0",   # <-- new
]
```

If you are iterating locally with uv:

```bash
cd mcp-gateway
uv sync
```

If you're building the container straight away, no action needed —
Docker will pick up the new dep on next build.

---

## Step 2 — Create the tool file

Make a new file: `mcp-gateway/tools/list_gcs_buckets.py`

```python
"""MCP tool: list GCS buckets in the current project."""

from __future__ import annotations

from google.cloud import storage


def list_gcs_buckets(max_results: int = 50) -> dict:
    """Return the names of GCS buckets in the current project.

    Args:
        max_results: Cap on how many bucket names to return. Default 50.
                     Claude will see this in the tool schema and can
                     pass a different value if it needs more.

    Returns:
        A dict with:
          * ``buckets``: list of bucket name strings
          * ``count``:   number of buckets returned
          * ``truncated``: True if there were more than ``max_results``
    """
    # google-cloud-storage picks up ADC automatically. On Cloud Run
    # that's the attached service account; locally it's your user.
    client = storage.Client()

    names: list[str] = []
    truncated = False
    for i, bucket in enumerate(client.list_buckets()):
        if i >= max_results:
            truncated = True
            break
        names.append(bucket.name)

    return {
        "buckets": names,
        "count": len(names),
        "truncated": truncated,
    }
```

**Why this shape?**

- **Type hints on every argument.** FastMCP turns these into the JSON
  schema Claude sees, so arg types matter.
- **A descriptive docstring.** The first paragraph becomes the tool
  description Claude reads. Say what it does, what it returns, and any
  gotchas. Be terse but specific.
- **Return a dict, not a bespoke class.** MCP tool results are JSON.
  Dicts serialize cleanly; custom objects need extra work.
- **Handle errors inside the function.** Convert exceptions to fields
  in the return dict (e.g., `{"error": ..., "detail": ...}`) rather
  than letting them bubble out — see `gcp_project_info.py` for the
  pattern.

---

## Step 3 — Register it on the server

Edit `mcp-gateway/server.py`. Add the import near the other tool
import, and add a `@mcp.tool()`-decorated wrapper:

```python
from tools.list_gcs_buckets import list_gcs_buckets as _list_gcs_buckets

@mcp.tool()
def list_gcs_buckets(max_results: int = 50) -> dict:
    """List up to ``max_results`` GCS buckets in this project."""
    return _list_gcs_buckets(max_results=max_results)
```

The wrapper looks redundant but serves a purpose: Claude reads the
**decorated function's** signature and docstring for the tool schema.
Keeping a thin wrapper in `server.py` makes the tool surface easy to
audit (one file, all tools visible) while the implementation lives in
its own module.

---

## Step 4 — Grant the service account GCS read permission

The MCP gateway's service account needs to be allowed to list buckets.
Grant the role:

```bash
# Find the service account email (Terraform outputs it as
# mcp_gateway_service_account; or look in the Cloud Console).
SA_EMAIL=mcp-gateway@$PROJECT_ID.iam.gserviceaccount.com

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/storage.objectViewer"
```

For bucket *listing* specifically you need `roles/storage.viewer`
(or `roles/storage.admin`). Use the least-privilege role that actually
works for your tool — the error messages when permissions are missing
are clear, so err on the side of too-narrow.

---

## Step 5 — Redeploy

```bash
cd mcp-gateway
gcloud builds submit --tag "$REGION-docker.pkg.dev/$PROJECT_ID/claude-code-vertex-gcp/mcp-gateway:latest"
gcloud run deploy mcp-gateway \
  --region=$REGION \
  --image="$REGION-docker.pkg.dev/$PROJECT_ID/claude-code-vertex-gcp/mcp-gateway:latest" \
  --no-allow-unauthenticated
```

Or just re-run `scripts/deploy-mcp-gateway.sh` — it does the same thing.

---

## Step 6 — Try it from Claude Code

In a Claude Code session, ask:

> List the GCS buckets in my project.

Claude will see the tool (because its name/docstring describe exactly
this), call it, and show you the names. If something's wrong, the
error will come back in the tool result, visible in Claude's response.

---

## Tips

- **Keep each tool in its own file** under `tools/`. Makes reviews
  easier and prevents `server.py` from growing forever.
- **Parameters should be simple types.** Strings, ints, lists,
  dicts — things that JSON-encode naturally. If you find yourself
  wanting to pass a custom class, break the arguments out into
  primitives.
- **Return *something* always.** Even on error. An empty return makes
  Claude guess; an explicit `{"error": "..."}` is actionable.
- **Log important calls.** `logging.getLogger("mcp-gateway").info(...)`
  emits a structured line visible in Cloud Logging — great for
  auditing what tools get invoked.
- **Don't leak secrets in tool results.** Claude's responses are
  stored in session logs and may be echoed back to the user verbatim.
  Never return raw credentials or PII.

---

## Common pitfalls

| Symptom | Likely cause |
| --- | --- |
| Tool not visible to Claude | Didn't add `@mcp.tool()` decorator; forgot to import in `server.py` |
| `PERMISSION_DENIED` at runtime | Service account missing the IAM role the tool needs |
| `ModuleNotFoundError` for a new dep | Forgot to rebuild the container after editing `pyproject.toml` |
| Tool hangs | Long-running call; wrap with `asyncio.wait_for` or use a timeout in the client library |
