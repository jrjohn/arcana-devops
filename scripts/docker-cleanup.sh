#!/bin/bash
# Docker Cleanup Script - runs when /data usage > 80%
# Cron: 0 * * * * /data/devops/scripts/docker-cleanup.sh
LOG="/var/log/docker-cleanup.log"
THRESHOLD=80
REGISTRY="http://localhost:5000"
ACCEPT="Accept: application/vnd.oci.image.index.v1+json"
KEEP_BUILDS=3

usage=$(df /data --output=pcent | tail -1 | tr -d " %")

if [ "$usage" -le "$THRESHOLD" ]; then
  exit 0
fi

echo "=== $(date) === /data at ${usage}%, threshold ${THRESHOLD}% ===" >> "$LOG"

# 1. Prune unused images
echo "[1] Pruning unused images..." >> "$LOG"
docker image prune -a -f >> "$LOG" 2>&1

# 2. Clean old registry tags (keep version + latest N build tags)
echo "[2] Cleaning old registry tags..." >> "$LOG"
for repo in $(curl -s $REGISTRY/v2/_catalog | python3 -c "import sys,json; [print(r) for r in json.load(sys.stdin).get('repositories',[])]" 2>/dev/null); do
  tags=$(curl -s $REGISTRY/v2/$repo/tags/list | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in (data.get('tags') or []):
    print(t)
" 2>/dev/null)

  [ -z "$tags" ] && continue

  build_tags=()
  while IFS= read -r tag; do
    [[ "$tag" == build-* ]] && build_tags+=("$tag")
  done <<< "$tags"

  [ ${#build_tags[@]} -le $KEEP_BUILDS ] && continue

  sorted=($(printf '%s\n' "${build_tags[@]}" | sort -t'-' -k2 -n))
  total=${#sorted[@]}
  del_build=("${sorted[@]:0:$((total-KEEP_BUILDS))}")

  for tag in "${del_build[@]}"; do
    digest=$(curl -s -I -H "$ACCEPT" "$REGISTRY/v2/$repo/manifests/$tag" 2>/dev/null | grep -i "Docker-Content-Digest" | tr -d '\r' | awk '{print $2}')
    if [ -n "$digest" ]; then
      curl -s -o /dev/null -X DELETE "$REGISTRY/v2/$repo/manifests/$digest"
      echo "  DEL $repo:$tag" >> "$LOG"
    fi
  done
done

# 3. Registry garbage collection
echo "[3] Registry garbage collection..." >> "$LOG"
docker exec registry bin/registry garbage-collect /etc/docker/registry/config.yml >> "$LOG" 2>&1

# 4. Prune build cache
echo "[4] Pruning build cache..." >> "$LOG"
docker builder prune -a -f >> "$LOG" 2>&1

# 5. Prune unused volumes
echo "[5] Pruning unused volumes..." >> "$LOG"
docker volume prune -f >> "$LOG" 2>&1

after=$(df /data --output=pcent | tail -1 | tr -d " %")
echo "=== Done: ${usage}% -> ${after}% ===" >> "$LOG"
echo "" >> "$LOG"
