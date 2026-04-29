#!/bin/bash
# Don't use set -e — we need all services to start even if one fails

DISPLAY_WIDTH="${DISPLAY_WIDTH:-1280}"
DISPLAY_HEIGHT="${DISPLAY_HEIGHT:-800}"
SALESFORCE_URL="${SALESFORCE_URL:-https://orgfarm-09257c3eee-dev-ed.develop.lightning.force.com}"

echo "══════════════════════════════════════════════════════════"
echo "  Deal Desk Agent — Browser VM"
echo "  Display: ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}"
echo "  Salesforce: ${SALESFORCE_URL}"
echo "══════════════════════════════════════════════════════════"

echo "Starting Xvfb on :1..."
Xvfb :1 -screen 0 ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}x24 -ac +extension GLX +render -noreset &
sleep 1

echo "Starting Fluxbox..."
DISPLAY=:1 fluxbox &
sleep 1

echo "Starting x11vnc..."
x11vnc -display :1 -forever -nopw -shared -rfbport 5900 -quiet &
sleep 1

echo "Starting noVNC on port 6080..."
websockify --web=/usr/share/novnc 6080 localhost:5900 &
sleep 1

echo "Launching Chrome..."
DISPLAY=:1 google-chrome-stable \
    --no-first-run \
    --no-default-browser-check \
    --disable-infobars \
    --disable-extensions \
    --disable-dev-shm-usage \
    --no-sandbox \
    --disable-gpu \
    --window-size=${DISPLAY_WIDTH},${DISPLAY_HEIGHT} \
    --window-position=0,0 \
    --start-maximized \
    --user-data-dir=/tmp/chrome-profile \
    "${SALESFORCE_URL}" &

echo "Starting agent server on port 8090..."
cd /opt/venv && python3 agent_server.py &
AGENT_PID=$!
sleep 2
if kill -0 $AGENT_PID 2>/dev/null; then
    echo "Agent server started (PID $AGENT_PID)"
else
    echo "WARNING: Agent server failed to start"
fi

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Browser VM ready"
echo "  noVNC: http://localhost:6080/vnc.html"
echo "  Agent: http://localhost:8090"
echo "══════════════════════════════════════════════════════════"

wait
