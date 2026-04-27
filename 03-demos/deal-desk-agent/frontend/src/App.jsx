import { useState, useEffect, useRef } from "react";
import Markdown from "./Markdown.jsx";

/* ═══════════════════════════════════════════════════════════════════════════════
   CONFIG
   ═══════════════════════════════════════════════════════════════════════════════ */

// Runtime config — injected by nginx entrypoint via /config.js (see Dockerfile).
// Falls back to localhost defaults so `npm run dev` still works against a local backend.
const API_BASE = window.__APP_CONFIG__?.API_BASE || "http://localhost:8080";
const NOVNC_URL = window.__APP_CONFIG__?.NOVNC_URL || "http://localhost:6080/vnc.html?autoconnect=true&resize=scale";

const PRESETS = [
  { label: "New Client Onboarding", prompt: "Onboard new client: ACME Capital Management. $250M AUM, long/short equity mandate, 2/20 fee structure, institutional investor. Primary contact: Sarah Chen, CIO. Run compliance checks and create the Salesforce opportunity." },
  { label: "Portfolio Rebalance", prompt: "Process portfolio rebalance for Meridian Partners. Shift allocation from 60/40 equity/bond to 70/30. $180M AUM, moderate risk tolerance. Update Salesforce with new mandate details." },
  { label: "Compliance Review", prompt: "Run full compliance review for Beacon Hedge Fund. $500M AUM, global macro strategy, Cayman domiciled. Check KYC/AML, FINRA registration, sanctions screening. Log results in Salesforce." },
];

const AGENTS = {
  research_agent: { name: "Research Agent", model: "Opus 4.5", icon: "\u{1F50D}", color: "#059669" },
  compliance_agent: { name: "Compliance Agent", model: "Sonnet 4.6", icon: "\u{1F6E1}", color: "#2563eb" },
  risk_agent: { name: "Risk Scoring Agent", model: "Haiku 4.5", icon: "\u{1F4CA}", color: "#d97706" },
  synthesis_agent: { name: "Synthesis Agent", model: "Opus 4.5", icon: "\u{1F9E0}", color: "#7c3aed" },
  salesforce_agent: { name: "Salesforce Agent", model: "Sonnet 4.6", icon: "\u{1F310}", color: "#dc2626" },
};

const TOOL_ICONS = {
  query_client_data: "\u{1F5C4}",
  query_market_intelligence: "\u{1F4F0}",
  query_compliance_records: "\u{1F4CB}",
  compute_risk_score: "\u{2696}",
  insert_deal_package: "\u{1F4BE}",
  update_client_status: "\u{270F}",
  computer_use: "\u{1F5B1}",
  screenshot: "\u{1F4F8}",
};

/* ═══════════════════════════════════════════════════════════════════════════════
   HEADER
   ═══════════════════════════════════════════════════════════════════════════════ */

function Header({ running, onReset }) {
  return (
    <header style={styles.header}>
      <div style={styles.headerCenter}>
        <svg width="28" height="28" viewBox="0 0 28 28" fill="none" style={{ marginRight: 10 }}>
          <rect width="28" height="28" rx="6" fill="#1a73e8" />
          <path d="M8 14l4 4 8-8" stroke="#fff" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
        <div>
          <h1 style={styles.title}>Deal Desk Agent</h1>
          <p style={styles.subtitle}><strong>Anthropic + Google Cloud</strong> &mdash; <strong>Better Together</strong></p>
        </div>
      </div>
      <div style={styles.headerRight}>
        <span style={{ ...styles.chip, background: "#1a73e8", color: "#fff", fontWeight: 700 }}>Google Cloud NEXT 2026</span>
        <span style={{ ...styles.chip, background: "#34a853", color: "#fff", fontWeight: 700 }}>Claude on Vertex AI</span>
        <span style={{ ...styles.chip, background: "#ea4335", color: "#fff", fontWeight: 700 }}>Agent Development Kit</span>
        <span style={{ ...styles.chip, background: "#fbbc04", color: "#1f2937", fontWeight: 700 }}>Computer Use API</span>
        {running && <span style={styles.liveIndicator}><span style={styles.liveDot} /> Running</span>}
        <button onClick={onReset} style={styles.resetBtn}>Reset</button>
      </div>
    </header>
  );
}

/* ═══════════════════════════════════════════════════════════════════════════════
   CHAT BUBBLE
   ═══════════════════════════════════════════════════════════════════════════════ */

