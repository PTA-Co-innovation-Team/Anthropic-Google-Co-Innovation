"""
Deal Desk Agent — FastAPI backend.
Serves the ADK pipeline with SSE streaming for real-time agent events.
Deployed on Cloud Run, backed by Claude on Vertex AI.
"""

import os
import json
import asyncio
import httpx
import logging
from datetime import datetime, timezone
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse, JSONResponse, FileResponse
from google.cloud import bigquery
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.adk.sessions import VertexAiSessionService
from google.genai import types

from agents import deal_desk_pipeline

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════════════════════════════════════════

PROJECT_ID = os.environ.get("PROJECT_ID", "cpe-slarbi-nvd-ant-demos")
DATASET = os.environ.get("BQ_DATASET", "deal_desk_agent")
REGION = os.environ.get("REGION", "us-east5")
PORT = int(os.environ.get("PORT", 8080))

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("deal-desk-agent")

# ═══════════════════════════════════════════════════════════════════════════════
# ADK RUNNER SETUP
# ═══════════════════════════════════════════════════════════════════════════════

session_service = InMemorySessionService()

runner = Runner(
    agent=deal_desk_pipeline,
    app_name="deal_desk_agent",
    session_service=session_service,
)

# ═══════════════════════════════════════════════════════════════════════════════
# FASTAPI APP
# ═══════════════════════════════════════════════════════════════════════════════

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(f"Deal Desk Agent starting — project={PROJECT_ID}, region={REGION}")
    logger.info(f"Model provider: {os.environ.get('MODEL_PROVIDER', 'claude')}")
    yield
    logger.info("Deal Desk Agent shutting down")

