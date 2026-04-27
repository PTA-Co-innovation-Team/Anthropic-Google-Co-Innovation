"""
Salesforce Browser Agent — Computer Use integration.
Drives a live Salesforce instance via Claude's computer use API on Vertex AI.
Runs inside a Docker container with a virtual desktop (Xvfb + Chrome + noVNC).

On Vertex AI, computer_20250124 tool type is NOT supported.
We use type: "custom" with a full input_schema instead.
No anthropic-beta headers are supported on Vertex rawPredict.
"""

import os
import json
import base64
import subprocess
import logging
import asyncio
from datetime import datetime
from typing import AsyncGenerator

import httpx
import google.auth
import google.auth.transport.requests

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════════════════════════════════════════

PROJECT_ID = os.environ.get("PROJECT_ID", "cpe-slarbi-nvd-ant-demos")
REGION = os.environ.get("REGION", "us-east5")
SONNET_MODEL = os.environ.get("SONNET_MODEL", "claude-sonnet-4-6@default")
SALESFORCE_URL = os.environ.get(
    "SALESFORCE_URL",
    "https://orgfarm-09257c3eee-dev-ed.develop.lightning.force.com"
)

# Computer use settings
DISPLAY_WIDTH = int(os.environ.get("DISPLAY_WIDTH", 1280))
DISPLAY_HEIGHT = int(os.environ.get("DISPLAY_HEIGHT", 800))
SCREENSHOT_PATH = "/tmp/screenshot.png"
MAX_ITERATIONS = int(os.environ.get("CU_MAX_ITERATIONS", 40))

# Vertex AI endpoint
VERTEX_ENDPOINT = (
    f"https://{REGION}-aiplatform.googleapis.com/v1/"
    f"projects/{PROJECT_ID}/locations/{REGION}/"
    f"publishers/anthropic/models/{SONNET_MODEL}:rawPredict"
)

logger = logging.getLogger("salesforce-browser-agent")
logging.basicConfig(level=logging.DEBUG)


# ═══════════════════════════════════════════════════════════════════════════════
# AUTH
# ═══════════════════════════════════════════════════════════════════════════════

def get_access_token() -> str:
    """Get a fresh GCP access token via ADC."""
    credentials, _ = google.auth.default()
    credentials.refresh(google.auth.transport.requests.Request())
    return credentials.token


# ═══════════════════════════════════════════════════════════════════════════════
# SCREENSHOT + ACTION EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

def take_screenshot() -> str:
    """Capture the virtual display and return base64-encoded PNG."""
    subprocess.run(
        ["scrot", "-o", SCREENSHOT_PATH],
        env={**os.environ, "DISPLAY": ":1"},
        check=True,
        capture_output=True,
    )
    with open(SCREENSHOT_PATH, "rb") as f:
        return base64.standard_b64encode(f.read()).decode("utf-8")