function ChatMessage({ msg }) {
  const isUser = msg.role === "user";
  const isAgent = msg.role === "agent_event";

  if (isAgent) {
    const agentCfg = AGENTS[msg.agent] || { name: msg.agent, icon: "\u{2699}", color: "#6b7280" };
    const toolIcon = TOOL_ICONS[msg.tool] || "\u{2699}";

    if (msg.eventType === "agent_start") {
      return (
        <div style={styles.agentEventRow}>
          <div style={{ ...styles.agentEventBadge, borderColor: agentCfg.color }}>
            <span>{agentCfg.icon}</span>
            <span style={{ fontWeight: 600, color: agentCfg.color }}>{agentCfg.name}</span>
            <span style={styles.agentEventModel}>Claude {agentCfg.model} on Vertex AI</span>
            <span style={styles.agentEventStatus}>activating...</span>
          </div>
        </div>
      );
    }
    if (msg.eventType === "agent_complete") {
      return (
        <div style={styles.agentEventRow}>
          <div style={{ ...styles.agentEventBadge, borderColor: agentCfg.color, background: "#f0fdf4" }}>
            <span>{agentCfg.icon}</span>
            <span style={{ fontWeight: 600, color: "#059669" }}>{agentCfg.name} — Complete</span>
            <span style={{ color: "#059669", fontWeight: 600 }}>{"\u2713"}</span>
          </div>
        </div>
      );
    }
    if (msg.eventType === "tool_call") {
      return (
        <div style={styles.toolEventRow}>
          <div style={styles.toolEventLine} />
          <div style={styles.toolEventContent}>
            <span style={styles.toolEventIcon}>{toolIcon}</span>
            <span style={styles.toolEventLabel}>CALL</span>
            <span style={styles.toolEventMsg}><Markdown text={msg.msg} /></span>
          </div>
        </div>
      );
    }
    if (msg.eventType === "tool_result") {
      return (
        <div style={styles.toolEventRow}>
          <div style={styles.toolEventLine} />
          <div style={{ ...styles.toolEventContent, background: "#f0fdf4" }}>
            <span style={styles.toolEventIcon}>{"\u2705"}</span>
            <span style={{ ...styles.toolEventLabel, color: "#059669" }}>RESULT</span>
            <span style={styles.toolEventMsg}><Markdown text={msg.msg} /></span>
          </div>
        </div>
      );
    }
    if (msg.eventType === "deal_package" || msg.eventType === "agent_output") {
      return (
        <div style={styles.assistantRow}>
          <div style={styles.assistantBubble}>
            <div style={styles.assistantHeader}>
              <span>{agentCfg.icon}</span>
              <span style={{ fontWeight: 600 }}>{agentCfg.name}</span>
            </div>
            <div style={styles.assistantText}><Markdown text={msg.msg} /></div>
          </div>
        </div>
      );
    }
    if (msg.eventType === "pipeline_complete") {
      return (
        <div style={styles.agentEventRow}>
          <div style={{ ...styles.pipelineComplete }}>
            {"\u2705"} Pipeline complete — all agents finished
          </div>
        </div>
      );
    }
    return null;
  }

  if (msg.role === "assistant") {
    return (
      <div style={styles.assistantRow}>
        <div style={styles.assistantBubble}>
          <Markdown text={msg.text} />
        </div>
      </div>
    );
  }

  if (isUser) {
    return (
      <div style={styles.userRow}>
        <div style={styles.userBubble}>{msg.text}</div>
      </div>
    );
  }

  return null;
}

/* ═══════════════════════════════════════════════════════════════════════════════
   SALESFORCE PANEL
   ═══════════════════════════════════════════════════════════════════════════════ */

