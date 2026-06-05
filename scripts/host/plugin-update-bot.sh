#!/bin/bash
# plugin-update-bot.sh — Renovate-style weekly PR for Jenkins plugin updates.
#
# Reads the live Jenkins update-center diff (installed vs available) and opens
# a PR on arcana-devops bumping jenkins/plugins-installed.txt to the proposed
# versions. That file is the TARGET lock: merging the PR expresses intent;
# scripts/host/apply-plugin-updates.sh makes the live instance match it
# (maintenance window — it ends in a safeRestart). 2026-06-05.
#
# Cron: /etc/cron.d/plugin-update-bot (Mon 06:30, after the 03:00 cleanup,
# before the 07:00 renovate run so both PRs land in the same morning review).
set -euo pipefail
J="http://localhost:8080/jenkins"
JC=$(cat /etc/ci-jenkins-cred)
TOKEN=$(grep -oP '^RENOVATE_TOKEN=\K.*' /data/projects/renovate-agent/.env)
REPO="jrjohn/arcana-devops"
BRANCH="jenkins-plugin-updates"
LOG=/var/log/plugin-update-bot.log
exec >> "$LOG" 2>&1
echo "=== $(date '+%F %T') plugin-update-bot start ==="

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# 1. proposed target list = live versions overridden by update-center updates
curl -sf -u "$JC" "$J/pluginManager/api/json?depth=1" > "$WORK/installed.json"
curl -sf -u "$JC" "$J/updateCenter/site/default/api/json?depth=2" > "$WORK/uc.json"
python3 - "$WORK" <<'PY'
import json, sys
w = sys.argv[1]
installed = json.load(open(w + "/installed.json"))["plugins"]
updates = {u["name"]: u["version"] for u in json.load(open(w + "/uc.json"))["updates"]}
lines, n = [], 0
for p in sorted(installed, key=lambda x: x["shortName"]):
    name, ver = p["shortName"], str(p["version"])
    if name in updates and updates[name] != ver:
        ver = updates[name]; n += 1
    lines.append("%s:%s" % (name, ver))
open(w + "/target.txt", "w").write("\n".join(lines) + "\n")
open(w + "/count.txt", "w").write(str(n))
PY
N=$(cat "$WORK/count.txt")
if [ "$N" = 0 ]; then echo "no plugin updates available — done"; exit 0; fi
echo "$N plugin updates proposed"

# 2. branch + commit (force-updated weekly; one rolling PR like Renovate)
git clone -q --depth 1 "https://x-access-token:${TOKEN}@github.com/${REPO}.git" "$WORK/repo"
cd "$WORK/repo"
git checkout -q -B "$BRANCH"
{
  echo "# Jenkins plugin TARGET lock — desired full resolved set incl. transitive deps."
  echo "# plugins.txt is the top-level manifest; apply this lock to the live instance"
  echo "# with scripts/host/apply-plugin-updates.sh (maintenance window: safeRestart)."
  echo "# Proposed by plugin-update-bot $(date '+%F') from the live update center ($N updates)."
  cat "$WORK/target.txt"
} > jenkins/plugins-installed.txt
if git diff --quiet; then echo "no change vs main — done"; exit 0; fi
git -c user.name="plugin-update-bot" -c user.email="ci@arcana.boo" \
    commit -qam "chore(jenkins): plugin updates $(date '+%F') — $N plugins"
git push -qf origin "$BRANCH"

# 3. open PR unless one is already open for the branch
OPEN=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "https://api.github.com/repos/$REPO/pulls?head=jrjohn:$BRANCH&state=open" \
  | python3 -c "import sys,json;print(len(json.load(sys.stdin)))")
if [ "$OPEN" = 0 ]; then
  printf '{"title":"chore(jenkins): plugin updates — %s plugins (%s)","head":"%s","base":"main","body":"Weekly Jenkins plugin update proposal generated from the live update center by plugin-update-bot.\\n\\nMerging = intent only. Apply in a maintenance window with `sudo scripts/host/apply-plugin-updates.sh` (downloads .jpi, safeRestart, polls back up, then refresh the freeze snapshot)."}' \
    "$N" "$(date '+%F')" "$BRANCH" > "$WORK/pr.json"
  curl -sf -H "Authorization: Bearer $TOKEN" -X POST \
    "https://api.github.com/repos/$REPO/pulls" -d @"$WORK/pr.json" \
    | python3 -c "import sys,json;print('opened PR #%s' % json.load(sys.stdin)['number'])"
else
  echo "PR already open — branch force-updated"
fi
echo "=== $(date '+%F %T') plugin-update-bot done ==="