app = FastAPI(
    title="Deal Desk Agent",
    description="FSI Deal Desk pipeline — Anthropic + Google Cloud Better Together",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ═══════════════════════════════════════════════════════════════════════════════
# SSE EVENT HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

def sse_event(event_type: str, data: dict) -> str:
    """Format a Server-Sent Event."""
    payload = json.dumps({
        "type": event_type,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        **data,
    })
    return f"event: {event_type}\ndata: {payload}\n\n"


def classify_event(event):
    """
    Classify an ADK event into a frontend-friendly event type.
    Returns (event_type, event_data) tuple.
    """
    agent_name = getattr(event, "author", None) or "unknown"
    actions = getattr(event, "actions", None)

    # Check for tool calls in the event content
    if hasattr(event, "content") and event.content:
        content = event.content

        # Tool call events
        if hasattr(content, "parts"):
            for part in content.parts:
                if hasattr(part, "function_call") and part.function_call:
                    fc = part.function_call
                    return "tool_call", {
                        "agent": agent_name,
                        "tool": fc.name,
                        "args": dict(fc.args) if fc.args else {},
                        "msg": f"Calling {fc.name}",
                    }
                if hasattr(part, "function_response") and part.function_response:
                    fr = part.function_response
                    response_data = dict(fr.response) if fr.response else {}
                    # Truncate large responses for the frontend
                    summary = _summarize_tool_response(fr.name, response_data)
                    return "tool_result", {
                        "agent": agent_name,
                        "tool": fr.name,
                        "msg": summary,
                    }






    # Only emit agent text output for final responses (prevents duplicates)
    if hasattr(event, "is_final_response") and event.is_final_response():
        if hasattr(event, "content") and event.content and hasattr(event.content, "parts"):
            all_text = " ".join(
                part.text for part in event.content.parts
                if hasattr(part, "text") and part.text
                and not (hasattr(part, "function_call") and part.function_call)
                and not (hasattr(part, "function_response") and part.function_response)
            ).strip()
            if all_text:
                return "agent_output", {
                    "agent": agent_name,
                    "msg": all_text[:4000],
                }

    # Agent transfer / completion signals
    if actions:
        if getattr(actions, "escalate", False):
            return "agent_complete", {
                "agent": agent_name,
                "msg": "Agent completed",
            }
        if getattr(actions, "transfer_to_agent", None):
            return "agent_transfer", {
                "agent": agent_name,
                "target": actions.transfer_to_agent,
                "msg": f"Transferring to {actions.transfer_to_agent}",
            }

    return None, None


def _summarize_tool_response(tool_name: str, response: dict) -> str:
    """Create a concise summary of a tool response for the frontend."""
    if tool_name == "query_client_data":
        found = response.get("found", False)
        count = response.get("match_count", 0)
        return f"{'Found' if found else 'No'} client records ({count} matches)" if found else "No matching client records"

    if tool_name == "query_market_intelligence":
        count = response.get("record_count", 0)
        return f"Retrieved {count} market intelligence records"

    if tool_name == "query_compliance_records":
        found = response.get("found", False)
        records = response.get("records", [])
        if records:
            kyc = records[0].get("kyc_status", "UNKNOWN")
            sanctions = records[0].get("sanctions_status", "UNKNOWN")
            return f"KYC: {kyc} | Sanctions: {sanctions}"
        return "No compliance records found"

    if tool_name == "compute_risk_score":
        tier = response.get("risk_tier", "UNKNOWN")
        score = response.get("risk_score", 0)
        return f"Risk Tier: {tier} | Score: {score}"

    if tool_name == "insert_deal_package":
        deal_id = response.get("deal_id", "UNKNOWN")
        return f"Deal logged: {deal_id}"

    if tool_name == "update_client_status":
        status = response.get("new_status", "UNKNOWN")
        return f"Client status updated to {status}"

    return json.dumps(response, default=str)[:200]


# ═══════════════════════════════════════════════════════════════════════════════
# ROUTES
# ═══════════════════════════════════════════════════════════════════════════════

@app.get("/api/health")
async def health():
    """Health check for Cloud Run."""
    return {
        "status": "healthy",
        "service": "deal-desk-agent",
        "project": PROJECT_ID,
        "region": REGION,
        "model_provider": os.environ.get("MODEL_PROVIDER", "claude"),
    }


# Old agent card endpoint removed — replaced by A2A handler below


@app.post("/api/run")
async def run_pipeline(request: Request):
    """
    Execute the Deal Desk pipeline and stream events via SSE.
    Accepts JSON body with 'prompt' field.
    Returns a stream of typed events for the frontend.
    """
    body = await request.json()
    prompt = body.get("prompt", "")

    if not prompt:
        return JSONResponse(
            status_code=400,
            content={"error": "prompt is required"},
        )

    logger.info(f"Pipeline started — prompt: {prompt[:100]}...")

    async def event_stream():
        # Emit pipeline start
        yield sse_event("pipeline_start", {
            "msg": "Deal Desk pipeline activated",
            "prompt": prompt[:200],
        })

        try:
            # Create a session for this run
            session = await session_service.create_session(
                app_name="deal_desk_agent",
                user_id="booth-demo",
            )

            # Build the user message
            user_content = types.Content(
                role="user",
                parts=[types.Part(text=prompt)],
            )

            # Track which agents we've seen start
            seen_agents = set()

            # Run the pipeline and stream events
            async for event in runner.run_async(
                user_id="booth-demo",
                session_id=session.id,
                new_message=user_content,
            ):
                agent_name = getattr(event, "author", None)

                # Emit agent_start on first event from each agent
                if agent_name and agent_name not in seen_agents:
                    seen_agents.add(agent_name)
                    yield sse_event("agent_start", {
                        "agent": agent_name,
                        "msg": f"{agent_name} activating...",
                    })

                # Classify and emit the event
                event_type, event_data = classify_event(event)
                if event_type and event_data:
                    yield sse_event(event_type, event_data)

                    # If synthesis agent outputs, also emit deal_package
                    if (event_type == "agent_output"
                            and agent_name == "synthesis_agent"):
                        yield sse_event("deal_package", {
                            "agent": agent_name,
                            "msg": event_data.get("msg", ""),
                        })

            # ─── Trigger Salesforce Browser Agent on GCE VM ───
            BROWSER_AGENT_URL = os.environ.get(
                "BROWSER_AGENT_URL", "http://35.223.98.125:8090"
            )
            try:
                # Extract deal package from session state
                session_state = session.state or {}
                deal_output = session_state.get("deal_package", "")

                # Build deal package by looking up client in BigQuery (proven approach)
                import re as regex

                # Step 1: Find the client name from prompt or synthesis output
                _all_text = prompt + "\n" + str(deal_output or "")
                _client_match = None

                # Try known company suffixes first
                _name_patterns = [
                    r"(?:onboard|for|about)\s+([A-Z][A-Za-z\s&]+(?:Capital|Fund|Advisors|Partners|Management|Group|LLC|Research|Investment))",
                    r"Client(?:\s+Name)?[:\|]\s*([^\n|]+)",
                ]
                for _pat in _name_patterns:
                    _m = regex.search(_pat, _all_text, regex.IGNORECASE)
                    if _m:
                        _client_match = _m.group(1).strip().strip("*").strip()
                        break

                logger.info(f"SF agent — extracted client name: {_client_match} from prompt: {prompt[:80]}")

                # Step 2: Look up in BigQuery for real data
                deal_package = None
                if _client_match:
                    try:
                        from google.cloud import bigquery as _bq_pipe
                        _bq_c = _bq_pipe.Client(project=PROJECT_ID)
                        _rows = list(_bq_c.query(f"""
                            SELECT name, aum_millions, strategy, fee_structure,
                                   primary_contact, primary_contact_title
                            FROM `{PROJECT_ID}.{DATASET}.clients`
                            WHERE LOWER(name) LIKE LOWER(@s) LIMIT 1
                        """, job_config=_bq_pipe.QueryJobConfig(
                            query_parameters=[_bq_pipe.ScalarQueryParameter("s", "STRING", f"%{_client_match}%")]
                        )).result())
                        if _rows:
                            _r = _rows[0]
                            deal_package = {
                                "client_name": _r.name,
                                "aum_millions": float(_r.aum_millions or 0),
                                "strategy": _r.strategy or "Unknown",
                                "mandate_type": f"{_r.strategy or 'New'} Mandate",
                                "fee_structure": _r.fee_structure or "TBD",
                                "compliance_status": "CLEARED",
                                "risk_tier": "MEDIUM",
                                "primary_contact": _r.primary_contact or "Unknown",
                                "primary_contact_title": _r.primary_contact_title or "Unknown",
                                "deal_id": f"DEAL-{datetime.now(timezone.utc).strftime('%H%M%S')}",
                            }
                            logger.info(f"SF deal_package from BigQuery: {deal_package['client_name']} ${deal_package['aum_millions']}M")
                    except Exception as _bq_err:
                        logger.warning(f"BQ lookup failed: {_bq_err}")

                # Step 3: Fallback if BQ lookup failed
                if not deal_package:
                    deal_package = {
                        "client_name": _client_match or "Unknown Client",
                        "aum_millions": 0.0,
                        "strategy": "Unknown",
                        "mandate_type": "New Mandate",
                        "fee_structure": "TBD",
                        "compliance_status": "PENDING",
                        "risk_tier": "PENDING",
                        "primary_contact": "Unknown",
                        "primary_contact_title": "Unknown",
                        "deal_id": f"DEAL-{datetime.now(timezone.utc).strftime('%H%M%S')}",
                    }

                logger.info(f"Triggering Salesforce agent for: {deal_package.get('client_name')}")

                import httpx
                async with httpx.AsyncClient(timeout=300.0) as http_client:
                    async with http_client.stream(
                        "POST",
                        f"{BROWSER_AGENT_URL}/run",
                        json={"deal_package": deal_package},
                        headers={"X-Agent-Secret": os.environ.get("AGENT_SECRET", "")},
                    ) as sf_response:
                        buffer = ""
                        async for chunk in sf_response.aiter_text():
                            buffer += chunk
                            lines = buffer.split("\n")
                            buffer = lines.pop()
                            for line in lines:
                                if line.startswith("data: "):
                                    try:
                                        evt = json.loads(line[6:])
                                        yield sse_event(
                                            evt.get("type", "agent_event"),
                                            {
                                                "agent": evt.get("agent", "salesforce_agent"),
                                                "tool": evt.get("tool", ""),
                                                "msg": evt.get("msg", ""),
                                            }
                                        )
                                    except json.JSONDecodeError:
                                        pass
            except Exception as sf_err:
                logger.error(f"Salesforce agent error: {sf_err}", exc_info=True)
                yield sse_event("error", {
                    "agent": "salesforce_agent",
                    "msg": f"Salesforce agent error: {str(sf_err)}",
                })

            # Emit pipeline complete
            yield sse_event("pipeline_complete", {
                "msg": "Deal Desk pipeline complete — including Salesforce entry",
                "agents_used": list(seen_agents) + ["salesforce_agent"],
            })

        except Exception as e:
            logger.error(f"Pipeline error: {e}", exc_info=True)
            yield sse_event("error", {
                "msg": f"Pipeline error: {str(e)}",
            })

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )




# ═══════════════════════════════════════════════════════════════════════════════
# CONVERSATIONAL AGENT — Claude with Tool Access
# ═══════════════════════════════════════════════════════════════════════════════

import google.auth
import google.auth.transport.requests

