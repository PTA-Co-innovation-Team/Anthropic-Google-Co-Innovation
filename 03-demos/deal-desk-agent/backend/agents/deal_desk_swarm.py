"""
Deal Desk Agent Swarm — ADK orchestration for the Deal Desk pipeline.
Powered by Claude models on Vertex AI, with Gemini swap capability for future use.

Architecture:
  ParallelAgent (Research + Compliance)
    → SequentialAgent (Risk → Synthesis)

All agents write to shared session state via output_key.
"""

import os
from google.adk.agents import LlmAgent, SequentialAgent, ParallelAgent
from google.adk.models.anthropic_llm import Claude
from google.adk.models.registry import LLMRegistry

from tools.bigquery_tools import (
    query_client_data,
    query_market_intelligence,
    query_compliance_records,
    update_client_status,
    insert_deal_package,
)
from tools.risk_scoring import compute_risk_score

# ═══════════════════════════════════════════════════════════════════════════════
# MODEL CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

MODEL_PROVIDER = os.environ.get("MODEL_PROVIDER", "claude")

# Claude on Vertex AI (default for NEXT demo)
CLAUDE_MODELS = {
    "opus": os.environ.get("OPUS_MODEL", "claude-opus-4-5@20251101"),
    "sonnet": os.environ.get("SONNET_MODEL", "claude-sonnet-4-6@default"),
    "haiku": os.environ.get("HAIKU_MODEL", "claude-haiku-4-5@20251001"),
}

# Gemini on Vertex AI (future use)
GEMINI_MODELS = {
    "opus": os.environ.get("GEMINI_LARGE", "gemini-2.5-pro"),
    "sonnet": os.environ.get("GEMINI_MID", "gemini-2.5-flash"),
    "haiku": os.environ.get("GEMINI_SMALL", "gemini-2.5-flash-lite"),
}


def get_model(tier: str) -> str:
    """
    Return the model string for a given tier (opus/sonnet/haiku).
    Reads MODEL_PROVIDER env var to swap between Claude and Gemini.
    """
    if MODEL_PROVIDER == "gemini":
        return GEMINI_MODELS[tier]
    return CLAUDE_MODELS[tier]


# Register Claude wrapper so ADK recognizes Claude model strings
if MODEL_PROVIDER == "claude":
    LLMRegistry.register(Claude)


# ═══════════════════════════════════════════════════════════════════════════════
# AGENT DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Research Agent (Opus 4.5) ────────────────────────────────────────────────
research_agent = LlmAgent(
    name="research_agent",
    model=get_model("opus"),
    description="Researches client background, prior relationships, and market intelligence.",
    instruction="""You are the Research Agent in an FSI Deal Desk pipeline.
Your job is to gather comprehensive intelligence on the client being onboarded.

When given a client name and details:
1. Use query_client_data to look up any existing records for this client.
2. Use query_market_intelligence to find recent SEC filings, news, and market data.
3. Synthesize your findings into a structured research brief.

Your output should include:
- Whether the client is new or has a prior relationship
- Key financial data (AUM, strategy, recent performance if available)
- Relevant market intelligence (filings, news, hiring signals)
- Any notable items that compliance or risk should be aware of

Be thorough but concise. Write for a senior portfolio manager audience.""",
    tools=[query_client_data, query_market_intelligence],
    output_key="research_output",
)

# ─── Compliance Agent (Sonnet 4.6) ────────────────────────────────────────────
compliance_agent = LlmAgent(
    name="compliance_agent",
    model=get_model("sonnet"),
    description="Runs KYC, AML, sanctions, and FINRA compliance checks.",
    instruction="""You are the Compliance Agent in an FSI Deal Desk pipeline.
Your job is to verify that a client passes all regulatory requirements.

When given a client name and details:
1. Use query_compliance_records to retrieve existing compliance data.
2. Evaluate each compliance dimension:
   - KYC (Know Your Customer) verification status
   - AML (Anti-Money Laundering) screening
   - Sanctions screening (OFAC, EU, UN)
   - FINRA registration and disclosure history
3. Provide a clear compliance determination.

Your output should include:
- Status for each compliance check (CLEAR / PENDING / REVIEW / FAILED)
- Overall compliance determination (CLEARED / BLOCKED / CONDITIONAL)
- Any items requiring manual review or escalation
- Recommended next steps if any checks are not clear

Flag any blockers immediately. Do not soft-pedal compliance issues.""",
    tools=[query_compliance_records],
    output_key="compliance_output",
)

