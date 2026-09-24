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
# NETWORK REAPER (2026-08-08): the old "idle nets are metadata-only" belief was
# WRONG. Each idle net still holds a full /16, and the Docker default pool
# (172.17-172.31, ~15 nets) exhausts — `compose build` then dies with
# "all predefined address pools have been fully subnetted" (node-app PR-102 stuck
# a release a full day). Blanket `network prune` races builds (2026-05-29 killed
# rust main #11), so reap AGE-BASED exactly like the containers above: only
# CI-named nets, 0 attached containers, >2h old. An active build's net is minutes
# old AND has containers, so it is never touched — no race.
netout = subprocess.run(["docker","network","ls","--format","{{.Name}}"],
                        capture_output=True,text=True).stdout
for name in netout.split():
    if not re.search(r"(-pipeline-mb_|arcana-ci-)", name):
        continue
    insp = subprocess.run(["docker","network","inspect","-f",
                           "{{len .Containers}}\t{{.Created}}", name],
                          capture_output=True,text=True).stdout.strip()
    if "\t" not in insp:
        continue
    ncont, created = insp.split("\t",1)
    if ncont != "0":                       # attached to a container → in use, skip
        continue
    cm = re.match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", created.strip())
    if not cm:
        continue
    cdt = datetime.datetime.strptime(cm.group(1), "%Y-%m-%dT%H:%M:%S").replace(
        tzinfo=datetime.timezone.utc)
    # 2026-09-14: 2h was too slow on a busy day — 20+ PR/main builds inside 2h left every
    # net younger than the cutoff and the pool exhausted again (python/node main failed with
    # "fully subnetted"). 1h is still far past any build step gap; an in-use net has containers.
    if (now - cdt).total_seconds() > 3600:
        subprocess.run(["docker","network","rm",name],capture_output=True)
        print(f"reaped stale CI network {name}")
PYEOF

# ANON-VOLUME REAPER (2026-09-23): stages like `docker create -v /src -v /output ...` followed
# by `docker rm -f` (no -v) leave one anonymous volume per build. 149 of them (28G) piled up
# and /data hit 98% on 2026-09-23 — go PR-84 died with "no space left on device". Remove
# only DANGLING ANONYMOUS volumes (64-hex names, referenced by no container); named volumes
# (kogito-pgdata, gradle/cargo caches, ...) are never touched here. A running build's
# container still references its volumes, so they are not dangling.
n=0
for v in $(docker volume ls -qf dangling=true 2>/dev/null | grep -E '^[0-9a-f]{64}$'); do
  docker volume rm "$v" >/dev/null 2>&1 && n=$((n+1))
done
echo "anonymous volumes removed: $n"

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

# PR-IMAGE + LEFTOVER-TEST-CONTAINER REAPER (2026-09-24): each PR build leaves a
# `<job>_pr-<N>-test:latest` image (rust 4.5 GB, springboot/angular ~2 GB). The build-N
# rule above only matches `:build-N` tags, so these were never removed — 6 closed-PR
# images plus 4 exited test containers (angular-test-35 held one for 5 days) had eaten
# ~19 GB and /data sat at 89%. Two steps, both conservative:
#  1. exited CI test containers named `<something>-test-<N>` that finished >2h ago
#     (Jenkins normally `docker rm`s them; they survive only when a build is killed).
#  2. PR images whose Jenkins branch job is `disabled` (PR closed/merged), or that are
#     >7 days old (covers job names Jenkins cannot resolve). `docker rmi` without -f,
#     so an image still used by any container is refused and kept.
GC_DRY=${GC_DRY:-0} JC="$(cat /etc/ci-jenkins-cred 2>/dev/null)" python3 - <<'PYEOF'
import subprocess, re, datetime, os, base64, urllib.request
dry = os.environ.get("GC_DRY") == "1"
now = datetime.datetime.now(datetime.timezone.utc)
def ts(s):
    m = re.match(r"(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})", s.strip())
    return datetime.datetime.strptime(m.group(1)+" "+m.group(2), "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc) if m else None
def run(cmd):
    if dry:
        print("DRY:", " ".join(cmd)); return True
    return subprocess.run(cmd, capture_output=True, text=True).returncode == 0

# 1. leftover exited test containers
out = subprocess.run(["docker","ps","-a","--filter","status=exited","--format","{{.Names}}"],
                     capture_output=True, text=True).stdout.split()
for name in out:
    if not re.fullmatch(r"[a-z0-9-]+-test-\d+", name):
        continue
    fin = subprocess.run(["docker","inspect","-f","{{.State.FinishedAt}}",name],
                         capture_output=True, text=True).stdout
    dt = ts(fin)   # FinishedAt is UTC (RFC3339 Z)
    if dt and (now - dt).total_seconds() > 7200 and run(["docker","rm",name]):
        print(f"reaped leftover test container {name}")

# 2. PR test images of closed PRs
cred = os.environ.get("JC","").strip()
def jenkins_color(job, branch):
    if not cred: return None
    req = urllib.request.Request(f"http://localhost:8080/jenkins/job/{job}/job/{branch}/api/json?tree=color")
    req.add_header("Authorization", "Basic " + base64.b64encode(cred.encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.read().decode()
    except Exception:
        return None        # 404 / unreachable -> unknown, never "closed"
imgs = subprocess.run(["docker","images","--format","{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}"],
                      capture_output=True, text=True).stdout
for line in imgs.splitlines():
    ref, _, created = line.partition("\t")
    m = re.fullmatch(r"([a-z0-9-]+-pipeline-mb)_pr-(\d+)-[a-z0-9_-]+:latest", ref.strip())
    if not m:
        continue
    job, pr = m.group(1), m.group(2)
    color = jenkins_color(job, f"PR-{pr}")
    dt = ts(created)
    age_d = (now - dt).total_seconds()/86400 if dt else 0
    why = "PR closed (job disabled)" if color and '"disabled"' in color else ("older than 7d" if age_d > 7 else None)
    if why and run(["docker","rmi",ref.strip()]):
        print(f"removed {ref.strip()} ({why})")
PYEOF
docker image prune -f >/dev/null 2>&1

# LOG CAP (2026-09-14): docker json-file logs have no max-size on this host (daemon-wide
# log-opts would need a dockerd restart). sf-ci grew to 1.4 GB of repeated stack traces and
# cadvisor to 665 MB, helping /data hit 100%. Truncate any container log over 500 MB in place
# (the container keeps running and keeps logging); name it so the noisy source is visible.
for f in /data/docker/containers/*/*-json.log; do
  [ -f "$f" ] || continue
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [ "$sz" -gt 524288000 ]; then
    cid=$(basename "$(dirname "$f")")
    name=$(docker ps -a --no-trunc --filter "id=$cid" --format '{{.Names}}' 2>/dev/null)
    truncate -s 0 "$f" && echo "truncated $((sz/1048576)) MB log of ${name:-$cid}"
  fi
done

echo "=== $(date '+%F %T') ci-disk-gc done (free=$(free_g)G) ==="
