#!/bin/bash
# apply-plugin-updates.sh — make the live Jenkins match the plugin TARGET lock
# (jenkins/plugins-installed.txt, normally bumped via plugin-update-bot PRs).
#
# ⚠ MAINTENANCE WINDOW ONLY: ends with a safeRestart (CI down ~2-4 min).
#   Refuses to run while any executor is busy.
#
# Procedure per the 'bluesea-jenkins-plugin-install-trap' lesson: download from
# updates.jenkins.io, install as .jpi (a .jpi outranks a bundled .hpi on boot),
# chown, single safeRestart at the end, poll until the API answers again.
set -euo pipefail
LOCK="${1:-/data/devops/jenkins/plugins-installed.txt}"
J="http://localhost:8080/jenkins"
JC=$(cat /etc/ci-jenkins-cred)

BUSY=$(curl -s -u "$JC" "$J/computer/api/json?tree=busyExecutors" | grep -o "[0-9]*" | head -1)
[ "${BUSY:-1}" != 0 ] && { echo "ABORT: $BUSY executor(s) busy — wait for idle"; exit 1; }

# live versions
LIVE=$(mktemp); trap 'rm -f "$LIVE"' EXIT
curl -sf -u "$JC" "$J/pluginManager/api/json?depth=1" | python3 -c "
import sys, json
for p in json.load(sys.stdin)['plugins']:
    print(p['shortName'] + ':' + str(p['version']))
" | sort > "$LIVE"

CHANGED=0
while IFS=: read -r NAME VER; do
  case "$NAME" in \#*|"") continue;; esac
  if ! grep -qx "$NAME:$VER" "$LIVE"; then
    echo "-> $NAME $(grep "^$NAME:" "$LIVE" | cut -d: -f2- || echo '(new)') => $VER"
    curl -sfL "https://updates.jenkins.io/download/plugins/$NAME/$VER/$NAME.hpi" -o "/tmp/$NAME.jpi"
    docker cp "/tmp/$NAME.jpi" "jenkins:/var/jenkins_home/plugins/$NAME.jpi"
    docker exec -u root jenkins chown jenkins:jenkins "/var/jenkins_home/plugins/$NAME.jpi"
    rm -f "/tmp/$NAME.jpi"
    CHANGED=$((CHANGED + 1))
  fi
done < "$LOCK"

[ "$CHANGED" = 0 ] && { echo "live already matches lock — nothing to do"; exit 0; }
echo "$CHANGED plugin(s) staged — safeRestart..."

CJ=$(mktemp); trap 'rm -f "$LIVE" "$CJ"' EXIT
CRUMB=$(curl -s -c "$CJ" -u "$JC" "$J/crumbIssuer/api/json" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])")
curl -s -o /dev/null -b "$CJ" -u "$JC" -H "$CRUMB" -X POST "$J/safeRestart"

for i in $(seq 1 60); do
  sleep 10
  if curl -sfm 5 -o /dev/null -u "$JC" "$J/api/json"; then
    echo "Jenkins back up after ~$((i * 10))s"
    echo "REMINDER: refresh the freeze snapshot (lock should now equal live)."
    exit 0
  fi
done
echo "Jenkins did not come back within 10 min — investigate (docker logs jenkins)"
exit 1