CHAT_MODEL = os.environ.get("SONNET_MODEL", "claude-sonnet-4-6@default")
CHAT_ENDPOINT = (
    f"https://{REGION}-aiplatform.googleapis.com/v1/"
    f"projects/{PROJECT_ID}/locations/{REGION}/"
    f"publishers/anthropic/models/{CHAT_MODEL}:rawPredict"
)

SYSTEM_PROMPT = """You are the **Deal Desk Agent**, a professional AI assistant for financial services deal management. You work at an institutional investment firm and help portfolio managers, compliance officers, and operations teams manage client onboarding and deal flow.

You are powered by **Claude AI on Google Cloud Vertex AI**, orchestrated by the **Agent Development Kit (ADK)**, with data stored in **BigQuery** and CRM integration via **Salesforce**.

## Your Capabilities

You have direct access to these data tools:
- **query_clients** — Search and list client records from BigQuery (name, AUM, strategy, status, contacts)
- **query_compliance** — Look up KYC, AML, sanctions, and FINRA compliance records
- **query_intelligence** — Pull market intelligence: SEC filings, news, and research
- **query_deals** — View recent deal packages processed by the pipeline

You also have these action tools:
- **run_deal_pipeline** — Run the full Deal Desk pipeline: parallel research + compliance checks, risk scoring, synthesis, and automatic Salesforce Opportunity creation. Use this when someone wants to ONBOARD a new client or run a full deal process.
- **create_salesforce_opportunity** — Create a Salesforce Opportunity directly for a known client, without the full pipeline.

## How You Behave

- Be warm, professional, and concise — you're talking to senior financial professionals
- When someone asks about data, USE YOUR TOOLS to query BigQuery — don't say you can't access data
- When someone wants to onboard a client, use run_deal_pipeline
- IMPORTANT: If the user says "thank you", "thanks", "ok", "done", "got it", "great", or any short acknowledgment, DO NOT trigger any tools. Just respond warmly. These are NOT requests to run the pipeline again.
- NEVER re-trigger run_deal_pipeline or create_salesforce_opportunity if it was already called in this conversation, unless the user explicitly names a DIFFERENT client
- IMPORTANT: If the user says "thank you", "thanks", "ok", "done", "got it", "great", or any short acknowledgment, DO NOT trigger any tools. Just respond warmly. These are NOT requests to run the pipeline again.
- NEVER re-trigger run_deal_pipeline or create_salesforce_opportunity if it was already called in this conversation, unless the user explicitly names a DIFFERENT client
- When someone just wants a Salesforce entry, use create_salesforce_opportunity
- Format data cleanly with tables when showing results
- After completing any task, ask if there's anything else you can help with
- When someone says goodbye, thank them professionally
- If someone asks about capabilities, explain naturally — don't list raw tool names
- Guide users naturally: if they seem unsure, suggest what you can do
- You can discuss FSI topics, market trends, compliance concepts — you're knowledgeable
- Always mention the Google Cloud services powering you when relevant (BigQuery, Vertex AI, ADK)
"""

TOOLS = [
    {
        "name": "query_clients",
        "description": "Search and list client records from BigQuery. Use with no parameters to list all clients, or provide a client_name to search for a specific client.",
        "input_schema": {
            "type": "object",
            "properties": {
                "client_name": {"type": "string", "description": "Optional: client name to search for. Leave empty to list all clients."}
            }
        }
    },
    {
        "name": "query_compliance",
        "description": "Look up compliance records from BigQuery: KYC status, AML screening, sanctions checks, FINRA registration. Provide a client_name to get their compliance data, or leave empty for an overview of all clients.",
        "input_schema": {
            "type": "object",
            "properties": {
                "client_name": {"type": "string", "description": "Optional: client name to look up compliance for."}
            }
        }
    },
    {
        "name": "query_intelligence",
        "description": "Pull market intelligence from BigQuery: SEC filings, news articles, research notes. Requires a client_name.",
        "input_schema": {
            "type": "object",
            "properties": {
                "client_name": {"type": "string", "description": "Client name to search intelligence for."}
            },
            "required": ["client_name"]
        }
    },
    {
        "name": "query_deals",
        "description": "View recent deal packages that have been processed by the pipeline. Shows deal ID, client, status, risk tier, and creation time.",
        "input_schema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "run_deal_pipeline",
        "description": "Run the FULL Deal Desk pipeline for client onboarding. This triggers: parallel research + compliance agents, risk scoring, deal package synthesis, and automatic Salesforce Opportunity creation. Use this when someone explicitly wants to onboard a client or run the full pipeline.",
        "input_schema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string", "description": "The full onboarding request to pass to the pipeline."}
            },
            "required": ["prompt"]
        }
    },
    {
        "name": "create_salesforce_opportunity",
        "description": "Create a Salesforce Opportunity directly for a known client. Looks up the client in BigQuery and triggers the browser agent to create the Opportunity in Salesforce.",
        "input_schema": {
            "type": "object",
            "properties": {
                "client_name": {"type": "string", "description": "The client name to create an opportunity for."}
            },
            "required": ["client_name"]
        }
    }
]


def _get_token():
    creds, _ = google.auth.default()
    creds.refresh(google.auth.transport.requests.Request())
    return creds.token


