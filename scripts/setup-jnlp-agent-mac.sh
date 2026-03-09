#!/usr/bin/env bash
set -euo pipefail

# Set up Jenkins JNLP agent on Mac Mini with SSH tunnel + health check
# Uses autossh tunnel to Jenkins (bypasses nginx/Authelia for stability)
#
# Prerequisites:
#   - Java 17+ installed (brew install openjdk@17)
#   - SSH key configured for Jenkins server (e.g. rocky@161.118.206.170)
#   - autossh installed (brew install autossh)
#
# Usage: ./setup-jnlp-agent-mac.sh <agent-secret> <ssh-target>
#   agent-secret: Get from Jenkins → Manage Jenkins → Nodes → macmini
#   ssh-target:   SSH destination, e.g. rocky@161.118.206.170

AGENT_NAME="macmini"
AGENT_DIR="$HOME/jenkins-agent"
AGENT_JAR="$AGENT_DIR/agent.jar"
TUNNEL_LOCAL_PORT=18080
JENKINS_REMOTE_PORT=8080
JENKINS_URL="http://localhost:${TUNNEL_LOCAL_PORT}/jenkins/"
DOWNLOAD_URL="https://arcana.boo/jenkins/"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <agent-secret> <ssh-target>"
    echo ""
    echo "  agent-secret: Get from Jenkins → Manage Jenkins → Nodes → macmini"
    echo "  ssh-target:   e.g. rocky@161.118.206.170"
    exit 1
fi

AGENT_SECRET="$1"
SSH_TARGET="$2"

# ── Validate prerequisites ────────────────────
echo "Checking prerequisites..."
which java >/dev/null 2>&1 || { echo "ERROR: Java not found. Install with: brew install openjdk@17"; exit 1; }
which autossh >/dev/null 2>&1 || { echo "ERROR: autossh not found. Install with: brew install autossh"; exit 1; }

SSH_KEY="$HOME/.ssh/id_ed25519"
[ -f "$SSH_KEY" ] || SSH_KEY="$HOME/.ssh/id_rsa"
[ -f "$SSH_KEY" ] || { echo "ERROR: No SSH key found at ~/.ssh/id_ed25519 or ~/.ssh/id_rsa"; exit 1; }

# Test SSH connection
echo "Testing SSH connection to $SSH_TARGET..."
ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "$SSH_TARGET" "echo OK" >/dev/null 2>&1 \
    || { echo "ERROR: Cannot SSH to $SSH_TARGET. Check your SSH key and target."; exit 1; }

# ── Setup ─────────────────────────────────────
echo "Setting up Jenkins JNLP agent with SSH tunnel..."
mkdir -p "$AGENT_DIR"

# Download agent.jar
echo "Downloading agent.jar..."
curl -sL "${DOWNLOAD_URL}jnlpJars/agent.jar" -o "$AGENT_JAR"

# ── Optimize power management ─────────────────
echo "Optimizing power management for CI agent..."
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 \
    networkoversleep 1 womp 1 tcpkeepalive 1 2>/dev/null || true

# ── 0. Prevent sleep (caffeinate) ─────────────
# pmset sleep 0 does NOT prevent Maintenance Sleep on Apple Silicon.
# caffeinate -s is required to prevent ALL sleep states.
CAFFEINATE_PLIST="$HOME/Library/LaunchAgents/com.jenkins.caffeinate.plist"
cat > "$CAFFEINATE_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jenkins.caffeinate</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-s</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

# ── 1. SSH Tunnel (autossh) ───────────────────
TUNNEL_PLIST="$HOME/Library/LaunchAgents/com.jenkins.tunnel.plist"
cat > "$TUNNEL_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jenkins.tunnel</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>AUTOSSH_GATETIME</key>
        <string>0</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>$(which autossh)</string>
        <string>-M</string>
        <string>0</string>
        <string>-N</string>
        <string>-o</string>
        <string>ServerAliveInterval=30</string>
        <string>-o</string>
        <string>ServerAliveCountMax=3</string>
        <string>-o</string>
        <string>ExitOnForwardFailure=yes</string>
        <string>-o</string>
        <string>StrictHostKeyChecking=no</string>
        <string>-i</string>
        <string>$SSH_KEY</string>
        <string>-L</string>
        <string>${TUNNEL_LOCAL_PORT}:localhost:${JENKINS_REMOTE_PORT}</string>
        <string>$SSH_TARGET</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$AGENT_DIR/tunnel.log</string>
    <key>StandardErrorPath</key>
    <string>$AGENT_DIR/tunnel.log</string>
