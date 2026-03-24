#!/bin/bash
# Docker Cleanup Script — daily cleanup of images, registry, cache, volumes
# Cron: 0 3 * * * /data/devops/scripts/docker-cleanup.sh
LOG="/data/devops/logs/docker-cleanup.log"
REGISTRY="http://localhost:5000"
ACCEPT="Accept: application/vnd.oci.image.index.v1+json"
KEEP_BUILDS=3

# Log rotation (keep last 500 lines)
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 500 ]; then
  tail -200 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

usage=$(df /data --output=pcent | tail -1 | tr -d " %")
echo "=== $(date) === /data at ${usage}% ===" >> "$LOG"

# 1. Clean old registry tags (keep version + latest N build tags)
echo "[1] Cleaning old registry tags..." >> "$LOG"
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

# 2. Registry garbage collection (remove unreferenced blobs)
echo "[2] Registry garbage collection..." >> "$LOG"
docker exec registry bin/registry garbage-collect /etc/docker/registry/config.yml --delete-untagged >> "$LOG" 2>&1

# 3. Prune unused images (older than 24h to avoid deleting active builds)
echo "[3] Pruning unused images..." >> "$LOG"
docker image prune -a -f --filter 'until=24h' >> "$LOG" 2>&1

# 4. Prune build cache
echo "[4] Pruning build cache..." >> "$LOG"
docker builder prune -a -f >> "$LOG" 2>&1

# 5. Prune unused volumes
echo "[5] Pruning unused volumes..." >> "$LOG"
docker volume prune -f >> "$LOG" 2>&1

after=$(df /data --output=pcent | tail -1 | tr -d " %")
echo "=== Done: ${usage}% -> ${after}% ===" >> "$LOG"