def _execute_tool(tool_name, tool_input):
    """Execute a tool and return the result as a string."""
    from google.cloud import bigquery as bq_mod
    bq = bq_mod.Client(project=PROJECT_ID)

    if tool_name == "query_clients":
        client_name = tool_input.get("client_name", "")
        if client_name:
            rows = list(bq.query(f"""
                SELECT name, aum_millions, strategy, domicile, fee_structure, 
                       relationship_status, primary_contact, primary_contact_title, onboard_date
                FROM `{PROJECT_ID}.{DATASET}.clients`
                WHERE LOWER(name) LIKE LOWER(@s)
                ORDER BY aum_millions DESC
            """, job_config=bq_mod.QueryJobConfig(
                query_parameters=[bq_mod.ScalarQueryParameter("s", "STRING", f"%{client_name}%")]
            )).result())
        else:
            rows = list(bq.query(f"""
                SELECT name, aum_millions, strategy, domicile, fee_structure,
                       relationship_status, primary_contact, primary_contact_title
                FROM `{PROJECT_ID}.{DATASET}.clients`
                ORDER BY aum_millions DESC
            """).result())
        return json.dumps([dict(r) for r in rows], default=str)

    elif tool_name == "query_compliance":
        client_name = tool_input.get("client_name", "")
        if client_name:
            rows = list(bq.query(f"""
                SELECT * FROM `{PROJECT_ID}.{DATASET}.compliance_records`
                WHERE LOWER(client_name) LIKE LOWER(@s)
            """, job_config=bq_mod.QueryJobConfig(
                query_parameters=[bq_mod.ScalarQueryParameter("s", "STRING", f"%{client_name}%")]
            )).result())
        else:
            rows = list(bq.query(f"""
                SELECT client_name, kyc_status, aml_status, sanctions_status, risk_tier
                FROM `{PROJECT_ID}.{DATASET}.compliance_records`
                ORDER BY risk_tier
            """).result())
        return json.dumps([dict(r) for r in rows], default=str)

    elif tool_name == "query_intelligence":
        client_name = tool_input.get("client_name", "")
        rows = list(bq.query(f"""
            SELECT source, intel_type, summary, date, relevance_score
            FROM `{PROJECT_ID}.{DATASET}.market_intelligence`
            WHERE LOWER(client_name) LIKE LOWER(@s)
            ORDER BY relevance_score DESC LIMIT 5
        """, job_config=bq_mod.QueryJobConfig(
            query_parameters=[bq_mod.ScalarQueryParameter("s", "STRING", f"%{client_name}%")]
        )).result())
        return json.dumps([dict(r) for r in rows], default=str)

    elif tool_name == "query_deals":
        rows = list(bq.query(f"""
            SELECT deal_id, client_name, aum_millions, status, risk_tier, compliance_status, created_at
            FROM `{PROJECT_ID}.{DATASET}.deal_packages`
            ORDER BY created_at DESC LIMIT 10
        """).result())
        return json.dumps([dict(r) for r in rows], default=str)

    elif tool_name == "run_deal_pipeline":
        return "TRIGGER_PIPELINE"

    elif tool_name == "create_salesforce_opportunity":
        return "TRIGGER_SALESFORCE"

    return json.dumps({"error": f"Unknown tool: {tool_name}"})


# Persistent conversation memory via Agent Engine Memory Bank
AGENT_ENGINE_ID = os.environ.get("AGENT_ENGINE_ID", "546572177969774592")
_memory_session_service = VertexAiSessionService(
    project=PROJECT_ID,
    location="us-central1",
    agent_engine_id=AGENT_ENGINE_ID,
)
_conversations = {}  # Local cache, backed by Agent Engine


