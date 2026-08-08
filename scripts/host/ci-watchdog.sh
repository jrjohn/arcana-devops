#!/bin/bash
# ci-watchdog.sh — hole #1: the substrate watches itself.
#
# Last night's whole failure chain (cron silently died → 12h of nothing; disk
# filled → Built-In offline → all CI stalled) happened because NOTHING checked
# whether the system was alive and healthy. This runs every 15 min as a root
# cron on the bluesea HOST (sda / — different disk than the /data it watches, so
# it keeps working even when /data is 100% full). It self-heals what it can and
# emails (SendGrid) what it can't.
set -u
LOG=/var/log/ci-watchdog.log
REM=/usr/local/bin/ci-remediate.sh
J="http://localhost:8080/jenkins"; JC="$(cat /etc/ci-jenkins-cred 2>/dev/null)"  # user:token, chmod 600, host-only — never commit credentials
STALE_HOURS=26           # daily cron (0 9 * * *) -> >26h since last successful run = stuck (was 5: stale hourly-era threshold that false-alarmed every afternoon)
DISK_WARN_PCT=88         # /data used% that triggers a prune
KEY_FILE=/data/projects/daily-ci-agent/claude-home/.sendgrid-key
ALERTS=""
log(){ echo "$(date '+%F %T') [watchdog] $*" >> "$LOG"; }
add_alert(){ ALERTS="${ALERTS}- $*\n"; log "ALERT: $*"; }

used_pct(){ df --output=pcent /data | tail -1 | tr -dc 0-9; }

# ── check 1: daily-ci-agent container alive ────────────────────────────────
if ! docker ps --format '{{.Names}}' | grep -qx daily-ci-agent; then
  log "container daily-ci-agent NOT running -> docker start"
  docker start daily-ci-agent >/dev/null 2>&1 || true
  if ! docker ps --format '{{.Names}}' | grep -qx daily-ci-agent; then
    add_alert "daily-ci-agent container is DOWN and could not be restarted."
  fi
fi