</dict>
</plist>
EOF

# ── 2. Jenkins Agent ──────────────────────────
AGENT_PLIST="$HOME/Library/LaunchAgents/com.jenkins.agent.plist"
cat > "$AGENT_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jenkins.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which java)</string>
        <string>-jar</string>
        <string>$AGENT_JAR</string>
        <string>-url</string>
        <string>$JENKINS_URL</string>
        <string>-name</string>
        <string>$AGENT_NAME</string>
        <string>-secret</string>
        <string>$AGENT_SECRET</string>
        <string>-workDir</string>
        <string>$AGENT_DIR</string>
        <string>-webSocket</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$AGENT_DIR/agent.log</string>
    <key>StandardErrorPath</key>
    <string>$AGENT_DIR/agent.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF

# ── 3. Health Check Daemon ────────────────────
cat > "$AGENT_DIR/check-agent-daemon.sh" << 'HEALTHCHECK'
#!/bin/bash
# Jenkins agent health check daemon — API check + log staleness fallback
AGENT_DIR="$HOME/jenkins-agent"
PLIST="$HOME/Library/LaunchAgents/com.jenkins.agent.plist"
LOGFILE="${AGENT_DIR}/check-agent.log"
REMOTING_LOG="${AGENT_DIR}/remoting/logs/remoting.log.0"
FAIL_MARKER="${AGENT_DIR}/.failing_since"
JENKINS_API="http://localhost:18080/jenkins/computer/macmini/api/json?tree=offline,temporarilyOffline"
JENKINS_AUTH="admin:admin"
STALE_THRESHOLD=300  # 5 min log staleness = silent disconnect (fallback)
FAIL_THRESHOLD=120   # 2 min of continuous offline = restart
CHECK_INTERVAL=30    # check every 30s

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

restart_agent() {
    local reason="$1"
    echo "$(timestamp) RESTART: ${reason}" >> "$LOGFILE"
    pkill -9 -f 'jenkins-agent/agent.jar' 2>/dev/null
    sleep 2
    launchctl unload "$PLIST" 2>/dev/null
    sleep 1
    launchctl load "$PLIST"
    rm -f "$FAIL_MARKER"
    echo "$(timestamp) Agent restarted." >> "$LOGFILE"
}

mark_offline() {
    local NOW="$1"
    if [ ! -f "$FAIL_MARKER" ]; then
        date +%s > "$FAIL_MARKER"
        echo "$(timestamp) Agent offline, monitoring..." >> "$LOGFILE"
        return
    fi
    FAIL_SINCE=$(cat "$FAIL_MARKER")
    FAIL_DURATION=$(( NOW - FAIL_SINCE ))
    if [ "$FAIL_DURATION" -gt "$FAIL_THRESHOLD" ]; then
        restart_agent "offline for ${FAIL_DURATION}s"
    fi
}

echo "$(timestamp) Health check daemon started (PID $$)" >> "$LOGFILE"

