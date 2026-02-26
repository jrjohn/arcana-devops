#!/usr/bin/env bash
set -euo pipefail

# Set up Jenkins JNLP agent on Mac Mini as a launchd service
# Connects outbound to https://arcana.boo/jenkins/ via WebSocket
#
# Prerequisites:
#   - Java 17+ installed (brew install openjdk@17)
#   - Jenkins agent.jar downloaded
#
# Usage: ./setup-jnlp-agent-mac.sh <agent-secret>
#   Get the secret from: Jenkins → Manage Jenkins → Nodes → macmini

JENKINS_URL="https://arcana.boo/jenkins/"
AGENT_NAME="macmini"
AGENT_DIR="$HOME/jenkins-agent"
AGENT_JAR="$AGENT_DIR/agent.jar"
PLIST_NAME="com.jenkins.agent"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <agent-secret>"
    echo ""
    echo "Get the secret from Jenkins → Manage Jenkins → Nodes → macmini"
    exit 1
fi

AGENT_SECRET="$1"

# ── Setup ─────────────────────────────────────
echo "Setting up Jenkins JNLP agent..."

mkdir -p "$AGENT_DIR"

# Download agent.jar
echo "Downloading agent.jar..."
curl -sL "${JENKINS_URL}jnlpJars/agent.jar" -o "$AGENT_JAR"

# ── Create launchd plist ──────────────────────
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
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

# ── Load service ──────────────────────────────
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load -w "$PLIST_PATH"

echo ""
echo "Jenkins JNLP agent installed as launchd service."
echo "  Service: $PLIST_NAME"
echo "  Work dir: $AGENT_DIR"
echo "  Log: $AGENT_DIR/agent.log"
echo ""
echo "Commands:"
echo "  Status:  launchctl list | grep jenkins"
echo "  Stop:    launchctl unload $PLIST_PATH"
echo "  Start:   launchctl load -w $PLIST_PATH"
echo "  Logs:    tail -f $AGENT_DIR/agent.log"