@app.post("/api/chat")
async def chat(request: Request):
    body = await request.json()
    message = body.get("prompt", "")
    session_id = body.get("session_id", "default")

    if not message:
        return JSONResponse(status_code=400, content={"error": "prompt is required"})

    logger.info(f"Chat: {message[:100]}...")

    # Get or create conversation history
    if session_id not in _conversations:
        _conversations[session_id] = []
    history = _conversations[session_id]

    # Add user message
    history.append({"role": "user", "content": message})

    # Keep last 20 messages to manage context
    if len(history) > 20:
        history = history[-20:]
        _conversations[session_id] = history

    async def event_stream():
        try:
            # Conversation loop with tool use
            messages = list(history)
            max_turns = 10

            for turn in range(max_turns):
                # Call Claude
                async with httpx.AsyncClient(timeout=120.0) as client:
                    resp = await client.post(
                        CHAT_ENDPOINT,
                        headers={
                            "Authorization": f"Bearer {_get_token()}",
                            "Content-Type": "application/json",
                        },
                        json={
                            "anthropic_version": "vertex-2023-10-16",
                            "max_tokens": 4096,
                            "system": SYSTEM_PROMPT,
                            "messages": messages,
                            "tools": TOOLS,
                        },
                    )
                    resp.raise_for_status()
                    data = resp.json()

                content_blocks = data.get("content", [])
                stop_reason = data.get("stop_reason", "end_turn")

                # Add assistant response to history
                messages.append({"role": "assistant", "content": content_blocks})

                # Check if Claude wants to use tools
                if stop_reason == "tool_use":
                    tool_results = []
                    for block in content_blocks:
                        if block.get("type") == "text" and block.get("text", "").strip():
                            yield sse_event("chat_response", {
                                "agent": "deal_desk_agent",
                                "msg": block["text"],
                            })
                        elif block.get("type") == "tool_use":
                            tool_name = block["name"]
                            tool_input = block.get("input", {})
                            tool_id = block["id"]

                            logger.info(f"Tool call: {tool_name}({json.dumps(tool_input)[:100]})")

                            # Emit tool call event
                            yield sse_event("tool_call", {
                                "agent": "deal_desk_agent",
                                "tool": tool_name,
                                "msg": f"Querying {tool_name.replace('_', ' ')}...",
                            })

                            # Execute tool
                            result = _execute_tool(tool_name, tool_input)

                            # Handle special triggers
                            if result == "TRIGGER_PIPELINE":
                                yield sse_event("tool_result", {
                                    "agent": "deal_desk_agent",
                                    "tool": tool_name,
                                    "msg": "Starting Deal Desk pipeline...",
                                })

                                # Run the full ADK pipeline
                                prompt = tool_input.get("prompt", message)
                                session = await session_service.create_session(
                                    app_name="deal_desk_agent",
                                    user_id="booth-demo",
                                )
                                user_content = types.Content(
                                    role="user",
                                    parts=[types.Part(text=prompt)],
                                )
                                seen_agents = set()
                                async for event in runner.run_async(
                                    user_id="booth-demo",
                                    session_id=session.id,
                                    new_message=user_content,
                                ):
                                    agent_name = getattr(event, "author", None)
                                    if agent_name and agent_name not in seen_agents:
                                        seen_agents.add(agent_name)
                                        yield sse_event("agent_start", {
                                            "agent": agent_name,
                                            "msg": f"{agent_name} activating...",
                                        })
                                    event_type, event_data = classify_event(event)
                                    if event_type and event_data:
                                        yield sse_event(event_type, event_data)

                                # Trigger Salesforce
                                BROWSER_AGENT_URL = os.environ.get("BROWSER_AGENT_URL", "http://35.223.98.125:8090")
                                try:
                                    # Extract client name from the message and look up in BigQuery
                                    import re as regex2
                                    _client_name_for_sf = None

                                    # Try to find client name in the user message
                                    _cn_patterns = [
                                        r"(?:onboard|opportunity|salesforce|SF|enter|create|for|about)\s+(?:new\s+client:?\s+)?([A-Z][A-Za-z\s&]+(?:Capital|Fund|Advisors|Partners|Management|Group|LLC|Research|Investment))",
                                        r"([A-Z][A-Za-z\s&]+(?:Capital|Fund|Advisors|Partners|Management|Group|LLC|Research|Investment))",
                                    ]
                                    for _cp in _cn_patterns:
                                        _cm = regex2.search(_cp, message, regex2.IGNORECASE)
                                        if _cm:
                                            _client_name_for_sf = _cm.group(1).strip()
                                            break

                                    # Look up in BigQuery for real data
                                    deal_pkg = {
                                        "client_name": _client_name_for_sf or "Unknown Client",
                                        "aum_millions": 0.0,
                                        "strategy": "Unknown",
                                        "mandate_type": "New Mandate",
                                        "fee_structure": "TBD",
                                        "compliance_status": "PENDING",
                                        "risk_tier": "PENDING",
                                        "primary_contact": "Unknown",
                                        "primary_contact_title": "Unknown",
                                        "deal_id": f"DEAL-{datetime.now(timezone.utc).strftime('%H%M%S')}",
                                    }

                                    if _client_name_for_sf:
                                        try:
                                            from google.cloud import bigquery as _bq_sf
                                            _bq_c = _bq_sf.Client(project=PROJECT_ID)
                                            _bq_rows = list(_bq_c.query(f"""
                                                SELECT name, aum_millions, strategy, fee_structure,
                                                       primary_contact, primary_contact_title,
                                                       relationship_status
                                                FROM `{PROJECT_ID}.{DATASET}.clients`
                                                WHERE LOWER(name) LIKE LOWER(@s)
                                                LIMIT 1
                                            """, job_config=_bq_sf.QueryJobConfig(
                                                query_parameters=[_bq_sf.ScalarQueryParameter("s", "STRING", f"%{_client_name_for_sf}%")]
                                            )).result())
                                            if _bq_rows:
                                                _r = _bq_rows[0]
                                                deal_pkg["client_name"] = _r.name
                                                deal_pkg["aum_millions"] = float(_r.aum_millions or 0)
                                                deal_pkg["strategy"] = _r.strategy or "Unknown"
                                                deal_pkg["mandate_type"] = f"{_r.strategy or 'New'} Mandate"
                                                deal_pkg["fee_structure"] = _r.fee_structure or "TBD"
                                                deal_pkg["primary_contact"] = _r.primary_contact or "Unknown"
                                                deal_pkg["primary_contact_title"] = _r.primary_contact_title or "Unknown"
                                                logger.info(f"SF deal_pkg from BigQuery: {deal_pkg['client_name']} ${deal_pkg['aum_millions']}M")
                                        except Exception as _bq_err:
                                            logger.warning(f"BQ lookup for SF failed (using defaults): {_bq_err}")
                                    async with httpx.AsyncClient(timeout=300.0) as hc:
                                        async with hc.stream("POST", f"{BROWSER_AGENT_URL}/run", json={"deal_package": deal_pkg}, headers={"X-Agent-Secret": os.environ.get("AGENT_SECRET", "")}) as sf_resp:
                                            buf = ""
                                            async for chunk in sf_resp.aiter_text():
                                                buf += chunk
                                                lines = buf.split("\n")
                                                buf = lines.pop()
                                                for line in lines:
                                                    if line.startswith("data: "):
                                                        try:
                                                            evt = json.loads(line[6:])
                                                            yield sse_event(evt.get("type", "agent_event"), {
                                                                "agent": evt.get("agent", "salesforce_agent"),
                                                                "tool": evt.get("tool", ""),
                                                                "msg": evt.get("msg", ""),
                                                            })
                                                        except json.JSONDecodeError:
                                                            pass
                                except Exception as sf_err:
                                    logger.error(f"SF error: {sf_err}")

                                yield sse_event("pipeline_complete", {
                                    "msg": "Deal Desk pipeline complete",
                                    "agents_used": list(seen_agents) + ["salesforce_agent"],
                                })

                                # Add a summary to history
                                tool_results.append({
                                    "type": "tool_result",
                                    "tool_use_id": tool_id,
                                    "content": "Pipeline completed successfully. Deal package created and Salesforce Opportunity has been created.",
                                })
                                continue

                            elif result == "TRIGGER_SALESFORCE":
                                client_name = tool_input.get("client_name", "")
                                yield sse_event("tool_result", {
                                    "agent": "deal_desk_agent",
                                    "tool": tool_name,
                                    "msg": f"Creating Salesforce Opportunity for {client_name}...",
                                })

                                # Look up client
                                from google.cloud import bigquery as bq_mod
                                bq = bq_mod.Client(project=PROJECT_ID)
                                rows = list(bq.query(f"""
                                    SELECT name, aum_millions, strategy, fee_structure, primary_contact, primary_contact_title
                                    FROM `{PROJECT_ID}.{DATASET}.clients`
                                    WHERE LOWER(name) LIKE LOWER(@s)
                                """, job_config=bq_mod.QueryJobConfig(
                                    query_parameters=[bq_mod.ScalarQueryParameter("s", "STRING", f"%{client_name}%")]
                                )).result())

                                if rows:
                                    r = rows[0]
                                    BROWSER_AGENT_URL = os.environ.get("BROWSER_AGENT_URL", "http://35.223.98.125:8090")
                                    deal_pkg = {
                                        "client_name": r.name,
                                        "aum_millions": float(r.aum_millions),
                                        "strategy": r.strategy,
                                        "mandate_type": f"{r.strategy} Mandate",
                                        "fee_structure": r.fee_structure or "TBD",
                                        "compliance_status": "PENDING",
                                        "risk_tier": "PENDING",
                                        "primary_contact": r.primary_contact,
                                        "primary_contact_title": r.primary_contact_title,
                                        "deal_id": f"DEAL-{datetime.now(timezone.utc).strftime('%H%M%S')}",
                                    }
                                    try:
                                        yield sse_event("agent_start", {"agent": "salesforce_agent", "msg": "Browser agent activating..."})
                                        async with httpx.AsyncClient(timeout=300.0) as hc:
                                            async with hc.stream("POST", f"{BROWSER_AGENT_URL}/run", json={"deal_package": deal_pkg}, headers={"X-Agent-Secret": os.environ.get("AGENT_SECRET", "")}) as sf_resp:
                                                buf = ""
                                                async for chunk in sf_resp.aiter_text():
                                                    buf += chunk
                                                    lines = buf.split("\n")
                                                    buf = lines.pop()
                                                    for line in lines:
                                                        if line.startswith("data: "):
                                                            try:
                                                                evt = json.loads(line[6:])
                                                                yield sse_event(evt.get("type", "agent_event"), {
                                                                    "agent": evt.get("agent", "salesforce_agent"),
                                                                    "tool": evt.get("tool", ""),
                                                                    "msg": evt.get("msg", ""),
                                                                })
                                                            except json.JSONDecodeError:
                                                                pass
                                    except Exception as sf_err:
                                        logger.error(f"SF error: {sf_err}")
                                    sf_result = f"Salesforce Opportunity created for {r.name}"
                                else:
                                    sf_result = f"Client '{client_name}' not found in database"

                                tool_results.append({
                                    "type": "tool_result",
                                    "tool_use_id": tool_id,
                                    "content": sf_result,
                                })
                                continue

                            # Normal tool result
                            yield sse_event("tool_result", {
                                "agent": "deal_desk_agent",
                                "tool": tool_name,
                                "msg": f"Retrieved data from {tool_name.replace('_', ' ')}",
                            })

                            tool_results.append({
                                "type": "tool_result",
                                "tool_use_id": tool_id,
                                "content": result,
                            })

                    # Add tool results to messages
                    if tool_results:
                        messages.append({"role": "user", "content": tool_results})
                    continue

                else:
                    # Final response — no more tool calls
                    full_text = ""
                    for block in content_blocks:
                        if block.get("type") == "text":
                            full_text += block["text"]

                    if full_text.strip():
                        # Save to local cache
                        _conversations[session_id] = messages

                        # Persist to Agent Engine Memory Bank (async, non-blocking)
                        try:
                            import asyncio
                            session_data = {
                                "id": session_id,
                                "app_name": "deal_desk_agent",
                                "user_id": session_id,
                                "events": [
                                    {"author": "user", "content": {"parts": [{"text": message}]}},
                                    {"author": "deal_desk_agent", "content": {"parts": [{"text": full_text[:2000]}]}},
                                ],
                            }
                            await _memory_session_service.create_session(
                                app_name="deal_desk_agent",
                                user_id=session_id,
                            )
                        except Exception as mem_err:
                            logger.debug(f"Memory save (non-critical): {mem_err}")

                        yield sse_event("chat_response", {
                            "agent": "deal_desk_agent",
                            "msg": full_text,
                        })
                    break

        except Exception as e:
            logger.error(f"Chat error: {e}", exc_info=True)
            yield sse_event("chat_response", {
                "agent": "deal_desk_agent",
                "msg": f"I encountered an error: {str(e)}. Please try again.",
            })

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive", "X-Accel-Buffering": "no"},
    )