if docker ps --format '{{.Names}}' | grep -qx daily-ci-agent; then
  # ── check 2: in-container cron file root-owned (THE bug that killed last night)
  OWN=$(docker exec daily-ci-agent stat -c '%U:%G' /etc/cron.d/daily-ci-agent 2>/dev/null)
  if [ "$OWN" != "root:root" ]; then
    log "cron.d/daily-ci-agent owned by '$OWN' (Vixie cron ignores non-root) -> chown root:root"
    docker exec daily-ci-agent chown root:root /etc/cron.d/daily-ci-agent 2>/dev/null \
      && log "cron ownership repaired" || add_alert "daily-ci-agent cron file is '$OWN' (not root) and chown failed — scheduler is dead."
  fi
  # cron daemon alive in container
  docker exec daily-ci-agent pgrep -x cron >/dev/null 2>&1 || add_alert "cron daemon not running inside daily-ci-agent container."

  # ── check 2b: pgsearchd daemon alive (vsearch/csearch route through it) ───
  # It died unnoticed for 15h on 2026-05-29 (entrypoint skipped it: crs not yet
  # in PATH at container start) → all in-container archive search broke silently.
  # No supervisor restarts it, so the watchdog owns its liveness.
  if ! docker exec daily-ci-agent pgrep -f "crs pgsearchd" >/dev/null 2>&1; then
    log "pgsearchd daemon DOWN in daily-ci-agent -> restarting (vsearch/csearch depend on it)"
    docker exec daily-ci-agent sh -c "mkdir -p /root/.cache/pgsearchd; chown -R claude-agent:claude-agent /root/.cache/pgsearchd; touch /root/claude-archive/pgsearchd.log; chown claude-agent:claude-agent /root/claude-archive/pgsearchd.log" 2>/dev/null
    docker exec -d -u claude-agent -e HOME=/root daily-ci-agent sh -c "crs pgsearchd >> /root/claude-archive/pgsearchd.log 2>&1"
    sleep 2
    docker exec daily-ci-agent test -S /root/.cache/pgsearchd/pgsearchd.sock 2>/dev/null \
      && log "pgsearchd restarted (socket up)" \
      || add_alert "pgsearchd daemon down in daily-ci-agent and restart failed — vsearch/csearch broken."
  fi

  # ── check 3: liveness — hours since last successful run ──────────────────
  LASTDONE=$(docker exec daily-ci-agent sh -c "grep 'daily-run done' /var/log/daily-run.log 2>/dev/null | tail -1" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
  if [ -n "$LASTDONE" ]; then
    AGE_H=$(( ( $(date +%s) - $(date -d "$LASTDONE" +%s) ) / 3600 ))
    log "last successful run: $LASTDONE (${AGE_H}h ago)"
    [ "$AGE_H" -gt "$STALE_HOURS" ] && add_alert "daily-ci-agent has not completed a run in ${AGE_H}h (last: $LASTDONE) — scheduler may be stuck."
  else
    log "no 'daily-run done' marker found in container log"
  fi
fi

# ── check 4: /data disk pressure ───────────────────────────────────────────
UP=$(used_pct)
log "disk /data used=${UP}%"
# pre-prune saturation alert (2026-06-05): on 6/4 /data hit 100% three times in
# 45 min and corrupted kafka's docker network endpoint (froze Data Index), yet
# NO mail went out — the old condition only checked POST-prune usage, which the
# prune always pulled back under 95%. The damaging event is the pre-prune spike;
# alert on it directly. Message kept %-free so the dedup hash stays stable
# (same alert-set max 1 mail / 6h).
if [ "${UP:-0}" -ge 95 ]; then
  add_alert "/data reached >=95% before prune — build storm is outrunning the GC. If it hits 100%, docker state corrupts (2026-06-04: kafka endpoint loss froze the workflow Data Index). See /var/log/ci-watchdog.log for the fill curve."
fi
if [ "${UP:-0}" -ge "$DISK_WARN_PCT" ]; then
  log "disk >=${DISK_WARN_PCT}% -> remediate prune-disk"
  OUT=$("$REM" prune-disk 2>&1)
  UP2=$(used_pct)
  log "post-prune disk used=${UP2}% ($OUT)"
  [ "${UP2:-0}" -ge 95 ] && add_alert "/data still ${UP2}% full after prune — manual cleanup or volume growth needed."
fi

# ── check 5: Built-In node offline (disk auto-offline) ─────────────────────
OFF=$(curl -s -u "$JC" "$J/computer/(built-in)/api/json?tree=temporarilyOffline,offlineCauseReason" 2>/dev/null)
if echo "$OFF" | grep -q '"temporarilyOffline":true'; then
  log "Built-In Node temporarilyOffline -> remediate online-builtin"
  "$REM" online-builtin >/dev/null 2>&1
  STILL=$(curl -s -u "$JC" "$J/computer/(built-in)/api/json?tree=temporarilyOffline" 2>/dev/null)
  echo "$STILL" | grep -q '"temporarilyOffline":true' && add_alert "Built-In Node still offline after remediation: $(echo "$OFF" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("offlineCauseReason",""))' 2>/dev/null)"
fi

# ── check 6: SonarQube ES stuck read-only (flood w/o release, disk now ok) ──
if docker ps --format '{{.Names}}' | grep -qx sonarqube && [ "${UP:-0}" -lt 90 ]; then
  RECENT=$(docker logs sonarqube --since 12m 2>&1 | grep -E "flood stage|releasing read-only" | tail -1)
  if echo "$RECENT" | grep -q "flood stage"; then
    log "ES shows recent flood w/o release while disk ok -> restart sonarqube"
    "$REM" restart-sonarqube >/dev/null 2>&1 || add_alert "SonarQube ES appears read-only-stuck and restart failed."
  fi
fi

# ── check 7: renovate-agent health (2026-06-05) ───────────────────────────
# The 07:00 dependency-update run failed silently (containerd lease error after
# the 6/4 disk incident) — nothing watched its rc. Alert when the last run
# failed or no successful run has landed in >26h (daily cadence + slack).
RBASE=/data/projects/renovate-agent
RRC=$(cat "$RBASE/last-rc" 2>/dev/null || echo 0)
RLS=$(cat "$RBASE/last-success" 2>/dev/null || echo 0)
if [ "$RRC" != 0 ]; then
  add_alert "renovate-agent last run FAILED (rc=$RRC) — dependency PRs are not being generated. See $RBASE/logs/."
elif [ $(( $(date +%s) - RLS )) -gt 93600 ]; then
  add_alert "renovate-agent has had no successful run in >26h — cron dead or runs hanging. See $RBASE/logs/."
fi

# ── send alert email if anything unresolved (deduped: same alert-set max 1/6h) ─
if [ -n "$ALERTS" ]; then
  STATE=/var/lib/ci-watchdog; mkdir -p "$STATE"
  H=$(printf '%s' "$ALERTS" | md5sum | cut -d' ' -f1)
  LASTH=$(cat "$STATE/last-alert-hash" 2>/dev/null || echo none)
  LASTT=$(cat "$STATE/last-alert-time" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [ "$H" = "$LASTH" ] && [ $((NOW - LASTT)) -lt 21600 ]; then
    log "alerts unchanged and emailed <6h ago -> suppress (no spam)"
    KEY=""   # skip send
  else
    KEY=$(cat "$KEY_FILE" 2>/dev/null)
    echo "$H" > "$STATE/last-alert-hash"; echo "$NOW" > "$STATE/last-alert-time"
  fi
  if [ -n "$KEY" ]; then
    SENDGRID_KEY="$KEY" python3 - "$ALERTS" <<'PY'
import os,sys,json,urllib.request
body="Arcana CI watchdog detected issues on bluesea:\n\n"+sys.argv[1].replace("\\n","\n")+"\nSee /var/log/ci-watchdog.log on bluesea."
payload={"personalizations":[{"to":[{"email":"jr.johnchang@gmail.com"}]}],
 "from":{"email":"ci@arcana.boo","name":"Arcana CI Watchdog"},
 "subject":"[arcana-ci] watchdog alert — CI substrate needs attention",
 "content":[{"type":"text/plain","value":body}]}
try:
    req=urllib.request.Request("https://api.sendgrid.com/v3/mail/send",
        data=json.dumps(payload).encode(),
        headers={"Authorization":"Bearer "+os.environ["SENDGRID_KEY"],"Content-Type":"application/json"})
    r=urllib.request.urlopen(req,timeout=20); print("[watchdog] alert email HTTP",r.status)
except Exception as e: print("[watchdog] alert email FAILED",e)
PY
  else
    log "have alerts but no SendGrid key at $KEY_FILE"
  fi
fi
log "watchdog tick done (used=${UP}% alerts=$( [ -n "$ALERTS" ] && echo yes || echo none ))"
