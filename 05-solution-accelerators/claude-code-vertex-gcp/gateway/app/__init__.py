"""LLM Gateway package.

A tiny FastAPI reverse proxy that sits between Claude Code (running on a
developer's machine or the Dev VM) and the Vertex AI Anthropic endpoint.

It does four things:

1. Accepts incoming HTTPS requests from Claude Code.
2. Verifies (via Cloud Run's built-in IAM enforcement) that the caller has
   ``roles/run.invoker``. Cloud Run rejects unauthenticated callers before
   we ever see them, so by the time a request hits our FastAPI app it is
   already authenticated. We just capture *who* the caller is for logging.
3. Strips Anthropic-only beta headers that Vertex does not accept.
4. Forwards the request to the real Vertex AI endpoint using the Cloud Run
   service account's Application Default Credentials.

See the repo-root ARCHITECTURE.md for the big picture.
"""

# Semantic version of the gateway image. Bump when you change behavior.
__version__ = "0.1.0"
