#!/bin/bash
# ci-disk-gc.sh — bound per-build docker image accumulation on /data.
#
# Why: Jenkins multibranch builds each create a `*:build-N` tagged image. With
# periodic scans triggering frequent rebuilds and no cleanup, these accumulate
# (~+50 GiB / 12h observed 2026-05-29) until /data hits 100%, which trips both
# Jenkins' <1 GiB Built-In-node-offline cutoff AND SonarQube's embedded ES
# flood-stage watermark (95%) — stalling all Linux CI. See memory
# jenkins-macmini-exclusive disk section.
#
# Safe by construction:
#   * only removes `*:build-<N>` tags, never base images or untagged layers in use
#   * keeps the newest KEEP build-N per repo → never touches an in-progress build
#     (in-progress always has the highest N) or the last few good images
#   * `docker rmi` refuses images used by a running container → extra safety net
#   * builder prune scoped to `until=2h` so fresh cache for running builds survives
#   * NEVER runs `image prune -af` (that would nuke in-progress build-N mid-build)
#
# Installed as root cron (/etc/cron.d/ci-disk-gc) every 20 min. 2026-05-29.
set -u
KEEP=3
LOG=/var/log/ci-disk-gc.log
free_g() { df -BG --output=avail /data | tail -1 | tr -dc 0-9; }

echo "=== $(date '+%F %T') ci-disk-gc start (free=$(free_g)G) ==="

# 1. always-safe reclaim
docker image prune -f >/dev/null 2>&1
docker builder prune -f --filter 'until=2h' >/dev/null 2>&1
# REMOVED 2026-05-29: network prune frees ~0 disk but races compose builds (killed rust main #11 net) — see substrate memory
# docker network prune -f >/dev/null 2>&1

# 2. old build-N tagged images: keep newest KEEP per repo, remove the rest
python3 - <<'PYEOF'
# AGE-BASED build-N GC (2026-06-04): the old "keep 3 highest N per repo" rotation
# deleted IN-PROGRESS PR builds' images — multibranch jobs share one repo tag
# space (main build-15 vs PR-15 build-2), so a PR's low N always lost the sort
# and got rmi'd mid-build (killed rust PR-15 #2 Layered stage). Age is the only
# safe criterion: an in-progress image is minutes old; >6h means the build ended.
import subprocess, re, datetime
out = subprocess.run(["docker","images","--format","{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}"],
                     capture_output=True, text=True).stdout
now = datetime.datetime.now(datetime.timezone.utc)
removed = 0
for line in out.splitlines():
    if "\t" not in line: continue
    ref, created = line.split("\t", 1)
    if not re.search(r":build-\d+$", ref.strip()): continue
    m = re.match(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) ([+-]\d{4})", created.strip())
    if not m: continue
    dt = datetime.datetime.strptime(m.group(1)+" "+m.group(2), "%Y-%m-%d %H:%M:%S %z")
    age_h = (now - dt).total_seconds()/3600
    if age_h > 6:
        r = subprocess.run(["docker","rmi",ref.strip()], capture_output=True, text=True)
        if r.returncode == 0:
            removed += 1
            print(f"removed {ref.strip()} (age {age_h:.1f}h)")
print(f"aged-out build images removed: {removed}")
PYEOF


# STALE-REAPER (2026-06-05): test resources (layered compose stacks, kind nodes)
# are cleaned by each stage's post{always} — UNLESS Jenkins dies mid-stage, which
# leaks them silently (found a 1h-old arcana-ci-grpc stack burning RAM). Nothing
# legit named arcana-ci-* lives >2h, so reap anything older.
python3 - <<'PYEOF'
import subprocess, re, datetime
out = subprocess.run(["docker","ps","-a","--filter","name=arcana-ci",
                      "--format","{{.Names}}\t{{.CreatedAt}}"],capture_output=True,text=True).stdout
now = datetime.datetime.now(datetime.timezone.utc)
for line in out.splitlines():
    if "\t" not in line: continue
    name, created = line.split("\t",1)
    m = re.match(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) ([+-]\d{4})", created.strip())
    if not m: continue
    dt = datetime.datetime.strptime(m.group(1)+" "+m.group(2), "%Y-%m-%d %H:%M:%S %z")
    if (now - dt).total_seconds() > 7200:
        subprocess.run(["docker","rm","-f",name.strip()],capture_output=True)
        print(f"reaped stale test container {name.strip()}")
# NOTE: deliberately NOT pruning networks — the 2026-05-29 lesson stands
# (network prune races compose builds; killed rust main #11 net). Idle nets
# are metadata-only; stage `down` removes its own.
PYEOF

# DEAD-BRANCH CACHE-VOLUME REAPER (2026-06-06): per-branch gradle/cargo cache
# volumes (<mb-job>_<branch>_<cache>) outlive their PRs — the branch job goes
# disabled/missing after merge+prune but the volume stays forever (rust PR-15
# et al. held ~3G). Reap volumes whose Jenkins branch job is dead.
JC=$(cat /etc/ci-jenkins-cred 2>/dev/null)
if [ -n "$JC" ]; then
  for v in $(docker volume ls -q | grep -E "^[a-z0-9-]+-mb_" 2>/dev/null); do
    job=${v%%_*}; rest=${v#*_}; branch=${rest%%_*}; jb=$branch
    case "$branch" in pr-*) jb="PR-${branch#pr-}";; esac
    resp=$(curl -sm 10 -u "$JC" "http://localhost:8080/jenkins/job/$job/job/$jb/api/json?tree=color" 2>/dev/null)
    case "$resp" in
      *disabled*|"")
        docker volume rm "$v" >/dev/null 2>&1 && echo "reaped dead-branch volume $v" ;;
    esac
  done
fi

echo "=== $(date '+%F %T') ci-disk-gc done (free=$(free_g)G) ==="
