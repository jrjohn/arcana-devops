#!/bin/bash
# jenkins-auto-upgrade — monthly: upgrade bluesea Jenkins (core + plugins) when anything is newer,
# prove it with a real build, and put back exactly what was running if any check fails.
#
# Why (2026-10-01): the controller sat 4 months on 2.555.2 with 3 core + 9 plugin security advisories.
# The image (/data/devops/jenkins/Dockerfile, `FROM jenkins/jenkins:lts-jdk25`) only moves when someone
# rebuilds it, and plugin-update-bot's "open a PR, apply by hand later" flow stalled on its first PR (#8,
# never merged). The manual upgrade that day (2.555.2 -> 2.580.1, 66 plugins, Java 21 -> 25) needed no
# fixes and ~45s of downtime, so it is safe to automate — provided a failure restores the old state.
#
# Steps
#   1. check      current core vs the base image's core, and pending plugin updates; nothing -> exit
#   2. backup     JENKINS_HOME minus workspace -> $BACKUP, running image tagged devops-jenkins:rollback
#   3. build      new image as devops-jenkins:candidate (latest is untouched until deploy)
#   4. idle       wait for 0 busy executors, then quietDown (gives up after IDLE_MAX_MIN, changes nothing)
#   5. deploy     candidate -> latest, recreate the container, stage every plugin update, safeRestart
#   6. verify     0 failed/inactive plugins, 0 security warnings, agents that were online are back,
#                 SMOKE_JOB builds SUCCESS
#   7. rollback   on any failure in 5-6: stop, restore home + image, start, verify it came back
# The outcome is recorded as one issue in jrjohn/arcana-devops: "[jenkins-upgrade] ..." — closed right
# away on success (a history entry), left open on failure or rollback.
#
# Env: UPGRADE_DRY=1  report what would happen, change nothing
#      FORCE=1        run steps 2-7 even when nothing is newer (exercise the path)
#      FORCE_FAIL=1   make verification fail on purpose (exercise the rollback)
set -u
LOG=${LOG:-/var/log/jenkins-auto-upgrade.log}
COMPOSE_DIR=/data/devops
HOME_DIR=/opt/arcana-state/jenkins-home
BACKUP=${BACKUP:-/data/backup/jenkins-home-pre-upgrade.tgz}
SMOKE_JOB=${SMOKE_JOB:-vue-app-pipeline-mb/main}
IDLE_MAX_MIN=${IDLE_MAX_MIN:-90}
REPO=jrjohn/arcana-devops
MARK="[jenkins-upgrade]"
J=http://localhost:8080/jenkins
JC="$(sudo cat /etc/ci-jenkins-cred 2>/dev/null)"
CJ=$(mktemp); trap 'rm -f "$CJ"' EXIT

log(){ local l; l="$(date '+%F %T') $*"; echo "$l" >> "$LOG"; echo "$l" 2>/dev/null || true; }
gh_(){ docker exec agent-task-node gh "$@"; }
jget(){ curl -sfg -m 30 -u "$JC" "$J$1"; }
crumb(){ curl -s -m 30 -c "$CJ" -b "$CJ" -u "$JC" "$J/crumbIssuer/api/json" | python3 -c "import sys,json;print(json.load(sys.stdin)['crumb'])" 2>/dev/null; }
jpost(){ local c; c=$(crumb); curl -s -m 60 -o /dev/null -w '%{http_code}' -c "$CJ" -b "$CJ" -u "$JC" -H "Jenkins-Crumb: $c" -X POST "$J$1"; }
groovy(){ local c; c=$(crumb); curl -s -m "${2:-120}" -c "$CJ" -b "$CJ" -u "$JC" -H "Jenkins-Crumb: $c" --data-urlencode "script=$1" "$J/scriptText"; }
core_version(){ curl -s -m 10 -o /dev/null -D - -u "$JC" "$J/api/json" 2>/dev/null | tr -d '\r' | sed -n 's/^[Xx]-[Jj]enkins: //p'; }
uptime_s(){ groovy 'println(((System.currentTimeMillis()-java.lang.management.ManagementFactory.runtimeMXBean.startTime)/1000).toLong())' 30 | tr -dc 0-9; }
online_agents(){ jget "/computer/api/json?tree=computer[displayName,offline]" | python3 -c "import sys,json;print(' '.join(sorted(c['displayName'] for c in json.load(sys.stdin)['computer'] if not c['offline'])))"; }

wait_up(){   # until the API answers with uptime below $1 s — pass the uptime read just before the restart,
             # so the old process (whose uptime only grows) can never satisfy it
  local i u
  for i in $(seq 1 60); do
    if [ -n "$(core_version)" ]; then u=$(uptime_s); [ -n "$u" ] && [ "$u" -lt "$1" ] && return 0; fi
    sleep 10
  done
  return 1
}

report(){    # $1=title $2=body $3=close|open
  local n
  n=$(gh_ issue create -R "$REPO" --title "$MARK $1" --body "$2" 2>/dev/null | grep -o '[0-9]*$')
  [ "$3" = close ] && [ -n "$n" ] && gh_ issue close "$n" -R "$REPO" >/dev/null 2>&1
  log "reported: $1 (issue #${n:-?}, $3)"
}

