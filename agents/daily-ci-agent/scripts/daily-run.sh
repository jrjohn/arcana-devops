#!/usr/bin/env bash
# Daily CI agent driver: invoke claude with the daily prompt.
set -euo pipefail

# Inherit container env vars (cron strips them — without this, $GH_TOKEN etc are empty)
set -a
while IFS= read -d $'\0' -r line; do export "$line"; done < /proc/1/environ
set +a

LOG_PREFIX=$(date '+%Y-%m-%d %H:%M:%S')
REPORT_DATE=$(date +%F)
REPORT_DIR=/data/ci-reports
REPORT_PATH="${REPORT_DIR}/${REPORT_DATE}.md"
PROMPT_FILE=/opt/prompt/daily.md
CLAUDE_BIN=$(command -v claude || echo /usr/local/bin/claude)

mkdir -p "$REPORT_DIR" /tmp/repos

# Defensive chown: in case interactive `claude` as root in the container
# overwrote /root/.claude.json or .credentials.json with root ownership,
# claude-agent (via runuser) can't read them and silently produces empty output.
chown claude-agent:claude-agent /root/.claude /root/.claude.json /root/.claude/.credentials.json 2>/dev/null || true
chown -R claude-agent:claude-agent /root/.claude 2>/dev/null || true

# Configure git for agent-driven commits.
# daily-run.sh runs as root via cron; claude-agent (uid 1001, HOME=/root) needs to
# write/extend /root/.gitconfig too (e.g. `gh auth setup-git` adds a credential
# helper). chown after writing so the agent can mutate it later without -c overrides.
git config --global user.name "jrjohn"
git config --global user.email "jrjohn@users.noreply.github.com"
git config --global init.defaultBranch main
git config --global --add safe.directory '*'  # /tmp/repos/* will be different uids
chown claude-agent:claude-agent /root/.gitconfig 2>/dev/null || true
chmod 664 /root/.gitconfig 2>/dev/null || true

# Re-auth gh as claude-agent (since runuser drops creds; refresh from env)
if [ -n "${GH_TOKEN:-}" ]; then
  /usr/sbin/runuser -u claude-agent -- bash -c "echo \"$GH_TOKEN\" | gh auth login --with-token 2>/dev/null && gh auth setup-git 2>/dev/null" || true
fi

echo "=== ${LOG_PREFIX} daily-run start ==="

if [ ! -x "$CLAUDE_BIN" ]; then
  echo "ERROR: claude CLI not found at $CLAUDE_BIN"; exit 1
fi
if [ ! -r "$PROMPT_FILE" ]; then
  echo "ERROR: prompt file missing: $PROMPT_FILE"; exit 1
fi
if [ ! -f /root/.claude/.credentials.json ]; then
  echo "ERROR: Claude not authenticated. Run: docker exec -it daily-ci-agent claude /login"
  echo "# Daily CI report — ${REPORT_DATE}" > "$REPORT_PATH"
  echo "" >> "$REPORT_PATH"
  echo "**ERROR**: Claude CLI not authenticated in container. Re-run OAuth setup." >> "$REPORT_PATH"
  exit 1
fi

export REPORT_PATH REPORT_DATE

# Write tokens to a sourceable env file. Claude Code's Bash tool subshells
# don't always inherit parent process env reliably; the agent's prompt
# instructs it to `source /tmp/agent.env` at the start of each Bash call.
#
# `rm -f` first: in this Docker container, root cannot overwrite a 600 file
# owned by claude-agent (likely SELinux MAC or userns DAC restriction), but
# /tmp's sticky bit allows root to unlink. Delete then create cleanly.
AGENT_ENV=/tmp/agent.env
rm -f "$AGENT_ENV"
umask 077
cat > "$AGENT_ENV" <<EOF
export GH_TOKEN='${GH_TOKEN:-}'
export JENKINS_USER='${JENKINS_USER:-}'
export JENKINS_TOKEN='${JENKINS_TOKEN:-}'
export SONAR_TOKEN='${SONAR_TOKEN:-}'
export CRS_PG_URL='${CRS_PG_URL:-}'
export OLLAMA_URL='${OLLAMA_URL:-http://localhost:11434}'
EOF
chown claude-agent:claude-agent "$AGENT_ENV"
chmod 600 "$AGENT_ENV"
echo "  tokens written to $AGENT_ENV"


# The secrets go through the environment, never the command line: `runuser -- env NAME=value`
# put every token in claude's argv, readable by anything that lists processes (2026-11-13).
# runuser -u (no --login) keeps the caller's environment, so exporting is enough.
export GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN JENKINS_USER JENKINS_TOKEN SONAR_TOKEN CRS_PG_URL

