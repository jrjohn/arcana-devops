#!/bin/bash
# ci-remediate.sh <action> — white-listed CI-substrate remediation actions.
#
# Single source of truth for "repair the substrate" ops. Two callers:
#   * ci-watchdog.sh        — autonomous, scheduled, health-triggered (hole #1)
#   * ci-remediate-spool.sh — on-demand, requested by the daily-ci-agent, which
#                             runs as uid 1001 with NO docker/root. This is the
#                             least-privilege actuation channel (hole #2): the
#                             agent can ask for these exact actions and nothing
#                             else; the host validates + executes + audits.
#
# Runs as root on the bluesea HOST (lives on sda / — a different disk than the
# /data it repairs, so it survives /data filling). Each action idempotent+logged.
set -u
J="http://localhost:8080/jenkins"
JC="$(cat /etc/ci-jenkins-cred 2>/dev/null)"  # user:token, chmod 600, host-only — never commit credentials
LOG=/var/log/ci-remediate.log
log(){ echo "$(date '+%F %T') [remediate] $*" >> "$LOG"; }
free_g(){ df -BG --output=avail /data | tail -1 | tr -dc 0-9; }
builds_running(){ curl -s -u "$JC" "$J/computer/api/json" 2>/dev/null | python3 -c "import sys,json;print(sum(1 for c in json.load(sys.stdin)['computer'] for e in c.get('executors',[]) if e.get('currentExecutable')))" 2>/dev/null || echo 1; }
jpost(){ # jpost <path> ; POST with crumb+cookie
  local cj; cj=$(mktemp)
  local cr; cr=$(curl -s -c "$cj" -u "$JC" "$J/crumbIssuer/api/json" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['crumb'])" 2>/dev/null)
  curl -s -b "$cj" -u "$JC" -H "Jenkins-Crumb:$cr" "$@" ; rc=$?
  rm -f "$cj"; return $rc
}

case "${1:-}" in
  prune-disk)
    log "prune-disk start free=$(free_g)G"
    /usr/local/bin/ci-disk-gc.sh >/dev/null 2>&1 || true
    docker image prune -f >/dev/null 2>&1
    docker builder prune -f >/dev/null 2>&1
    # REMOVED 2026-05-29: network prune frees ~0 disk but races compose builds (killed rust main #11 net)
    # docker network prune -f >/dev/null 2>&1
    if [ "$(free_g)" -lt 15 ] && [ "$(builds_running)" = "0" ]; then
      log "prune-disk: <15G free and 0 builds running -> image prune -af"
      docker image prune -af >/dev/null 2>&1
    fi
    log "prune-disk done free=$(free_g)G"
    echo "free=$(free_g)G"
    ;;
  online-builtin)
    OFF=$(curl -s -u "$JC" "$J/computer/(built-in)/api/json?tree=temporarilyOffline" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('temporarilyOffline'))" 2>/dev/null)
    if [ "$OFF" = "True" ] && [ "$(free_g)" -ge 10 ]; then
      jpost --data-urlencode 'script=jenkins.model.Jenkins.instance.toComputer().setTemporarilyOffline(false, null); println("online")' "$J/scriptText" >/dev/null 2>&1
      log "online-builtin: forced online (was offline, free=$(free_g)G)"
      echo "online"
    else
      log "online-builtin: no-op (temporarilyOffline=$OFF free=$(free_g)G)"
      echo "noop offline=$OFF free=$(free_g)G"
    fi
    ;;
  restart-sonarqube)
    # clears a stuck ES read-only block when disk freed but block didn't auto-release
    docker restart sonarqube >/dev/null 2>&1 && { log "restart-sonarqube done"; echo "restarted"; } || { log "restart-sonarqube FAILED"; echo "failed"; exit 1; }
    ;;
  *)
    log "UNKNOWN action: '${1:-}' (allowed: prune-disk online-builtin restart-sonarqube)"
    echo "unknown-action"; exit 2
    ;;
esac