# One run at a time (cron + a manual run must never deploy/roll back concurrently), and never die
# half-way because the terminal that started it went away: ignore SIGPIPE so a closed stdout only
# fails the echo, not the run (2026-10-01: an ssh-launched test lost its terminal mid-wait).
trap '' PIPE
exec 9>/var/lock/jenkins-auto-upgrade.lock
flock -n 9 || { log "another run is in progress, exiting"; exit 0; }

[ -n "$JC" ] || { log "no Jenkins credential"; exit 0; }
[ -n "$(core_version)" ] || { log "Jenkins not answering, skipping"; exit 0; }

# ---------- 1. check ----------
CUR=$(core_version)
BASE=$(sed -n 's/^FROM //p' "$COMPOSE_DIR/jenkins/Dockerfile" | head -1)
docker pull -q "$BASE" >/dev/null 2>&1 || { log "cannot pull $BASE, skipping"; exit 0; }
NEW=$(docker run --rm --entrypoint java "$BASE" -jar /usr/share/jenkins/jenkins.war --version 2>/dev/null | tail -1)
PLUG=$(groovy 'Jenkins.instance.updateCenter.sites.each{it.updateDirectlyNow(false)}; println Jenkins.instance.updateCenter.updates.size()' 300 | tr -dc 0-9)
log "check: core $CUR, $BASE has ${NEW:-?}, plugin updates ${PLUG:-?}"
[ -n "$NEW" ] && [ -n "$PLUG" ] || { log "check incomplete, skipping"; exit 0; }
if [ "$CUR" = "$NEW" ] && [ "$PLUG" = 0 ] && [ -z "${FORCE:-}" ]; then log "up to date"; exit 0; fi
[ -n "${UPGRADE_DRY:-}" ] && { log "DRY: would upgrade core $CUR -> $NEW and $PLUG plugins"; exit 0; }

# ---------- 2. backup ----------
sudo mkdir -p "$(dirname "$BACKUP")"
sudo tar -C "$(dirname "$HOME_DIR")" -czf "$BACKUP" --exclude="$(basename "$HOME_DIR")/workspace" \
  --exclude="$(basename "$HOME_DIR")/caches" "$(basename "$HOME_DIR")" 2>/dev/null
[ $? -le 1 ] && sudo tar -tzf "$BACKUP" 2>/dev/null | grep -q "jenkins-home/secrets/master.key$" \
  || { log "backup failed or incomplete, nothing changed"; report "backup failed, upgrade skipped" "Could not write a complete $BACKUP. Nothing was changed." open; exit 1; }
docker tag "$(docker inspect jenkins --format '{{.Image}}')" devops-jenkins:rollback 2>/dev/null \
  || docker tag devops-jenkins:latest devops-jenkins:rollback \
  || { log "cannot tag rollback image, nothing changed"; exit 1; }
AGENTS_BEFORE=$(online_agents)
log "backup ok ($(du -h "$BACKUP" | cut -f1)); rollback image tagged; agents online: $AGENTS_BEFORE"

# ---------- 3. build ----------
if ! docker build -q --pull -t devops-jenkins:candidate "$COMPOSE_DIR/jenkins" >/dev/null 2>>"$LOG"; then
  log "image build failed, nothing changed"
  report "image build failed, upgrade skipped" "\`docker build --pull\` of $COMPOSE_DIR/jenkins failed (see $LOG). Jenkins was not touched." open
  exit 1
fi

# ---------- 4. idle ----------
# Wait for idle FIRST, quietDown only once idle. quietDown pauses running Pipeline builds
# ("Pausing (Preparing for shutdown)"), so "quietDown, then wait for 0 busy" never ends — the 2026-10-01
# install test sat 90 min with two builds frozen at their last step and all CI queued behind it.
busy(){ jget '/computer/api/json?tree=busyExecutors' | tr -dc 0-9; }
IDLE=""
for i in $(seq 1 $((IDLE_MAX_MIN * 2))); do
  if [ "$(busy)" = 0 ]; then
    jpost /quietDown >/dev/null
    sleep 5
    [ "$(busy)" = 0 ] && { IDLE=1; break; }
    jpost /cancelQuietDown >/dev/null     # a build started in the gap: let it run, keep waiting
  fi
  sleep 30
done
if [ -z "$IDLE" ]; then
  docker rmi devops-jenkins:candidate >/dev/null 2>&1
  log "never idle in ${IDLE_MAX_MIN} min, skipped (next run retries)"
  exit 0
fi
log "idle, quietDown set"

