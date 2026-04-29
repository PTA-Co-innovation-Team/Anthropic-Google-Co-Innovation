FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV DISPLAY_WIDTH=1280
ENV DISPLAY_HEIGHT=800

# ─── System dependencies ───
RUN apt-get update && apt-get install -y \
    xvfb \
    x11vnc \
    xdotool \
    scrot \
    fluxbox \
    wget \
    curl \
    gnupg2 \
    python3 \
    python3-pip \
    python3-venv \
    supervisor \
    net-tools \
    novnc \
    websockify \
    fonts-liberation \
    libnss3 \
    libatk-bridge2.0-0 \
    libdrm2 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libgbm1 \
    libasound2t64 \
    libpango-1.0-0 \
    libcairo2 \
    libcups2 \
    libxss1 \
    libxtst6 \
    xauth \
    && rm -rf /var/lib/apt/lists/*

# ─── Install Google Chrome ───
RUN wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor > /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# ─── Python dependencies for the agent loop ───
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --no-cache-dir \
    httpx \
    google-auth \
    google-cloud-bigquery \
    fastapi \
    uvicorn

# ─── noVNC setup ───
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# ─── Agent server ───
COPY agent_server.py /opt/venv/agent_server.py
COPY salesforce_browser_agent.py /opt/venv/salesforce_browser_agent.py

# ─── Supervisor config ───
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# ─── Entrypoint ───
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ─── Ports ───
# 5900 = VNC, 6080 = noVNC web viewer, 8090 = agent server
EXPOSE 5900 6080 8090

ENTRYPOINT ["/entrypoint.sh"]