def execute_action(action: dict) -> dict:
    """
    Execute a computer use action on the virtual desktop.
    Supports: click, type, key, scroll, screenshot, move.
    Returns a result dict.
    """
    action_type = action.get("action")
    display_env = {**os.environ, "DISPLAY": ":1"}

    try:
        if action_type == "screenshot":
            return {"type": "screenshot", "status": "ok"}

        elif action_type == "click":
            x = action.get("coordinate", [0, 0])[0]
            y = action.get("coordinate", [0, 0])[1]
            button = action.get("button", "left")
            btn_flag = {"left": "1", "right": "3", "middle": "2"}.get(button, "1")
            subprocess.run(
                ["xdotool", "mousemove", str(x), str(y), "click", btn_flag],
                env=display_env, check=True, capture_output=True,
            )
            return {"type": "click", "x": x, "y": y, "button": button, "status": "ok"}

        elif action_type == "double_click":
            x = action.get("coordinate", [0, 0])[0]
            y = action.get("coordinate", [0, 0])[1]
            subprocess.run(
                ["xdotool", "mousemove", str(x), str(y),
                 "click", "--repeat", "2", "--delay", "100", "1"],
                env=display_env, check=True, capture_output=True,
            )
            return {"type": "double_click", "x": x, "y": y, "status": "ok"}

        elif action_type == "type":
            text = action.get("text", "")
            subprocess.run(
                ["xdotool", "type", "--clearmodifiers", "--delay", "25", text],
                env=display_env, check=True, capture_output=True,
            )
            return {"type": "type", "text": text[:50], "status": "ok"}

        elif action_type == "key":
            key = action.get("key", "")
            subprocess.run(
                ["xdotool", "key", key],
                env=display_env, check=True, capture_output=True,
            )
            return {"type": "key", "key": key, "status": "ok"}

        elif action_type == "scroll":
            x = action.get("coordinate", [640, 400])[0]
            y = action.get("coordinate", [640, 400])[1]
            direction = action.get("direction", "down")
            amount = action.get("amount", 3)
            btn = "5" if direction == "down" else "4"
            subprocess.run(
                ["xdotool", "mousemove", str(x), str(y)],
                env=display_env, check=True, capture_output=True,
            )
            for _ in range(amount):
                subprocess.run(
                    ["xdotool", "click", btn],
                    env=display_env, check=True, capture_output=True,
                )
            return {"type": "scroll", "direction": direction, "amount": amount, "status": "ok"}

        elif action_type == "move":
            x = action.get("coordinate", [0, 0])[0]
            y = action.get("coordinate", [0, 0])[1]
            subprocess.run(
                ["xdotool", "mousemove", str(x), str(y)],
                env=display_env, check=True, capture_output=True,
            )
            return {"type": "move", "x": x, "y": y, "status": "ok"}

        elif action_type == "wait":
            duration = action.get("duration", 2)
            import time
            time.sleep(duration)
            return {"type": "wait", "duration": duration, "status": "ok"}

        else:
            return {"type": action_type, "status": "unsupported"}

    except subprocess.CalledProcessError as e:
        logger.error(f"Action execution failed: {action_type} — {e}")
        return {"type": action_type, "status": "error", "msg": str(e)}


# ═══════════════════════════════════════════════════════════════════════════════
# CUSTOM COMPUTER USE TOOL DEFINITION (Vertex AI compatible)
# ═══════════════════════════════════════════════════════════════════════════════

COMPUTER_TOOL = {
    "type": "custom",
    "name": "computer",
    "description": (
        f"Control a computer with a {DISPLAY_WIDTH}x{DISPLAY_HEIGHT} pixel screen. "
        "The screen is display :1. You can perform mouse and keyboard actions. "
        "After every action, a screenshot will be returned showing the result. "
        "Coordinates are absolute pixel positions from top-left (0,0) to "
        f"bottom-right ({DISPLAY_WIDTH},{DISPLAY_HEIGHT})."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": [
                    "click", "double_click", "type", "key",
                    "scroll", "screenshot", "move", "wait"
                ],
                "description": "The action to perform."
            },
            "coordinate": {
                "type": "array",
                "items": {"type": "integer"},
                "minItems": 2,
                "maxItems": 2,
                "description": "Pixel [x, y] coordinate for click, double_click, scroll, and move actions."
            },
            "text": {
                "type": "string",
                "description": "Text to type (for 'type' action)."
            },
            "key": {
                "type": "string",
                "description": "Key or combo to press (for 'key' action), e.g. 'Return', 'ctrl+a', 'Tab'."
            },
            "button": {
                "type": "string",
                "enum": ["left", "right", "middle"],
                "description": "Mouse button for click action. Default: left."
            },
            "direction": {
                "type": "string",
                "enum": ["up", "down"],
                "description": "Scroll direction."
            },
            "amount": {
                "type": "integer",
                "description": "Number of scroll clicks. Default: 3."
            },
            "duration": {
                "type": "integer",
                "description": "Seconds to wait (for 'wait' action). Default: 2."
            }
        },
        "required": ["action"]
    }
}


# ═══════════════════════════════════════════════════════════════════════════════
# VERTEX AI API CALL
# ═══════════════════════════════════════════════════════════════════════════════

async def call_claude_computer_use(
    messages: list,
    system_prompt: str,
) -> dict:
    """
    Call Claude Sonnet 4.6 on Vertex AI with custom computer use tool.

    Key Vertex AI constraints (discovered via /test-vertex diagnostic):
    - NO anthropic-beta headers supported on Vertex rawPredict
    - computer_20250124 tool type NOT supported on Vertex
    - Must use type: "custom" with full input_schema
    - Display dimensions go in tool description, not as tool fields
    """
    token = get_access_token()

    payload = {
        "anthropic_version": "vertex-2023-10-16",
        "max_tokens": 4096,
        "system": system_prompt,
        "messages": messages,
        "tools": [COMPUTER_TOOL],
    }

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    async with httpx.AsyncClient(timeout=120.0) as client:
        response = await client.post(
            VERTEX_ENDPOINT,
            headers=headers,
            json=payload,
        )

        if response.status_code != 200:
            logger.error(f"Vertex AI {response.status_code}: {response.text}")

        response.raise_for_status()
        return response.json()