# ---------- 5-7. deploy, verify, rollback ----------
rollback(){
  log "ROLLBACK: $1"
  docker stop jenkins >/dev/null 2>&1
  local ts; ts=$(date +%Y%m%d%H%M%S)
  sudo mv "$HOME_DIR/plugins" "$HOME_DIR/plugins.failed-$ts"
  sudo tar -C "$(dirname "$HOME_DIR")" -xzf "$BACKUP"
  docker tag devops-jenkins:rollback devops-jenkins:latest
  (cd "$COMPOSE_DIR" && docker compose -p devops up -d --no-deps --force-recreate jenkins) >/dev/null 2>&1
  local back="NO"; wait_up 900 && back="yes, $(core_version)"
  local failed; failed=$(groovy 'println Jenkins.instance.pluginManager.failedPlugins.size()' 30 | tr -dc 0-9)
  sudo rm -rf "$HOME_DIR/plugins.failed-$ts"
  log "rollback done: back up=$back failed plugins=${failed:-?}"
  report "upgrade $CUR -> $NEW rolled back" "Monthly upgrade failed and was rolled back automatically.

- Reason: **$1**
- Tried: core $CUR -> $NEW, $PLUG plugin updates
- After rollback: Jenkins up = **$back**, failed plugins = ${failed:-?}
- Backup used: \`$BACKUP\`; log: \`$LOG\`

Fix the cause, then rerun: \`sudo FORCE=1 /usr/local/bin/jenkins-auto-upgrade.sh\`" open
  exit 1
}

docker tag devops-jenkins:candidate devops-jenkins:latest
U0=$(uptime_s)
(cd "$COMPOSE_DIR" && docker compose -p devops up -d --no-deps jenkins) >/dev/null 2>>"$LOG"
wait_up "${U0:-600}" || rollback "new image did not come up within 10 min"
log "core now $(core_version)"

OUT=$(groovy 'def uc=Jenkins.instance.updateCenter; def bad=[]; uc.updates.collect{[it.name, it.deploy(false)]}.each{n,f -> if(f.get().error){bad<<n}}; println "bad="+bad.join(","); println "restart="+uc.isRestartRequiredForCompletion()' 900)
echo "$OUT" | grep -q "^bad=$" || rollback "plugin download failed: $(echo "$OUT" | sed -n 's/^bad=//p' | cut -c1-200)"
if echo "$OUT" | grep -q "^restart=true"; then
  U0=$(uptime_s)
  jpost /safeRestart >/dev/null
  wait_up "$U0" || rollback "Jenkins did not come back after the plugin restart"
fi

V=$(groovy 'def j=Jenkins.instance; def pm=j.pluginManager; def m=j.getExtensionList(jenkins.security.UpdateSiteWarningsMonitor)[0]; println "failed="+pm.failedPlugins.collect{it.name}.join(","); println "inactive="+pm.plugins.findAll{!it.active}.collect{it.shortName}.join(","); println "warnings="+(m.activeCoreWarnings.collect{it.id}+m.activePluginWarningsByPlugin.collect{k,v->k.shortName}).join(",")' 60)
for k in failed inactive warnings; do
  val=$(echo "$V" | sed -n "s/^$k=//p")
  [ -n "$val" ] && rollback "$k plugins after upgrade: $val"
done
echo "$V" | grep -q "^failed=" || rollback "could not read plugin state after upgrade"

for i in $(seq 1 18); do
  AGENTS_NOW=$(online_agents)
  missing=$(comm -23 <(tr ' ' '\n' <<<"$AGENTS_BEFORE" | sort) <(tr ' ' '\n' <<<"$AGENTS_NOW" | sort) | tr '\n' ' ')
  [ -z "${missing// }" ] && break
  sleep 10
done
[ -n "${missing// }" ] && rollback "agents did not reconnect: $missing"

SJ="/job/${SMOKE_JOB%%/*}/job/${SMOKE_JOB#*/}"
N=$(jget "$SJ/api/json?tree=nextBuildNumber" | python3 -c "import sys,json;print(json.load(sys.stdin)['nextBuildNumber'])" 2>/dev/null)
[ -n "$N" ] || rollback "smoke job $SMOKE_JOB not found"
jpost "$SJ/build" >/dev/null
R=""
for i in $(seq 1 120); do
  R=$(jget "$SJ/$N/api/json?tree=result,building" | python3 -c "import sys,json;d=json.load(sys.stdin);print('' if d['building'] else d['result'])" 2>/dev/null)
  [ -n "$R" ] && break
  sleep 15
done
[ -n "${FORCE_FAIL:-}" ] && R="FORCED_FAIL"
[ "$R" = SUCCESS ] || rollback "smoke build $SMOKE_JOB #$N result: ${R:-timeout}"

FINAL=$(core_version)
log "SUCCESS: core $CUR -> $FINAL, $PLUG plugins, smoke $SMOKE_JOB #$N green"
report "upgraded $CUR -> $FINAL" "Monthly upgrade done and verified.

- Core: $CUR -> **$FINAL** ($BASE)
- Plugins updated: $PLUG; failed / inactive / security warnings: none
- Agents back online: $AGENTS_BEFORE
- Smoke build: $SMOKE_JOB #$N **SUCCESS**
- Rollback kept until next month: image \`devops-jenkins:rollback\`, home \`$BACKUP\`" close
