#!/bin/bash
# 每週重建 agent-task-node,裝「當下最新」的 Claude CLI —— 更新發生在 BUILD 時,
# 不在執行時(執行時自動更新已用 DISABLE_AUTOUPDATER=1 關掉,因為它會半路弄壞 symlink)。
# 由 cron 每週跑。手動也可:bash /data/projects/claude-agents-workflow/weekly-rebuild-agent.sh
set -uo pipefail
cd /data/projects/claude-agents-workflow || exit 1
P="claude-agents-workflow"; F="docker-compose.sonataflow.yml"
TS=$(date +%Y%m%d%H%M%S)

echo "[$TS] === 每週重建 agent-task-node(更新 Claude CLI）==="
# --- 1/2 daily-ci-agent(每日巡檢,也是 agent-task-node 的底層映像)---
DD=/data/projects/daily-ci-agent
docker tag daily-ci-agent:latest daily-ci-agent:prev-$TS 2>/dev/null || true
if docker build --build-arg CLAUDE_CACHE_BUST="$TS" -t daily-ci-agent:latest "$DD"; then
  (cd "$DD" && docker compose -f docker-compose.ci-agent.yml up -d daily-ci-agent)
  sleep 8
  DVER=$(docker exec daily-ci-agent sh -c 'claude --version' 2>&1 | head -1)
  if docker exec daily-ci-agent sh -c 'cd /tmp && printf hi | timeout 120 claude -p >/dev/null 2>&1'; then
    echo "[$TS] ✅ daily-ci-agent OK — $DVER"
    docker images 'daily-ci-agent:prev-*' --format '{{.Tag}}' | sort -r | tail -n +4 | \
      while read t; do docker rmi "daily-ci-agent:$t" 2>/dev/null || true; done
  else
    echo "[$TS] ❌ daily-ci-agent $DVER 失敗 —— 回滾到 prev-$TS"
    docker tag daily-ci-agent:prev-$TS daily-ci-agent:latest
    (cd "$DD" && docker compose -f docker-compose.ci-agent.yml up -d daily-ci-agent)
  fi
else
  echo "[$TS] daily-ci-agent build 失敗,保留現役不動"
fi

# --- 2/2 agent-task-node(ci-flow / merge-flow)---
# 先把現役 image 存成 rollback 標籤
docker tag agent-task-node:latest agent-task-node:prev-$TS 2>/dev/null || true

# CLAUDE_CACHE_BUST 每次不同 → 強制重跑 npm i @latest 那層,抓最新 CLI
docker build \
  --build-arg BASE_IMAGE=daily-ci-agent:latest \
  --build-arg CLAUDE_CACHE_BUST="$TS" \
  -t agent-task-node:latest ./agent-task-node || { echo "build 失敗,保留現役容器不動"; exit 1; }

docker compose -p "$P" -f "$F" up -d agent-task-node

sleep 8
VER=$(docker exec agent-task-node sh -lc 'claude --version' 2>&1 | head -1)
if docker exec agent-task-node sh -lc 'printf hi | claude -p >/dev/null 2>&1'; then
  echo "[$TS] ✅ OK — $VER,認證正常"
  # 只保留最近 3 個 rollback 標籤
  docker images 'agent-task-node:prev-*' --format '{{.Tag}}' | sort -r | tail -n +4 | \
    while read t; do docker rmi "agent-task-node:$t" 2>/dev/null || true; done
else
  echo "[$TS] ❌ 新版認證/啟動失敗 —— 回滾到 prev-$TS"
  docker tag agent-task-node:prev-$TS agent-task-node:latest
  docker compose -p "$P" -f "$F" up -d agent-task-node
  echo "[$TS] 已回滾。請人工查 claude $VER 為何失敗。"
fi
