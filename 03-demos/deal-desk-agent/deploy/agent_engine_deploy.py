"""
Deploy Deal Desk Agent to Vertex AI Agent Engine.
Uses the ADK pipeline with Claude on Vertex AI.
"""

import os
import sys

# Add backend to path so we can import the agent
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))

# Set required env vars before importing agent
os.environ["GOOGLE_CLOUD_PROJECT"] = "cpe-slarbi-nvd-ant-demos"
os.environ["GOOGLE_CLOUD_LOCATION"] = "us-east5"
os.environ["PROJECT_ID"] = "cpe-slarbi-nvd-ant-demos"
os.environ["REGION"] = "us-east5"
os.environ["BQ_DATASET"] = "deal_desk_agent"
os.environ["MODEL_PROVIDER"] = "claude"
os.environ["OPUS_MODEL"] = "claude-opus-4-5@20251101"
os.environ["SONNET_MODEL"] = "claude-sonnet-4-6@default"
os.environ["HAIKU_MODEL"] = "claude-haiku-4-5@20251001"

import vertexai
from vertexai import agent_engines
from agents import deal_desk_pipeline

PROJECT_ID = "cpe-slarbi-nvd-ant-demos"
LOCATION = "us-central1"
STAGING_BUCKET = "gs://cpe-slarbi-nvd-ant-demos-agent-staging"

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
        "service_account": f"deal-desk-agent-sa@{PROJECT_ID}.iam.gserviceaccount.com",
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