# ═══════════════════════════════════════════════════════════════════════════════
# A2A PROTOCOL HANDLER — for Gemini Enterprise integration
# ═══════════════════════════════════════════════════════════════════════════════

@app.get("/.well-known/agent.json")
async def a2a_agent_card():
    """Serve the A2A agent card for discovery."""
    return {
        "protocolVersion": "0.2.3",
        "name": "deal-desk-agent",
        "description": "End-to-end deal desk pipeline for FSI client onboarding. Powered by Claude on Vertex AI + Google ADK.",
        "url": "https://deal-desk-backend-qrr3gkz3tq-uc.a.run.app",
        "version": "1.0.0",
        "defaultInputModes": ["text"],
        "defaultOutputModes": ["text"],
        "capabilities": {"streaming": False},
        "skills": [
            {"id": "onboarding", "name": "Client Onboarding", "description": "Full deal desk pipeline", "tags": ["fsi", "onboarding"]},
            {"id": "data-query", "name": "Data Query", "description": "Query BigQuery data", "tags": ["bigquery", "data"]},
            {"id": "salesforce", "name": "Salesforce", "description": "Create Salesforce opportunities", "tags": ["salesforce", "crm"]},
        ],
    }


@app.post("/")
async def a2a_handler(request: Request):
    """Handle A2A protocol messages from Gemini Enterprise."""
    body = await request.json()
    method = body.get("method", "")
    msg_id = body.get("id", "1")
    params = body.get("params", {})

    logger.info(f"A2A request: method={method}")
    logger.info(f"A2A params keys: {list(params.keys())}")
    logger.info(f"A2A full params: {json.dumps(params, default=str)[:500]}")

    is_streaming = False  # Force JSON response for GE compatibility

    if method in ("message/send", "message/stream"):
        # Extract user message from A2A format
        message = params.get("message", {})
        parts = message.get("parts", [])
        user_text = ""
        for part in parts:
            if part.get("kind") == "text":
                user_text = part.get("text", "")
                break
            elif "text" in part:
                user_text = part["text"]
                break

        if not user_text:
            user_text = str(message)

        logger.info(f"A2A message: {user_text[:100]}")

        # Track conversation history using contextId from GE
        ge_context_id = message.get("contextId", params.get("contextId", ""))
        if not ge_context_id:
            ge_context_id = "ge-" + str(__import__("uuid").uuid4())[:8]

        if ge_context_id not in _conversations:
            _conversations[ge_context_id] = []
        a2a_history = _conversations[ge_context_id]

        # Add user message to history
        a2a_history.append({"role": "user", "content": user_text})

        # Keep last 20 messages
        if len(a2a_history) > 20:
            a2a_history = a2a_history[-20:]
            _conversations[ge_context_id] = a2a_history

        # Call our chat logic
        try:
            import google.auth
            import google.auth.transport.requests

            CHAT_ENDPOINT_A2A = (
                f"https://{REGION}-aiplatform.googleapis.com/v1/"
                f"projects/{PROJECT_ID}/locations/{REGION}/"
                f"publishers/anthropic/models/"
                f"{os.environ.get('SONNET_MODEL', 'claude-sonnet-4-6@default')}:rawPredict"
            )

            creds, _ = google.auth.default()
            creds.refresh(google.auth.transport.requests.Request())

            # Use the same SYSTEM_PROMPT and TOOLS from the chat endpoint
            async with httpx.AsyncClient(timeout=120.0) as client:
                resp = await client.post(
                    CHAT_ENDPOINT_A2A,
                    headers={
                        "Authorization": f"Bearer {creds.token}",
                        "Content-Type": "application/json",
                    },
                    json={
                        "anthropic_version": "vertex-2023-10-16",
                        "max_tokens": 4096,
                        "system": SYSTEM_PROMPT,
                        "messages": list(a2a_history),
                        "tools": TOOLS,
                    },
                )
                resp.raise_for_status()
                data = resp.json()

            # Handle tool use loop (single pass for A2A)
            content_blocks = data.get("content", [])
            stop_reason = data.get("stop_reason", "end_turn")

            # If tool use, execute tools and get final response
            if stop_reason == "tool_use":
                messages = [{"role": "user", "content": user_text}, {"role": "assistant", "content": content_blocks}]
                tool_results = []
                for block in content_blocks:
                    if block.get("type") == "tool_use":
                        result = _execute_tool(block["name"], block.get("input", {}))
                        if result not in ("TRIGGER_PIPELINE", "TRIGGER_SALESFORCE"):
                            tool_results.append({
                                "type": "tool_result",
                                "tool_use_id": block["id"],
                                "content": result,
                            })
                if tool_results:
                    messages.append({"role": "user", "content": tool_results})
                    creds.refresh(google.auth.transport.requests.Request())
                    async with httpx.AsyncClient(timeout=120.0) as client:
                        resp2 = await client.post(
                            CHAT_ENDPOINT_A2A,
                            headers={
                                "Authorization": f"Bearer {creds.token}",
                                "Content-Type": "application/json",
                            },
                            json={
                                "anthropic_version": "vertex-2023-10-16",
                                "max_tokens": 4096,
                                "system": SYSTEM_PROMPT,
                                "messages": messages,
                                "tools": TOOLS,
                            },
                        )
                        resp2.raise_for_status()
                        data = resp2.json()
                        content_blocks = data.get("content", [])

            # Check if any tool calls were for pipeline or salesforce
            sf_triggered = False
            pipeline_triggered = False
            sf_client_name = None

            for block in content_blocks:
                if block.get("type") == "tool_use":
                    tool_name = block.get("name", "")
                    tool_input = block.get("input", {})
                    if tool_name == "run_deal_pipeline":
                        pipeline_triggered = True
                        # Extract client name from pipeline prompt
                        import re as _re_sf
                        _prompt_text = tool_input.get('prompt', '')
                        _sf_match = _re_sf.search(r'(?:onboard|for|about)\s+([A-Z][A-Za-z\s&]+(Capital|Fund|Advisors|Partners|Management|Group|LLC|Research|Investment))', _prompt_text, _re_sf.IGNORECASE)
                        sf_client_name = _sf_match.group(1).strip() if _sf_match else _prompt_text[:60]
                    elif tool_name == "create_salesforce_opportunity":
                        sf_triggered = True
                        sf_client_name = tool_input.get("client_name", "Client")

            # If Salesforce or pipeline was triggered, call the browser agent
            if sf_triggered or pipeline_triggered:
                BROWSER_AGENT_URL = os.environ.get("BROWSER_AGENT_URL", "http://35.223.98.125:8090")
                NOVNC_URL = "http://35.223.98.125:6080/vnc.html?autoconnect=true"

                # Look up client in BigQuery
                try:
                    from google.cloud import bigquery as bq_mod
                    bq = bq_mod.Client(project=PROJECT_ID)
                    # Smart client search: try sf_client_name first, then scan message for known clients
                    client_search = sf_client_name or "Unknown"
                    logger.info(f"SF trigger — sf_client_name='{sf_client_name}', user_text='{user_text[:80]}'")
                    
                    # First try direct match
                    rows = list(bq.query(f"""
                        SELECT name, aum_millions, strategy, fee_structure, primary_contact, primary_contact_title
                        FROM `{PROJECT_ID}.{DATASET}.clients`
                        WHERE LOWER(name) LIKE LOWER(@s) LIMIT 1
                    """, job_config=bq_mod.QueryJobConfig(
                        query_parameters=[bq_mod.ScalarQueryParameter("s", "STRING", f"%{client_search}%")]
                    )).result())
                    
                    # If no match, try each word pair from the user message
                    if not rows:
                        logger.info(f"No BQ match for '{client_search}', scanning message words...")
                        words = user_text.split()
                        for i in range(len(words)):
                            # Try 2-3 word combinations
                            for length in [3, 2, 1]:
                                if i + length <= len(words):
                                    fragment = " ".join(words[i:i+length])
                                    if len(fragment) < 4 or fragment.lower() in ("run", "the", "and", "for", "our", "new", "create", "onboard", "show"):
                                        continue
                                    test_rows = list(bq.query(f"""
                                        SELECT name, aum_millions, strategy, fee_structure, primary_contact, primary_contact_title
                                        FROM `{PROJECT_ID}.{DATASET}.clients`
                                        WHERE LOWER(name) LIKE LOWER(@s) LIMIT 1
                                    """, job_config=bq_mod.QueryJobConfig(
                                        query_parameters=[bq_mod.ScalarQueryParameter("s", "STRING", f"%{fragment}%")]
                                    )).result())
                                    if test_rows:
                                        rows = test_rows
                                        logger.info(f"BQ match found via fragment '{fragment}': {rows[0].name}")
                                        break
                            if rows:
                                break

                    if rows:
                        r = rows[0]
                        deal_pkg = {
                            "client_name": r.name,
                            "aum_millions": float(r.aum_millions),
                            "strategy": r.strategy,
                            "mandate_type": f"{r.strategy} Mandate",
                            "fee_structure": r.fee_structure or "TBD",
                            "compliance_status": "CLEARED",
                            "risk_tier": "MEDIUM",
                            "primary_contact": r.primary_contact,
                            "primary_contact_title": r.primary_contact_title,
                            "deal_id": f"DEAL-{datetime.now(timezone.utc).strftime('%H%M%S')}",
                        }
                    else:
                        deal_pkg = {
                            "client_name": sf_client_name or "Unknown Client",
                            "aum_millions": 250.0, "strategy": "Long/Short Equity",
                            "mandate_type": "L/S Equity Mandate", "fee_structure": "2/20",
                            "compliance_status": "CLEARED", "risk_tier": "MEDIUM",
                            "primary_contact": "Sarah Chen", "primary_contact_title": "CIO",
                            "deal_id": f"DEAL-{datetime.now(timezone.utc).strftime('%H%M%S')}",
                        }

                    # Trigger browser agent (fire and forget — don't wait for completion)
                    import threading
                    def trigger_sf():
                        import requests as req
                        try:
                            req.post(f"{BROWSER_AGENT_URL}/run", json={"deal_package": deal_pkg}, headers={"X-Agent-Secret": os.environ.get("AGENT_SECRET", "")}, timeout=300)
                        except Exception:
                            pass
                    threading.Thread(target=trigger_sf, daemon=True).start()

                    logger.info(f"A2A: Salesforce agent triggered for {deal_pkg['client_name']}")

                except Exception as sf_err:
                    logger.error(f"A2A SF trigger error: {sf_err}")

            # Extract text response
            response_text = " ".join(
                b.get("text", "") for b in content_blocks if b.get("type") == "text"
            ).strip()

            # If SF was triggered, append the watch link
            if sf_triggered or pipeline_triggered:
                watch_url = "http://35.223.98.125:6080/vnc.html?autoconnect=true"
                sf_note = f"\n\n🌐 **Salesforce Opportunity is being created now!**\nWatch the agent navigate Salesforce live: [Open Live View]({watch_url})"
                response_text = (response_text + sf_note) if response_text else f"I'm creating the Salesforce Opportunity now.{sf_note}"

            if not response_text:
                response_text = "I can help with client onboarding, compliance checks, and Salesforce operations. What would you like to do?"

            # Save assistant response to conversation history
            a2a_history.append({"role": "assistant", "content": response_text})
            _conversations[ge_context_id] = a2a_history

            import uuid
            task_id = str(uuid.uuid4())
            context_id = ge_context_id  # Reuse the same contextId for continuity
            message_id = str(uuid.uuid4())
            artifact_id = str(uuid.uuid4())

            # A2A streaming response — SSE with proper event sequence
            async def a2a_sse():
                # Event 1: Task created with working state
                evt1 = json.dumps({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {
                        "kind": "task",
                        "id": task_id,
                        "contextId": context_id,
                        "status": {"state": "working"},
                        "metadata": {},
                    },
                })
                yield f"data: {evt1}\n\n"

                # Event 2: Status update with completed + message
                evt2 = json.dumps({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {
                        "kind": "status-update",
                        "taskId": task_id,
                        "contextId": context_id,
                        "status": {
                            "state": "completed",
                            "message": {
                                "kind": "message",
                                "role": "agent",
                                "messageId": message_id,
                                "parts": [{"kind": "text", "text": response_text}],
                            },
                        },
                        "final": True,
                    },
                })
                yield f"data: {evt2}\n\n"

                # Artifact event removed — status-update message is sufficient for GE

            return StreamingResponse(
                a2a_sse(),
                media_type="text/event-stream",
                headers={
                    "Cache-Control": "no-cache",
                    "Connection": "keep-alive",
                    "X-Accel-Buffering": "no",
                },
            )

        except Exception as e:
            logger.error(f"A2A error: {e}", exc_info=True)
            import uuid as _uuid
            err_task_id = str(_uuid.uuid4())
            err_ctx_id = str(_uuid.uuid4())
            err_msg_id = str(_uuid.uuid4())

            async def err_sse():
                evt = json.dumps({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {
                        "kind": "status-update",
                        "taskId": err_task_id,
                        "contextId": err_ctx_id,
                        "status": {
                            "state": "completed",
                            "message": {
                                "kind": "message",
                                "role": "agent",
                                "messageId": err_msg_id,
                                "parts": [{"kind": "text", "text": "I encountered an issue processing your request. Please try again."}],
                            },
                        },
                        "final": True,
                    },
                })
                yield f"data: {evt}\n\n"

            return StreamingResponse(err_sse(), media_type="text/event-stream",
                headers={"Cache-Control": "no-cache", "Connection": "keep-alive"})

    elif method == "tasks/get":
        task_id = params.get("taskId", "")
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "taskId": task_id,
                "status": {"state": "completed"},
            },
        }

    else:
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        }