# ═══════════════════════════════════════════════════════════════════════════════
# AGENT LOOP
# ═══════════════════════════════════════════════════════════════════════════════

def build_system_prompt(deal_package: dict) -> str:
    """Build the system prompt with deal package context for the browser agent."""
    return f"""You are a Salesforce operations agent controlling a browser on a {DISPLAY_WIDTH}x{DISPLAY_HEIGHT} pixel screen.
Your job is to create a new Opportunity in Salesforce Lightning using the deal package data provided below.

You have a "computer" tool that lets you interact with the screen. After each action, you'll receive a screenshot showing the result.

AVAILABLE ACTIONS:
- click: Click at [x, y] coordinate (left/right/middle button)
- double_click: Double-click at [x, y] coordinate
- type: Type text at current cursor position
- key: Press a key or combo (e.g., "Return", "Tab", "ctrl+a")
- scroll: Scroll up/down at [x, y] coordinate
- screenshot: Take a screenshot without performing an action
- move: Move cursor to [x, y] coordinate
- wait: Wait N seconds for page load

DEAL PACKAGE:
- Client Name: {deal_package.get('client_name', 'Unknown')}
- AUM: ${deal_package.get('aum_millions', 0)}M
- Strategy: {deal_package.get('strategy', 'Unknown')}
- Mandate Type: {deal_package.get('mandate_type', 'Unknown')}
- Fee Structure: {deal_package.get('fee_structure', 'Unknown')}
- Compliance Status: {deal_package.get('compliance_status', 'Unknown')}
- Risk Tier: {deal_package.get('risk_tier', 'Unknown')}
- Primary Contact: {deal_package.get('primary_contact', 'Unknown')}
- Primary Contact Title: {deal_package.get('primary_contact_title', 'Unknown')}
- Deal ID: {deal_package.get('deal_id', 'Unknown')}

SALESFORCE URL: {SALESFORCE_URL}

INSTRUCTIONS:
1. You should see the Salesforce Lightning interface in the browser.
2. Navigate to the Sales app if not already there.
3. Click "New" to create a new Opportunity.
4. Fill in these fields:
   - Opportunity Name: "{deal_package.get('client_name', 'Unknown')} — {deal_package.get('mandate_type', 'New Mandate')}"
   - Close Date: Set to 30 days from today
   - Stage: "Negotiation"
   - Amount: {deal_package.get('aum_millions', 0)}000000
5. Fill in any additional fields visible on the form.
6. Click Save.
7. After saving, take a screenshot to verify the Opportunity was created.
8. Report the Opportunity name and any ID visible on the page.

IMPORTANT:
- Work carefully and methodically.
- If a page is loading, wait a moment and take another screenshot.
- If you encounter an error, try an alternative approach.
- Do NOT navigate away from Salesforce.
- When you are done, include the text "TASK_COMPLETE" in your response."""