function SalesforcePanel({ active }) {
  return (
    <div style={styles.sfPanel}>
      <div style={styles.sfHeader}>
        <span style={{ width: 8, height: 8, borderRadius: "50%", background: active ? "#059669" : "#d1d5db" }} />
        <span style={styles.sfTitle}>Live Salesforce View</span>
        <span style={styles.sfBadge}>noVNC</span><a href="http://35.223.98.125:6080/vnc.html?autoconnect=true" target="_blank" rel="noopener" style={styles.newTabBtn}>Open in new tab 2197</a>
      </div>
      <div style={styles.sfBody}>
        {active ? (
          <div style={styles.sfPlaceholder}>
            <div style={{ fontSize: 48, marginBottom: 16 }}>{"\u{1F310}"}</div>
            <div style={{ fontSize: 16, fontWeight: 600, color: "#059669", marginBottom: 8 }}>Salesforce Agent Active</div>
            <div style={{ fontSize: 14, color: "#6b7280", lineHeight: 1.6, maxWidth: 340, marginBottom: 20, textAlign: "center" }}>
              Claude is navigating your Salesforce instance in real time. Click below to watch.
            </div>
            <a href="http://35.223.98.125:6080/vnc.html?autoconnect=true" target="_blank" rel="noopener"
              style={{ display: "inline-block", padding: "12px 28px", fontSize: 15, fontWeight: 700, borderRadius: 8, background: "#1a73e8", color: "#ffffff", textDecoration: "none", cursor: "pointer" }}>
              Watch Live in Salesforce {"\u2197"}
            </a>
          </div>
        ) : (
          <div style={styles.sfPlaceholder}>
            <div style={{ fontSize: 48, opacity: 0.3, marginBottom: 16 }}>{"\u{1F5A5}"}</div>
            <div style={{ fontSize: 16, fontWeight: 600, color: "#6b7280", marginBottom: 8 }}>Salesforce Browser</div>
            <div style={{ fontSize: 14, color: "#9ca3af", lineHeight: 1.6, maxWidth: 300 }}>
              The browser agent will activate here after the deal package is ready.
              Claude will navigate Salesforce Lightning in real time.
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

/* ═══════════════════════════════════════════════════════════════════════════════
   MAIN APP
   ═══════════════════════════════════════════════════════════════════════════════ */

export default function App() {
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState("");
  const [running, setRunning] = useState(false);
  const [sfActive, setSfActive] = useState(false);
  const chatEndRef = useRef(null);

  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const addMessage = (msg) => setMessages((prev) => [...prev, msg]);

  const handleReset = async () => {
    try { await fetch(`${API_BASE}/api/reset`, { method: "POST" }); } catch (e) {}
    setMessages([]);
    setRunning(false);
    setSfActive(false);
  };

  const handleSubmit = (text) => {
    if (!text.trim() || running) return;
    const prompt = text.trim();
    setInput("");
    setRunning(true);

    addMessage({ role: "user", text: prompt });

    fetch(`${API_BASE}/api/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt }),
    }).then(async (response) => {
      if (!response.ok) {
        addMessage({ role: "agent_event", eventType: "agent_output", agent: "synthesis_agent", msg: `Error: ${response.status} ${response.statusText}` });
        setRunning(false);
        return;
      }
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() || "";

        for (const line of lines) {
          if (line.startsWith("data: ")) {
            try {
              const evt = JSON.parse(line.slice(6));
              handleEvent(evt);
            } catch (e) {}
          }
        }
      }
      setRunning(false);
    }).catch((err) => {
      addMessage({ role: "agent_event", eventType: "agent_output", agent: "synthesis_agent", msg: `Connection error: ${err.message}` });
      setRunning(false);
    });
  };

  const handleEvent = (evt) => {
    if (evt.agent === "salesforce_agent" && evt.type === "agent_start") setSfActive(true);
    
    // Clean conversational responses — no pipeline chrome
    if (evt.type === "chat_response") {
      addMessage({
        role: "assistant",
        text: evt.msg || "",
      });
      setRunning(false);
      return;
    }

    addMessage({
      role: "agent_event",
      eventType: evt.type,
      agent: evt.agent || "unknown",
      tool: evt.tool || null,
      msg: evt.msg || "",
    });
  };

  return (
    <div style={styles.root}>
      <Header running={running} onReset={handleReset} />

      <div style={styles.mainLayout}>
        {/* ─── LEFT: Chat Interface ─── */}
        <div style={styles.chatPanel}>
          {/* Preset buttons */}
          <div style={styles.presetArea}>
            <span style={styles.presetLabel}>Demo scenarios</span>
            <div style={styles.presetBtns}>
              {PRESETS.map((p, i) => (
                <button key={i} onClick={() => handleSubmit(p.prompt)} disabled={running}
                  style={{ ...styles.presetBtn, opacity: running ? 0.5 : 1, cursor: running ? "not-allowed" : "pointer" }}>
                  {p.label}
                </button>
              ))}
            </div>
          </div>

          {/* Chat messages */}
          <div style={styles.chatMessages}>
            {messages.length === 0 && (
              <div style={styles.emptyChat}>
                <div style={{ fontSize: 40, opacity: 0.3, marginBottom: 12 }}>{"\u26A1"}</div>
                <div style={{ fontSize: 15, color: "#9ca3af", textAlign: "center", lineHeight: 1.6 }}>
                  Select a demo scenario above or type a message below.<br />
                  The multi-agent pipeline will activate and stream results here.
                </div>
              </div>
            )}
            {messages.map((msg, i) => <ChatMessage key={i} msg={msg} />)}
            <div ref={chatEndRef} />
          </div>

          {/* Input area */}
          <div style={styles.inputArea}>
            <input
              style={styles.chatInput}
              placeholder="Type a message or ask a follow-up question..."
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter") handleSubmit(input); }}
              disabled={running}
            />
            <button onClick={() => handleSubmit(input)} disabled={running || !input.trim()}
              style={{ ...styles.sendBtn, opacity: running || !input.trim() ? 0.5 : 1 }}>
              Send
            </button>
          </div>
        </div>

        {/* ─── RIGHT: Salesforce Viewer ─── */}
        <div style={styles.rightPanel}>
          <SalesforcePanel active={sfActive} />
        </div>
      </div>

      <footer style={styles.footer}>
        <span>Google Cloud NEXT 2026</span>
        <span style={styles.footerDot}>{"\u00B7"}</span>
        <span>Claude on Vertex AI</span>
        <span style={styles.footerDot}>{"\u00B7"}</span>
        <span>Agent Development Kit</span>
        <span style={styles.footerDot}>{"\u00B7"}</span>
        <span>Computer Use API</span>
      </footer>
    </div>
  );
}

/* ═══════════════════════════════════════════════════════════════════════════════
   STYLES
   ═══════════════════════════════════════════════════════════════════════════════ */

const styles = {
  root: {
    fontFamily: "'Google Sans', 'Segoe UI', system-ui, sans-serif",
    background: "#ffffff", height: "100vh", overflow: "hidden",
    display: "flex", flexDirection: "column", color: "#1f2937",
  },

  /* Header */
  header: {
    display: "flex", alignItems: "center", justifyContent: "space-between",
    padding: "12px 24px", borderBottom: "1px solid #e5e7eb", background: "#ffffff",
  },
  headerCenter: { display: "flex", alignItems: "center" },
  headerRight: { display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" },
  title: { fontSize: 18, fontWeight: 700, margin: 0, color: "#111827", textAlign: "center" },
  subtitle: { fontSize: 12, margin: 0, color: "#4b5563" },
  chip: {
    fontSize: 11, fontWeight: 500, padding: "4px 12px", borderRadius: 100,
    border: "none", whiteSpace: "nowrap",
  },
  liveIndicator: {
    display: "flex", alignItems: "center", gap: 6,
    fontSize: 12, fontWeight: 600, color: "#059669",
  },
  liveDot: {
    width: 8, height: 8, borderRadius: "50%", background: "#059669",
    display: "inline-block", animation: "pulse 1.5s ease-in-out infinite",
  },
  resetBtn: {
    fontSize: 12, fontWeight: 600, padding: "5px 14px", borderRadius: 6,
    border: "1px solid #d1d5db", background: "#ffffff", color: "#374151", cursor: "pointer",
  },

  /* Main Layout */
  mainLayout: { display: "flex", flex: 1, overflow: "hidden" },
  chatPanel: {
    width: "55%", display: "flex", flexDirection: "column", minHeight: 0,
    borderRight: "1px solid #e5e7eb", background: "#ffffff",
  },
  rightPanel: { width: "45%", display: "flex", flexDirection: "column", background: "#f9fafb" },

  /* Presets */
  presetArea: {
    padding: "12px 20px", borderBottom: "1px solid #f3f4f6",
    background: "#fafafa", display: "flex", alignItems: "center", gap: 12,
  },
  presetLabel: { fontSize: 12, fontWeight: 500, color: "#9ca3af", whiteSpace: "nowrap" },
  presetBtns: { display: "flex", gap: 8, flexWrap: "wrap" },
  presetBtn: {
    fontSize: 13, fontWeight: 500, padding: "6px 16px", borderRadius: 6,
    border: "1px solid #d1d5db", background: "#ffffff", color: "#1f2937", cursor: "pointer",
  },

  /* Chat Messages */
  chatMessages: { flex: 1, overflowY: "auto", padding: "16px 20px", display: "flex", flexDirection: "column", gap: 8, minHeight: 0 },
  emptyChat: {
    flex: 1, display: "flex", flexDirection: "column",
    alignItems: "center", justifyContent: "center", padding: 40,
  },

  /* User bubble */
  userRow: { display: "flex", justifyContent: "flex-end" },
  userBubble: {
    maxWidth: "70%", padding: "10px 16px", borderRadius: "16px 16px 4px 16px",
    background: "#1a73e8", color: "#ffffff", fontSize: 14, lineHeight: 1.6,
  },

  /* Agent events */
  agentEventRow: { display: "flex", justifyContent: "flex-start", padding: "4px 0" },
  agentEventBadge: {
    display: "flex", alignItems: "center", gap: 8, padding: "8px 14px",
    borderRadius: 8, border: "1px solid", background: "#f9fafb", fontSize: 13,
  },
  agentEventModel: { fontSize: 11, color: "#9ca3af" },
  agentEventStatus: { fontSize: 12, color: "#6b7280", fontStyle: "italic" },

  /* Tool events */
  toolEventRow: { display: "flex", alignItems: "center", gap: 8, paddingLeft: 24 },
  toolEventLine: { width: 2, height: 28, background: "#e5e7eb", borderRadius: 1, flexShrink: 0 },
  toolEventContent: {
    display: "flex", alignItems: "center", gap: 6, padding: "5px 12px",
    borderRadius: 6, background: "#f3f4f6", fontSize: 13, flex: 1,
  },
  toolEventIcon: { fontSize: 14, width: 20, textAlign: "center" },
  toolEventLabel: {
    fontSize: 10, fontWeight: 700, letterSpacing: "0.05em",
    color: "#6b7280", textTransform: "uppercase", flexShrink: 0,
  },
  toolEventMsg: { color: "#374151", flex: 1 },

  /* Assistant bubble */
  assistantRow: { display: "flex", justifyContent: "flex-start" },
  assistantBubble: {
    maxWidth: "80%", padding: "12px 16px", borderRadius: "16px 16px 16px 4px",
    background: "#f3f4f6", fontSize: 14, lineHeight: 1.6,
  },
  assistantHeader: { display: "flex", alignItems: "center", gap: 6, marginBottom: 6, fontSize: 13, fontWeight: 600 },
  assistantText: { color: "#1f2937", whiteSpace: "pre-wrap" },

  /* Pipeline complete */
  pipelineComplete: {
    padding: "10px 16px", borderRadius: 8, background: "#f0fdf4",
    border: "1px solid #bbf7d0", color: "#166534", fontWeight: 600, fontSize: 14,
  },

  /* Input area */
  inputArea: {
    padding: "12px 20px", borderTop: "1px solid #e5e7eb",
    display: "flex", gap: 10, background: "#ffffff",
  },
  chatInput: {
    flex: 1, padding: "10px 16px", fontSize: 14, borderRadius: 24,
    border: "1px solid #d1d5db", outline: "none", fontFamily: "inherit",
    color: "#1f2937", background: "#f9fafb",
  },
  sendBtn: {
    padding: "10px 24px", fontSize: 14, fontWeight: 600, borderRadius: 24,
    border: "none", background: "#1a73e8", color: "#ffffff", cursor: "pointer",
  },

  /* Salesforce panel */
  sfPanel: { display: "flex", flexDirection: "column", flex: 1 },
  sfHeader: {
    display: "flex", alignItems: "center", gap: 8,
    padding: "10px 20px", borderBottom: "1px solid #e5e7eb", background: "#ffffff",
  },
  sfTitle: { fontSize: 13, fontWeight: 600, color: "#374151", flex: 1 },
  sfBadge: {
  newTabBtn: {
    fontSize: 11, fontWeight: 600, padding: "3px 10px", borderRadius: 4,
    background: "#1a73e8", color: "#ffffff", textDecoration: "none",
    marginLeft: 6, cursor: "pointer",
  },
    fontSize: 10, fontWeight: 600, padding: "2px 8px", borderRadius: 4,
    background: "#f3f4f6", color: "#6b7280", textTransform: "uppercase", letterSpacing: "0.05em",
  },
  sfBody: { flex: 1, display: "flex" },
  sfIframe: { width: "100%", height: "100%", border: "none" },
  sfPlaceholder: {
    flex: 1, display: "flex", flexDirection: "column",
    alignItems: "center", justifyContent: "center", padding: 40, textAlign: "center",
  },

  /* Footer */
  footer: {
    display: "flex", alignItems: "center", justifyContent: "center", gap: 8,
    padding: "10px 24px", borderTop: "1px solid #e5e7eb",
    fontSize: 12, fontWeight: 500, color: "#9ca3af", background: "#ffffff",
  },
  footerDot: { color: "#d1d5db" },
};

/* Global CSS */
if (typeof document !== "undefined") {
  const s = document.createElement("style");
  s.textContent = `
    @keyframes spin { to { transform: rotate(360deg); } }
    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }
    @import url('https://fonts.googleapis.com/css2?family=Google+Sans:wght@400;500;600;700&display=swap');
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { margin: 0; background: #ffffff; }
    input:focus { border-color: #1a73e8 !important; background: #ffffff !important; }
    button:hover:not(:disabled) { filter: brightness(0.95); }
  `;
  document.head.appendChild(s);
}