# ─── Parallel Intake (Research + Compliance run simultaneously) ────────────────
parallel_intake = ParallelAgent(
    name="parallel_intake",
    description="Runs research and compliance checks in parallel for efficiency.",
    sub_agents=[research_agent, compliance_agent],
)

# ─── Risk Scoring Agent (Haiku 4.5) ──────────────────────────────────────────
risk_agent = LlmAgent(
    name="risk_agent",
    model=get_model("haiku"),
    description="Evaluates client risk based on research and compliance findings.",
    instruction="""You are the Risk Scoring Agent in an FSI Deal Desk pipeline.
Your job is to assess the overall risk of onboarding this client.

You have access to:
- Research findings in {research_output}
- Compliance findings in {compliance_output}

Steps:
1. Extract the key risk factors from the research and compliance outputs:
   client name, AUM, strategy, domicile, KYC status, AML status, sanctions status.
2. Use compute_risk_score with these parameters to get a quantitative assessment.
3. Review the score, tier, and any blockers returned.
4. Provide your risk assessment with a clear recommendation.

Your output should include:
- The numeric risk score and tier
- Key risk factors and their contributions
- Any blockers that prevent onboarding
- Your recommendation: APPROVE / APPROVE WITH CONDITIONS / HOLD / ESCALATE

Be decisive. Risk assessments must be clear and actionable.""",
    tools=[compute_risk_score],
    output_key="risk_output",
)

# ─── Synthesis Agent (Opus 4.5) ──────────────────────────────────────────────
synthesis_agent = LlmAgent(
    name="synthesis_agent",
    model=get_model("opus"),
    description="Synthesizes all findings into a deal package and logs it to BigQuery.",
    instruction="""You are the Synthesis Agent in an FSI Deal Desk pipeline.
Your job is to produce the final deal package and log it to the system of record.

You have access to:
- Research findings in {research_output}
- Compliance findings in {compliance_output}
- Risk assessment in {risk_output}

Steps:
1. Review all three inputs and produce a structured deal summary.
2. If compliance is CLEARED and risk recommendation is APPROVE or APPROVE WITH CONDITIONS:
   a. Use insert_deal_package to log the deal to BigQuery with all relevant fields.
   b. Use update_client_status to set the client's relationship status to 'Active'.
3. If compliance is BLOCKED or risk says HOLD/ESCALATE:
   a. Still log the deal with appropriate status and notes explaining why it was held.
   b. Do NOT update client status.

Your final output should be a structured deal package containing:
- Client name, AUM, strategy, mandate type, fee structure
- Compliance status summary
- Risk tier and score
- Primary contact name and title
- Deal ID (from the insert_deal_package response)
- Status: APPROVED / APPROVED_WITH_CONDITIONS / ON_HOLD / ESCALATED
- Summary notes explaining the decision

This deal package will be passed to the Salesforce Agent for CRM entry.""",
    tools=[insert_deal_package, update_client_status],
    output_key="deal_package",
)

# ─── Sequential Pipeline (Risk → Synthesis, runs after parallel intake) ───────
post_intake_pipeline = SequentialAgent(
    name="post_intake_pipeline",
    description="Runs risk assessment then synthesis sequentially after parallel intake.",
    sub_agents=[risk_agent, synthesis_agent],
)

# ═══════════════════════════════════════════════════════════════════════════════
# TOP-LEVEL PIPELINE
# ═══════════════════════════════════════════════════════════════════════════════

deal_desk_pipeline = SequentialAgent(
    name="deal_desk_pipeline",
    description="""End-to-end Deal Desk pipeline for FSI client onboarding.
    Runs research and compliance in parallel, then risk scoring, then synthesis.
    Produces a complete deal package ready for Salesforce entry.""",
    sub_agents=[parallel_intake, post_intake_pipeline],
)