async def run_salesforce_agent(
    deal_package: dict,
) -> AsyncGenerator[dict, None]:
    """
    Run the Salesforce browser agent loop.
    Yields SSE-compatible event dicts as the agent progresses.
    """
    system_prompt = build_system_prompt(deal_package)
    messages = []
    iteration = 0

    yield {
        "type": "agent_start",
        "agent": "salesforce_agent",
        "msg": "Browser agent activating — connecting to Salesforce...",
    }

    # Take initial screenshot
    try:
        screenshot_b64 = take_screenshot()
    except Exception as e:
        yield {
            "type": "error",
            "agent": "salesforce_agent",
            "msg": f"Failed to capture initial screenshot: {e}",
        }
        return

    # Start conversation with initial screenshot
    messages.append({
        "role": "user",
        "content": [
            {
                "type": "text",
                "text": "Here is the current state of the screen. Please create the Salesforce Opportunity using the deal package data.",
            },
            {
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": "image/png",
                    "data": screenshot_b64,
                },
            },
        ],
    })

    yield {
        "type": "tool_call",
        "agent": "salesforce_agent",
        "tool": "screenshot",
        "msg": "Captured Salesforce dashboard",
    }

    while iteration < MAX_ITERATIONS:
        iteration += 1
        logger.info(f"Salesforce agent — iteration {iteration}")

        # Call Claude with current conversation
        try:
            response = await call_claude_computer_use(messages, system_prompt)
        except httpx.HTTPStatusError as e:
            yield {
                "type": "error",
                "agent": "salesforce_agent",
                "msg": f"Vertex AI {e.response.status_code}: {e.response.text[:500]}",
            }
            return
        except Exception as e:
            yield {
                "type": "error",
                "agent": "salesforce_agent",
                "msg": f"Vertex AI call failed: {e}",
            }
            return

        # Process response content blocks
        assistant_content = response.get("content", [])
        messages.append({"role": "assistant", "content": assistant_content})

        # Check for task completion or tool use
        has_tool_use = False
        task_complete = False
        tool_results = []

        for block in assistant_content:
            block_type = block.get("type")

            if block_type == "text":
                text = block.get("text", "")
                if "TASK_COMPLETE" in text:
                    task_complete = True
                    yield {
                        "type": "agent_output",
                        "agent": "salesforce_agent",
                        "msg": text[:500],
                    }

            elif block_type == "tool_use":
                has_tool_use = True
                tool_input = block.get("input", {})
                tool_id = block.get("id")
                action_type = tool_input.get("action", "unknown")

                # Emit event for the frontend
                action_desc = _describe_action(tool_input)
                yield {
                    "type": "tool_call",
                    "agent": "salesforce_agent",
                    "tool": "computer_use",
                    "msg": action_desc,
                }

                # Execute the action
                result = execute_action(tool_input)

                # Small delay for UI responsiveness
                await asyncio.sleep(0.5)

                # Take a new screenshot after the action
                try:
                    screenshot_b64 = take_screenshot()
                except Exception as e:
                    logger.error(f"Screenshot failed: {e}")
                    screenshot_b64 = None

                # Build tool result
                tool_result_content = []
                if screenshot_b64:
                    tool_result_content.append({
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": "image/png",
                            "data": screenshot_b64,
                        },
                    })

                if result.get("status") == "error":
                    tool_result_content.append({
                        "type": "text",
                        "text": f"Action failed: {result.get('msg', 'unknown error')}",
                    })

                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": tool_id,
                    "content": tool_result_content,
                })

                yield {
                    "type": "tool_result",
                    "agent": "salesforce_agent",
                    "tool": "computer_use",
                    "msg": f"Action executed: {action_type} — {result.get('status')}",
                }

        if task_complete:
            yield {
                "type": "agent_complete",
                "agent": "salesforce_agent",
                "msg": "Salesforce Opportunity created and verified",
            }
            return

        if has_tool_use and tool_results:
            messages.append({"role": "user", "content": tool_results})
        elif not has_tool_use:
            # Model responded with text only, no tool use — done
            yield {
                "type": "agent_complete",
                "agent": "salesforce_agent",
                "msg": "Salesforce agent finished",
            }
            return

    # Max iterations reached
    yield {
        "type": "agent_complete",
        "agent": "salesforce_agent",
        "msg": f"Max iterations ({MAX_ITERATIONS}) reached — review Salesforce manually",
    }


def _describe_action(tool_input: dict) -> str:
    """Create a human-readable description of a computer use action."""
    action = tool_input.get("action", "unknown")

    if action == "click":
        coords = tool_input.get("coordinate", [0, 0])
        return f"Click at ({coords[0]}, {coords[1]})"

    elif action == "double_click":
        coords = tool_input.get("coordinate", [0, 0])
        return f"Double-click at ({coords[0]}, {coords[1]})"

    elif action == "type":
        text = tool_input.get("text", "")
        display = text[:60] + "..." if len(text) > 60 else text
        return f'Type: "{display}"'

    elif action == "key":
        return f"Press key: {tool_input.get('key', '')}"

    elif action == "scroll":
        direction = tool_input.get("direction", "down")
        return f"Scroll {direction}"

    elif action == "screenshot":
        return "Capture screenshot"

    elif action == "move":
        coords = tool_input.get("coordinate", [0, 0])
        return f"Move cursor to ({coords[0]}, {coords[1]})"

    elif action == "wait":
        return f"Wait {tool_input.get('duration', 2)}s for page load"

    return f"Action: {action}"