PROMPT_CONTENT=$(cat "$PROMPT_FILE")
# Drop privileges to claude-agent (claude CLI refuses --dangerously-skip-permissions as root).
# At most 3 h: a run that waits on background work can otherwise hang into the next day
# (2026-11-13). The missing-report guard below then writes the report and mails John.
timeout --kill-after=60 10800 /usr/sbin/runuser -u claude-agent -- env \
    HOME=/root \
    PATH=/root/.cargo/bin:/root/bin:/usr/local/bin:/usr/bin:/bin \
    REPORT_PATH="$REPORT_PATH" \
    REPORT_DATE="$REPORT_DATE" \
    OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}" \
  "$CLAUDE_BIN" --print --dangerously-skip-permissions "$PROMPT_CONTENT"

echo "=== $(date '+%Y-%m-%d %H:%M:%S') daily-run done (report: $REPORT_PATH) ==="

# The agent can end its --print session while it "waits" for background work and never write
# the report (2026-11-10). A missing report must not look like a quiet day: write one that says
# so and counts as a human-review item, so the mail below goes out.
if [ ! -s "$REPORT_PATH" ]; then
  echo "  [guard] agent finished without writing $REPORT_PATH — writing a placeholder"
  cat > "$REPORT_PATH" <<EOF
# Daily CI report — ${REPORT_DATE}

## Summary
- Needs human review: 1 (the agent run ended without writing its report)

## Needs human review
### daily-ci-agent produced no report
The agent session ended at $(date '+%H:%M') without writing this file. Check /var/log/daily-run.log
inside the daily-ci-agent container for where it stopped (often: it started background polling and ended its turn).
EOF
  chown claude-agent:claude-agent "$REPORT_PATH" 2>/dev/null || true
fi

# ── Email alert (SendGrid) — only when the agent flagged items needing human ──
# review, so we don't spam (most days N=0 → no send). Key in the bind-mounted
# claude-home so it survives without recreating this container (which would drop
# the runtime crs-build cron). Added 2026-05-28.
ALERT_KEY=$(cat /root/.claude/.sendgrid-key 2>/dev/null)
NEED=$(grep -iE "needs human review" "$REPORT_PATH" 2>/dev/null | grep -oE "[0-9]+" | head -1)
if [ -n "$ALERT_KEY" ] && [ -n "$NEED" ] && [ "$NEED" -gt 0 ] 2>/dev/null; then
    SENDGRID_KEY="$ALERT_KEY" python3 - "$NEED" "$REPORT_DATE" "$REPORT_PATH" <<'PY'
import os, sys, json, urllib.request
need, date, path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    body = open(path, encoding="utf-8", errors="replace").read()[:3500]
except Exception:
    body = "(report unreadable)"
payload = {
    "personalizations": [{"to": [{"email": "jr.johnchang@gmail.com"}]}],
    "from": {"email": "ci@arcana.boo", "name": "Arcana CI"},
    "subject": f"[arcana-ci] {need} pipeline(s) need human review — {date}",
    "content": [{"type": "text/plain", "value":
        f"daily-ci-agent flagged {need} item(s) needing human review on {date}.\n"
        f"It cannot fix these itself (infra outage / major migration / etc).\n\n"
        f"Report: {path}\n\n--- report (truncated) ---\n{body}"}],
}
req = urllib.request.Request("https://api.sendgrid.com/v3/mail/send",
    data=json.dumps(payload).encode(),
    headers={"Authorization": "Bearer " + os.environ["SENDGRID_KEY"],
             "Content-Type": "application/json"})
try:
    # 2026-10-13: Gmail SMTP first (SendGrid free credits ran out → 401 "Maximum credits exceeded"
    # since ~09-25, so 19 days of escalations never reached John). SendGrid kept as fallback.
    import smtplib, ssl
    from email.mime.text import MIMEText
    gu, gp = open("/root/.claude/.gmail-smtp").read().split()[:2]
    m = MIMEText(payload["content"][0]["value"], "plain", "utf-8")
    m["Subject"], m["From"], m["To"] = payload["subject"], f"Arcana CI <{gu}>", "jr.johnchang@gmail.com"
    with smtplib.SMTP_SSL("smtp.gmail.com", 465, context=ssl.create_default_context(), timeout=20) as s:
        s.login(gu, gp); s.sendmail(gu, ["jr.johnchang@gmail.com"], m.as_string())
    print(f"  [notify] email alert sent via gmail (need={need})")
except Exception as ge:
    try:
        r = urllib.request.urlopen(req, timeout=20)
        print(f"  [notify] email alert sent via sendgrid (HTTP {r.status}, need={need}; gmail failed: {ge})")
    except Exception as e:
        body = e.read()[:200] if hasattr(e, "read") else b""
        print(f"  [notify] email alert FAILED: gmail={ge} sendgrid={e} {body}")
PY
else
    echo "  [notify] no email alert (need=${NEED:-0})"
fi

# ── Release orchestration (release-please, gated on green CI) — folded into daily run (John 2026-06-01) ──
echo "=== $(date '+%H:%M:%S') release-please orchestration ==="
/usr/sbin/runuser -u claude-agent -- env \
    HOME=/root PATH=/root/.cargo/bin:/root/bin:/usr/local/bin:/usr/bin:/bin \
    /root/.claude/run-release-please.sh || echo "  [release] orchestration step failed (non-fatal)"