while true; do
    # Log rotation
    if [ -f "$LOGFILE" ] && [ "$(wc -l < "$LOGFILE")" -gt 500 ]; then
        tail -200 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
    fi

    NOW=$(date +%s)

    # 1. Process check
    if ! pgrep -f 'jenkins-agent/agent.jar' > /dev/null 2>&1; then
        restart_agent "process not running"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # 2. Try Jenkins API via SSH tunnel
    HTTP_CODE=$(curl -s -m 5 -o /tmp/jenkins-agent-status.json -w '%{http_code}' \
        --user "$JENKINS_AUTH" "$JENKINS_API" 2>/dev/null)

    if [ "$HTTP_CODE" = "200" ]; then
        OFFLINE=$(python3 -c "import json;d=json.load(open('/tmp/jenkins-agent-status.json'));print(d.get('offline',False))" 2>/dev/null)
        TEMP_OFFLINE=$(python3 -c "import json;d=json.load(open('/tmp/jenkins-agent-status.json'));print(d.get('temporarilyOffline',False))" 2>/dev/null)

        # Manually taken offline — don't touch
        if [ "$TEMP_OFFLINE" = "True" ]; then
            rm -f "$FAIL_MARKER"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        if [ "$OFFLINE" = "False" ]; then
            rm -f "$FAIL_MARKER"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # Jenkins says offline
        mark_offline "$NOW"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # 3. Fallback: API unreachable (tunnel down) — use log staleness
    if [ -f "$REMOTING_LOG" ]; then
        LOG_MTIME=$(stat -f %m "$REMOTING_LOG" 2>/dev/null)
        LOG_AGE=$(( NOW - LOG_MTIME ))

        LAST_STATUS=$(grep -E '(Connected$|Failed to connect|Terminated)' "$REMOTING_LOG" | tail -1)

        if echo "$LAST_STATUS" | grep -q 'Connected$' && [ "$LOG_AGE" -gt "$STALE_THRESHOLD" ]; then
            mark_offline "$NOW"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        if echo "$LAST_STATUS" | grep -qE 'Failed to connect|Terminated'; then
            mark_offline "$NOW"
            sleep "$CHECK_INTERVAL"
            continue
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
HEALTHCHECK
chmod +x "$AGENT_DIR/check-agent-daemon.sh"

CHECK_PLIST="$HOME/Library/LaunchAgents/com.jenkins.agent.check.plist"
cat > "$CHECK_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jenkins.agent.check</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$AGENT_DIR/check-agent-daemon.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$AGENT_DIR/check-agent-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$AGENT_DIR/check-agent-launchd.log</string>
</dict>
</plist>
EOF

# ── Load all services ─────────────────────────
echo "Loading services..."

# 0. Caffeinate (prevent sleep)
launchctl unload "$CAFFEINATE_PLIST" 2>/dev/null || true
launchctl load -w "$CAFFEINATE_PLIST"

# 1. Tunnel
launchctl unload "$TUNNEL_PLIST" 2>/dev/null || true
launchctl load -w "$TUNNEL_PLIST"
echo "  Waiting for tunnel..."
for i in $(seq 1 10); do
    if curl -s -m 2 -o /dev/null "http://localhost:${TUNNEL_LOCAL_PORT}/jenkins/login" 2>/dev/null; then
        echo "  Tunnel ready."
        break
    fi
    sleep 1
done

# 2. Agent
launchctl unload "$AGENT_PLIST" 2>/dev/null || true
launchctl load -w "$AGENT_PLIST"

# 3. Health check daemon
launchctl unload "$CHECK_PLIST" 2>/dev/null || true
launchctl load -w "$CHECK_PLIST"

sleep 3

echo ""
echo "Jenkins JNLP agent installed with SSH tunnel + health check."
echo ""
echo "  Services:"
echo "    com.jenkins.caffeinate   — Prevent system sleep (caffeinate -s)"
echo "    com.jenkins.tunnel       — autossh SSH tunnel (port $TUNNEL_LOCAL_PORT)"
echo "    com.jenkins.agent        — Jenkins agent (via tunnel)"
echo "    com.jenkins.agent.check  — Health check daemon (30s interval)"
echo ""
echo "  Logs:"
echo "    $AGENT_DIR/tunnel.log"
echo "    $AGENT_DIR/agent.log"
echo "    $AGENT_DIR/check-agent.log"
echo ""
echo "Commands:"
echo "  Status:  launchctl list | grep jenkins"
echo "  Logs:    tail -f $AGENT_DIR/check-agent.log"
