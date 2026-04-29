"""
Deploy Deal Desk Agent to Vertex AI Agent Engine.
Uses the ADK pipeline with Claude on Vertex AI.
"""

import os
import sys

# Add backend to path so we can import the agent
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

# All deploy-time configuration is read from the environment.
# Required: GOOGLE_CLOUD_PROJECT (or PROJECT_ID).
# Optional: GOOGLE_CLOUD_LOCATION/REGION, BQ_DATASET, OPUS_MODEL, SONNET_MODEL,
#   HAIKU_MODEL, AGENT_ENGINE_LOCATION, STAGING_BUCKET.

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get("PROJECT_ID")
if not PROJECT_ID:
    raise RuntimeError(
        "Set GOOGLE_CLOUD_PROJECT (or PROJECT_ID) before running this script."
    )

os.environ.setdefault("GOOGLE_CLOUD_PROJECT", PROJECT_ID)
os.environ.setdefault("PROJECT_ID", PROJECT_ID)
os.environ.setdefault("GOOGLE_CLOUD_LOCATION", os.environ.get("REGION", "us-east5"))
os.environ.setdefault("REGION", os.environ["GOOGLE_CLOUD_LOCATION"])
os.environ.setdefault("BQ_DATASET", "deal_desk_agent")
os.environ.setdefault("MODEL_PROVIDER", "claude")
os.environ.setdefault("OPUS_MODEL", "claude-opus-4-5@20251101")
os.environ.setdefault("SONNET_MODEL", "claude-sonnet-4-6@default")
os.environ.setdefault("HAIKU_MODEL", "claude-haiku-4-5@20251001")

import vertexai
from vertexai import agent_engines
from agents import deal_desk_pipeline

LOCATION = os.environ.get("AGENT_ENGINE_LOCATION", "us-central1")
STAGING_BUCKET = os.environ.get("STAGING_BUCKET", f"gs://{PROJECT_ID}-agent-staging")

print("═" * 60)
print("  Deal Desk Agent — Agent Engine Deployment")
print(f"  Project:  {PROJECT_ID}")
print(f"  Location: {LOCATION}")
print(f"  Staging:  {STAGING_BUCKET}")
print("═" * 60)

# Initialize Vertex AI
vertexai.init(project=PROJECT_ID, location=LOCATION)

# Wrap in AdkApp
print("\n📦 Wrapping agent in AdkApp...")
app = agent_engines.AdkApp(
    agent=deal_desk_pipeline,
    enable_tracing=True,
)

# Test locally first
print("🧪 Testing locally...")
try:
    for event in app.stream_query(
        user_id="test-user",
        message="hello",
    ):
        print(f"  Event: {type(event).__name__}")
    print("✅ Local test passed")
except Exception as e:
    print(f"⚠️  Local test error (may be expected for Claude): {e}")

# Deploy
print("\n🚀 Deploying to Agent Engine (this takes 5-10 minutes)...")
client = vertexai.Client(project=PROJECT_ID, location=LOCATION)

remote_agent = client.agent_engines.create(
    agent=app,
    config={
        "requirements": [
            "cloudpickle>=3.0.0",
            "pydantic>=2.0.0",
            "google-cloud-aiplatform[agent_engines,adk]",
            "google-adk>=1.2.0",
            "anthropic[vertex]>=0.43.0",
            "google-cloud-bigquery>=3.27.0",
        ],
        "staging_bucket": STAGING_BUCKET,
        "display_name": "Deal Desk Agent",
        "description": "FSI Deal Desk pipeline — Claude on Vertex AI + ADK",
        "service_account": os.environ.get(
            "AGENT_SERVICE_ACCOUNT",
            f"deal-desk-agent-sa@{PROJECT_ID}.iam.gserviceaccount.com",
        ),
    },
)

print(f"\n✅ Agent Engine deployed!")
print(f"   Resource: {remote_agent.api_resource}")
print(f"   Operations: {remote_agent.operation_schemas()}")

# Save resource info
import json
output = {
    "resource_name": str(remote_agent.api_resource),
    "project": PROJECT_ID,
    "location": LOCATION,
}
with open(os.path.join(os.path.dirname(__file__), "agent_engine_output.json"), "w") as f:
    json.dump(output, f, indent=2)
print(f"   Saved to: deploy/agent_engine_output.json")