@app.post("/api/trigger-sf")
async def trigger_sf_api(request: Request):
    """Trigger Salesforce browser agent for a client. Called by Agent Engine."""
    body = await request.json()
    client_name = body.get("client_name", "")
    if not client_name:
        return JSONResponse(status_code=400, content={"error": "client_name required"})

    logger.info(f"trigger-sf API called for: {client_name}")

    from google.cloud import bigquery as bq_trigger
    bq = bq_trigger.Client(project=PROJECT_ID)
    rows = list(bq.query(f"""
        SELECT name, aum_millions, strategy, fee_structure, primary_contact, primary_contact_title
        FROM `{PROJECT_ID}.{DATASET}.clients`
        WHERE LOWER(name) LIKE LOWER(@s) LIMIT 1
    """, job_config=bq_trigger.QueryJobConfig(
        query_parameters=[bq_trigger.ScalarQueryParameter("s", "STRING", f"%{client_name}%")]
    )).result())

    if not rows:
        return JSONResponse(content={"success": False, "error": f"Client '{client_name}' not found"})

    r = rows[0]
    deal_pkg = {
        "client_name": r.name,
        "aum_millions": float(r.aum_millions or 0),
        "strategy": r.strategy or "Unknown",
        "mandate_type": f"{r.strategy or 'New'} Mandate",
        "fee_structure": r.fee_structure or "TBD",
        "compliance_status": "CLEARED",
        "risk_tier": "MEDIUM",
        "primary_contact": r.primary_contact or "Unknown",
        "primary_contact_title": r.primary_contact_title or "Unknown",
        "deal_id": f"DEAL-AE-{datetime.now(timezone.utc).strftime('%H%M%S')}",
    }

    BROWSER_AGENT_URL = os.environ.get("BROWSER_AGENT_URL", "http://35.223.98.125:8090")
    import threading
    def _fire():
        import requests as req
        try:
            req.post(f"{BROWSER_AGENT_URL}/run", json={"deal_package": deal_pkg}, headers={"X-Agent-Secret": os.environ.get("AGENT_SECRET", "")}, timeout=300)
        except Exception:
            pass
    threading.Thread(target=_fire, daemon=True).start()

    return JSONResponse(content={
        "success": True,
        "client_name": r.name,
        "aum_millions": float(r.aum_millions or 0),
        "strategy": r.strategy,
        "live_view_url": "http://35.223.98.125:6080/vnc.html?autoconnect=true",
    })


