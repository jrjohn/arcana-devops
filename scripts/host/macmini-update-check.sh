#!/bin/bash
# macmini-update-check — weekly: are macOS / Xcode on the Mac mini (iOS build agent) behind?
#
# Why (2026-09-30): the Mac mini was still on Xcode 26.2 (installed 2026-02-24) while 26.6 and
# 27.0 had shipped; App Store auto-update is deliberately OFF so a new Xcode can never land in the
# middle of CI unannounced (same lesson as rust:latest turning builds red). Nothing told anyone it
# was falling behind. This check only REPORTS; upgrading stays a deliberate, verified step.
#
# Runs on bluesea (cron). The Mac mini has no GitHub CLI and is not reachable from bluesea, but it
# is a Jenkins agent, so the check runs there through the node's script console. Findings go to one
# "[macmini-update]" issue in jrjohn/arcana-devops (body refreshed each week), closed automatically
# once nothing is pending. `mas` (Mac App Store CLI) sees Xcode because the App Store is signed in.
set -u
LOG=${LOG:-/data/projects/claude-agents-workflow/macmini-update-check.log}
REPO=jrjohn/arcana-devops
MARK="[macmini-update]"
J=http://localhost:8080/jenkins
JC="$(sudo cat /etc/ci-jenkins-cred 2>/dev/null)"
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
gh_(){ docker exec agent-task-node gh "$@" 2>/dev/null; }
[ -n "$JC" ] || { log "no Jenkins credential"; exit 0; }

GROOVY=$(cat <<'EOF'
def run = { String c ->
  def pb = new ProcessBuilder(['/bin/zsh', '-lc', c]); pb.redirectErrorStream(true)
  def p = pb.start(); def out = p.inputStream.text; p.waitFor(); return out.trim()
}
println "XCODE=" + run('xcodebuild -version | head -1')
println "MACOS=" + run('sw_vers -productVersion')
println "MAS_BEGIN"; println run('PATH=/opt/homebrew/bin:$PATH mas outdated'); println "MAS_END"
println "SU_BEGIN"; println run('softwareupdate --list 2>&1 | grep -E "^[*] Label:"'); println "SU_END"
EOF
)
C=$(mktemp); trap 'rm -f "$C"' EXIT
CR=$(curl -s -c "$C" -b "$C" -u "$JC" "$J/crumbIssuer/api/json" | python3 -c "import sys,json;print(json.load(sys.stdin)['crumb'])" 2>/dev/null)
OUT=$(curl -s -m 300 -c "$C" -b "$C" -u "$JC" -H "Jenkins-Crumb: $CR" --data-urlencode "script=$GROOVY" "$J/computer/macmini/scriptText")
if ! echo "$OUT" | grep -q "^XCODE="; then
  log "macmini unreachable or script failed: $(echo "$OUT" | head -2 | tr '\n' ' ' | cut -c1-200)"
  exit 0
fi
XCODE=$(echo "$OUT" | sed -n 's/^XCODE=//p'); MACOS=$(echo "$OUT" | sed -n 's/^MACOS=//p')
MAS=$(echo "$OUT" | sed -n '/^MAS_BEGIN$/,/^MAS_END$/p' | sed '1d;$d' | sed '/^[[:space:]]*$/d')
SU=$(echo "$OUT" | sed -n '/^SU_BEGIN$/,/^SU_END$/p' | sed '1d;$d' | sed 's/^\* Label: //' | grep -vE '^Safari' | sed '/^[[:space:]]*$/d')
log "xcode=$XCODE macos=$MACOS mas=[$(echo "$MAS" | tr '\n' ';')] su=[$(echo "$SU" | tr '\n' ';')]"

N=$(gh_ issue list -R "$REPO" --state open --search "$MARK in:title" --json number,title --jq "[.[]|select(.title|startswith(\"$MARK\"))][0].number // empty")
if [ -z "$MAS$SU" ]; then
  [ -n "$N" ] && gh_ issue close "$N" -R "$REPO" --comment "Mac mini is current ($XCODE, macOS $MACOS). Closing automatically." >/dev/null && log "closed #$N"
  exit 0
fi
BODY="Mac mini (iOS build agent) has pending updates — checked $(date '+%F').

- Current: **$XCODE**, macOS **$MACOS**
- App Store (mas outdated):
\`\`\`
${MAS:-(none)}
\`\`\`
- macOS / Command Line Tools (softwareupdate --list):
\`\`\`
${SU:-(none)}
\`\`\`

App Store auto-update is intentionally off. Upgrade deliberately when no iOS build is running:
1. \`sudo softwareupdate -i <label> -R\` for macOS (reboots; Jenkins agent reconnects on its own)
2. back up \`/Applications/Xcode.app\`, then \`mas upgrade 497799835\` (Xcode)
3. verify arcana-ios builds and tests on the new Xcode before relying on it

Refreshed weekly by macmini-update-check; closes itself when nothing is pending."
if [ -n "$N" ]; then
  gh_ issue edit "$N" -R "$REPO" --body "$BODY" >/dev/null && log "refreshed #$N"
else
  gh_ issue create -R "$REPO" --title "$MARK Mac mini has pending macOS/Xcode updates" --body "$BODY" >/dev/null && log "opened issue"
fi
