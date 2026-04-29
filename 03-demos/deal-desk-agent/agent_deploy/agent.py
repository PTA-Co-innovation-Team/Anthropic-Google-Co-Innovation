"""Deal Desk Agent — root agent definition for Agent Engine deployment.

Conversational agent that can:
- Answer data queries (list clients, compliance, deals)
- Trigger the full onboarding pipeline when requested
- Provide client deep dives
"""
import os

# Set env vars needed by the agent
os.environ.setdefault("GOOGLE_CLOUD_PROJECT", "cpe-slarbi-nvd-ant-demos")
os.environ["GOOGLE_CLOUD_LOCATION"] = "us-east5"
os.environ.setdefault("PROJECT_ID", "cpe-slarbi-nvd-ant-demos")
os.environ["REGION"] = "us-east5"
os.environ.setdefault("BQ_DATASET", "deal_desk_agent")
os.environ.setdefault("MODEL_PROVIDER", "claude")
os.environ.setdefault("OPUS_MODEL", "claude-opus-4-5@20251101")
os.environ.setdefault("SONNET_MODEL", "claude-sonnet-4-6@default")
os.environ.setdefault("HAIKU_MODEL", "claude-haiku-4-5@20251001")

from google.adk.agents import LlmAgent, SequentialAgent, ParallelAgent
from google.adk.models.anthropic_llm import Claude
from google.adk.models.registry import LLMRegistry
LLMRegistry.register(Claude)

from .tools import (
    query_client_data,
    query_market_intelligence,
    query_compliance_records,
    update_client_status,
    insert_deal_package,
    list_all_clients,
    list_all_compliance,
    list_deal_packages,
    trigger_salesforce_opportunity,
)
from .risk_scoring import compute_risk_score

OPUS = os.environ.get("OPUS_MODEL", "claude-opus-4-5@20251101")
SONNET = os.environ.get("SONNET_MODEL", "claude-sonnet-4-6@default")
HAIKU = os.environ.get("HAIKU_MODEL", "claude-haiku-4-5@20251001")

# ═══════════════════════════════════════════════════════════════════════════════
# PIPELINE SUB-AGENTS (for full onboarding flow)
# ═══════════════════════════════════════════════════════════════════════════════

research_agent = LlmAgent(
    name="research_agent",
    model=OPUS,
    description="Researches client background, prior relationships, and market intelligence.",
    instruction="You are the Research Agent. Use query_client_data and query_market_intelligence to gather intelligence on the client being onboarded. Provide a structured research brief.",
    tools=[query_client_data, query_market_intelligence],
    output_key="research_output",
)

compliance_agent = LlmAgent(
    name="compliance_agent",
    model=SONNET,
    description="Runs KYC, AML, sanctions, and FINRA compliance checks.",
    instruction="You are the Compliance Agent. Use query_compliance_records to verify regulatory compliance. Provide clear status for each check.",
    tools=[query_compliance_records],
    output_key="compliance_output",
)

parallel_intake = ParallelAgent(
    name="parallel_intake",
    description="Runs research and compliance in parallel.",
    sub_agents=[research_agent, compliance_agent],
)

risk_agent = LlmAgent(
    name="risk_agent",
    model=HAIKU,
    description="Evaluates client risk based on research and compliance findings.",
    instruction="You are the Risk Agent. Read {research_output} and {compliance_output}, then use compute_risk_score to assess risk. Provide recommendation.",
    tools=[compute_risk_score],
    output_key="risk_output",
)

synthesis_agent = LlmAgent(
    name="synthesis_agent",
    model=OPUS,
    description="Synthesizes deal package and logs to BigQuery.",
    instruction="You are the Synthesis Agent. Read {research_output}, {compliance_output}, {risk_output}. Use insert_deal_package to log the deal and update_client_status to activate the client.",
    tools=[insert_deal_package, update_client_status],
    output_key="deal_package",
)

post_intake = SequentialAgent(
    name="post_intake",
    sub_agents=[risk_agent, synthesis_agent],
)

deal_desk_pipeline = SequentialAgent(
    name="deal_desk_pipeline",
    description="Full onboarding pipeline: parallel research + compliance, then risk scoring, then deal synthesis. Use this when the user asks to onboard a client or run the full pipeline.",
    sub_agents=[parallel_intake, post_intake],
)

# ═══════════════════════════════════════════════════════════════════════════════
# ROOT AGENT — Conversational with pipeline delegation
# ═══════════════════════════════════════════════════════════════════════════════

root_agent = LlmAgent(
    name="deal_desk_agent",
    model=SONNET,
    description="Conversational FSI Deal Desk agent with data access and onboarding pipeline.",
    instruction="""You are the Deal Desk Agent, a professional AI assistant for financial services deal management at a hedge fund.

You are powered by Claude AI models on Google Cloud Vertex AI, orchestrated by Google's Agent Development Kit (ADK).

YOUR CAPABILITIES:
1. **Data Queries**: List all clients, look up specific clients, check compliance records, view market intelligence, and review deal packages. Use the appropriate tool for each query.
2. **Client Onboarding**: When the user asks to onboard a client, run compliance checks, or process a deal — delegate to the deal_desk_pipeline sub-agent which runs the full parallel pipeline (research + compliance → risk → synthesis).
3. **Compliance Checks**: Query compliance records for any client.

GUIDELINES:
- When the user says "show me our clients" or "list clients", use the list_all_clients tool and present the results in a clear table format.
- When the user asks about a specific client, use query_client_data to look them up.
- When the user asks to onboard a client or run the full pipeline, delegate to the deal_desk_pipeline.
- Always present BigQuery data in clean, formatted tables with columns for key fields.
- When the user asks to onboard a client, create a Salesforce Opportunity, or process a deal, ALWAYS use trigger_salesforce_opportunity with the client name. This is the primary action tool. Always include the live_view_url from the tool result in your response so the user can watch the agent work.
- Do NOT delegate to deal_desk_pipeline for onboarding requests — use trigger_salesforce_opportunity directly.
- IMPORTANT: If the user says "thank you", "thanks", "ok", "done", or any short acknowledgment, DO NOT trigger any tools. Instead, respond with a warm, professional farewell like "You're welcome! Let me know if you need anything else." Always respond with text — never return an empty response.
- Be warm, professional, and concise.
- Mention that data is pulled live from BigQuery via Google Cloud.""",
    tools=[
        list_all_clients,
        list_all_compliance,
        list_deal_packages,
        query_client_data,
        query_market_intelligence,
        query_compliance_records,
        trigger_salesforce_opportunity,
    ],
    sub_agents=[deal_desk_pipeline],
)