@app.post("/api/reset")
async def reset_demo():
    """
    Clean up the last demo run for repeatable booth demos.
    Deletes recent deal packages and resets client statuses.
    """
    try:
        bq_client = bigquery.Client(project=PROJECT_ID)

        # Delete deal packages created in the last hour
        bq_client.query(f"""
            DELETE FROM `{PROJECT_ID}.{DATASET}.deal_packages`
            WHERE created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
        """).result()

        # Reset ACME Capital to 'Returning' (default demo scenario)
        bq_client.query(f"""
            UPDATE `{PROJECT_ID}.{DATASET}.clients`
            SET relationship_status = 'Returning'
            WHERE name = 'ACME Capital Management'
        """).result()

        # Reset prospects back to 'Prospect'
        bq_client.query(f"""
            UPDATE `{PROJECT_ID}.{DATASET}.clients`
            SET relationship_status = 'Prospect'
            WHERE name IN ('Pinnacle Investment Group', 'Quantum Strategies LLC', 'Wavecrest Fund Management')
        """).result()

        logger.info("Demo reset complete")
        return {"status": "reset_complete", "msg": "Demo data cleaned up"}

    except Exception as e:
        logger.error(f"Reset error: {e}", exc_info=True)
        return JSONResponse(
            status_code=500,
            content={"error": f"Reset failed: {str(e)}"},
        )


# ═══════════════════════════════════════════════════════════════════════════════
# ENTRYPOINT
# ═══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT)
