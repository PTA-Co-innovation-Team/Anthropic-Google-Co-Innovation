#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dev VM startup script (Terraform-templated).
#
# Runs once on first boot via GCE metadata startup-script. Installs:
#   * Node.js LTS (Claude Code is a Node app)
#   * Claude Code itself (the official npm package)
#   * code-server (if $install_vscode_server == "true")
#   * A system-wide /etc/claude-code/settings.json pre-configured for
#     this deployment, so any developer on OS Login gets Claude Code
#     pointing at the right gateway out of the box.
#   * Optional: an auto-shutdown systemd timer that powers the VM off
#     after $auto_shutdown_idle_hours with no SSH sessions.
#
# Templated variables (replaced by Terraform's templatefile()):
#   $${project_id}
#   $${vertex_region}
#   $${llm_gateway_url}
#   $${mcp_gateway_url}
#   $${install_vscode_server}   ("true" or "false")
#   $${auto_shutdown_idle_hours} (0 disables)
# -----------------------------------------------------------------------------

set -euo pipefail

# Log everything to a dedicated file so operators can debug a failed
# bootstrap without re-running the startup script.
exec > >(tee -a /var/log/claude-code-bootstrap.log) 2>&1
echo "[bootstrap] starting at $(date -u +%FT%TZ)"

# --- Base OS update ----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq python3 python3-pip git

# --- Node.js LTS via NodeSource --------------------------------------------
if ! command -v node >/dev/null; then
  echo "[bootstrap] installing Node.js LTS"
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y nodejs
fi

# --- Claude Code -------------------------------------------------------------
# The official npm package. Installs the `claude` CLI globally so every
# OS Login user on the box picks it up.
if ! command -v claude >/dev/null; then
  echo "[bootstrap] installing Claude Code"
  npm install -g @anthropic-ai/claude-code
fi

# --- System-wide Claude Code settings ---------------------------------------
# Claude Code reads ~/.claude/settings.json per-user. We ALSO write a
# system-wide /etc/claude-code/settings.json and a shell snippet in
# /etc/profile.d/ that symlinks it into new users' home on first login.
install -d -m 0755 /etc/claude-code
cat >/etc/claude-code/settings.json <<'JSON'
{
  "env": {
    "CLAUDE_CODE_USE_VERTEX": "1",
    "CLOUD_ML_REGION": "${vertex_region}",
    "ANTHROPIC_VERTEX_PROJECT_ID": "${project_id}",
    "ANTHROPIC_VERTEX_BASE_URL": "${llm_gateway_url}",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
JSON

# Accept self-signed GLB cert when gateway URL is IP-based.
case "${llm_gateway_url}" in
  https://[0-9]*)
    python3 -c '
import json
p = "/etc/claude-code/settings.json"
with open(p) as f: s = json.load(f)
s["env"]["NODE_TLS_REJECT_UNAUTHORIZED"] = "0"
with open(p, "w") as f: json.dump(s, f, indent=2)
'
    ;;
esac

# Add MCP server config only when a gateway URL was provided.
if [ -n "${mcp_gateway_url}" ]; then
  python3 -c '
import json, sys
p = "/etc/claude-code/settings.json"
with open(p) as f: s = json.load(f)
s["mcpServers"] = {"gcp-tools": {"type": "http", "url": sys.argv[1]}}
with open(p, "w") as f: json.dump(s, f, indent=2)
' "${mcp_gateway_url}/mcp"
fi

cat >/etc/profile.d/claude-code-settings.sh <<'SH'
# Link the shared Claude Code settings into the user's home on first
# login, if they don't already have a file there.
if [ -n "$HOME" ] && [ ! -e "$HOME/.claude/settings.json" ]; then
  mkdir -p "$HOME/.claude"
  ln -sf /etc/claude-code/settings.json "$HOME/.claude/settings.json"
fi
SH
chmod 0755 /etc/profile.d/claude-code-settings.sh

# --- code-server (optional) --------------------------------------------------
if [ "${install_vscode_server}" = "true" ] && ! command -v code-server >/dev/null; then
  echo "[bootstrap] installing code-server"
  curl -fsSL https://code-server.dev/install.sh | sh

  # Run code-server as a systemd user service; we bind to 0.0.0.0:8080
  # inside the VPC and expose to users via IAP's TCP tunnel.
  cat >/etc/systemd/system/code-server.service <<'UNIT'
[Unit]
Description=code-server (VS Code in the browser)
After=network-online.target

[Service]
Type=simple
# Runs as the "claude-shared" user when in shared mode — created lazily
# below. Per-user mode would set User=%i on a templated unit instead.
User=claude-shared
Environment=PASSWORD=disabled
ExecStart=/usr/bin/code-server --bind-addr 0.0.0.0:8080 --auth none
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

  # Create a shared user for code-server ONLY. Developers SSH in as
  # themselves via OS Login; code-server runs as this service account
  # for convenience.
  id claude-shared >/dev/null 2>&1 || useradd -m -s /bin/bash claude-shared

  systemctl daemon-reload
  systemctl enable --now code-server.service
fi

# --- Auto-shutdown timer -----------------------------------------------------
if [ "${auto_shutdown_idle_hours}" != "0" ]; then
  echo "[bootstrap] installing auto-shutdown timer (${auto_shutdown_idle_hours}h idle)"

  cat >/usr/local/sbin/claude-code-maybe-shutdown <<'SCRIPT'
#!/usr/bin/env bash
# Power off if no SSH sessions have been active within the last N hours.
IDLE_HOURS="$1"
# `who` lists active terminals; if empty, no users logged in.
if ! who | grep -q .; then
  # Also check the last SSH session end time from wtmp; be conservative.
  LAST_LOGIN_EPOCH=$(last -1 -F | head -n1 | awk '{print $(NF-1),$NF}' | xargs -I{} date -d "{}" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  if [ "$((NOW_EPOCH - LAST_LOGIN_EPOCH))" -gt "$((IDLE_HOURS * 3600))" ]; then
    logger -t claude-code-auto-shutdown "shutting down, idle > $${IDLE_HOURS}h"
    shutdown -h now
  fi
fi
SCRIPT
  chmod +x /usr/local/sbin/claude-code-maybe-shutdown

  cat >/etc/systemd/system/claude-code-auto-shutdown.service <<UNIT
[Unit]
Description=Shut down if idle > ${auto_shutdown_idle_hours}h

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/claude-code-maybe-shutdown ${auto_shutdown_idle_hours}
UNIT

  cat >/etc/systemd/system/claude-code-auto-shutdown.timer <<'UNIT'
[Unit]
Description=Periodically check idle state

[Timer]
OnBootSec=15min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now claude-code-auto-shutdown.timer
fi

echo "[bootstrap] done at $(date -u +%FT%TZ)"
