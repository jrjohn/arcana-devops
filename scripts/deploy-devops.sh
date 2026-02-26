#!/usr/bin/env bash
set -euo pipefail

# Deploy DevOps stack on Bluesea (arcana.boo)
# Usage: ./scripts/deploy-bluesea.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECTS_DIR="/data/projects"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[DEPLOY]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Prerequisites ─────────────────────────────
log "Checking prerequisites..."

if ! command -v docker &>/dev/null; then
    err "Docker is not installed"
    exit 1
fi

if ! docker compose version &>/dev/null; then
    err "Docker Compose plugin is not installed"
    exit 1
fi

# Check vm.max_map_count for SonarQube
CURRENT_MAP_COUNT=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
if [ "$CURRENT_MAP_COUNT" -lt 524288 ]; then
    warn "vm.max_map_count=$CURRENT_MAP_COUNT (need >= 524288 for SonarQube)"
    log "Setting vm.max_map_count=524288..."
    sudo sysctl -w vm.max_map_count=524288
    if ! grep -q "vm.max_map_count" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.max_map_count=524288" | sudo tee -a /etc/sysctl.conf
    fi
fi

# ── .env file ─────────────────────────────────
if [ ! -f "$PROJECT_DIR/.env" ]; then
    err ".env file not found. Copy from .env.example and configure:"
    err "  cp $PROJECT_DIR/.env.example $PROJECT_DIR/.env"
    err "  # Set GITHUB_TOKEN, SONARQUBE_TOKEN, passwords, etc."
    exit 1
fi

# ── Create projects directory ─────────────────
log "Ensuring $PROJECTS_DIR exists..."
sudo mkdir -p "$PROJECTS_DIR"
sudo chown "$(whoami):$(id -g)" "$PROJECTS_DIR"

# ── Docker GID ────────────────────────────────
DOCKER_GID=$(getent group docker | cut -d: -f3)
log "Docker GID: $DOCKER_GID"
sed -i "s/^DOCKER_GID=.*/DOCKER_GID=$DOCKER_GID/" "$PROJECT_DIR/.env"

# ── QEMU for cross-platform builds ───────────
if [ ! -f /proc/sys/fs/binfmt_misc/qemu-x86_64 ] 2>/dev/null; then
    log "Installing QEMU x86_64 emulation for Android/HarmonyOS builds..."
    docker run --rm --privileged tonistiigi/binfmt --install amd64 >/dev/null 2>&1 || true
    log "QEMU x86_64 emulation installed"
fi

# ── Build custom Jenkins image ────────────────
log "Building custom Jenkins image..."
cd "$PROJECT_DIR"
docker compose build jenkins

# ── Start core services ───────────────────────
log "Starting core services (Jenkins + SonarQube)..."
docker compose up -d

# ── Start monitoring stack ────────────────────
log "Starting monitoring stack..."
docker compose -f docker-compose.monitoring.yml up -d --build

# ── Install nginx config ─────────────────────
# arcana-devops.conf is an includable snippet (location blocks only).
# It must be included inside an existing server block, NOT placed in conf.d/.
# Example: include /data/devops/nginx/arcana-devops.conf;
if [ -d /etc/nginx ]; then
    if ! grep -rq "arcana-devops.conf" /etc/nginx/ 2>/dev/null; then
        warn "Nginx config not yet included. Add this line inside your server block:"
        warn "  include $PROJECT_DIR/nginx/arcana-devops.conf;"
        warn "Then run: sudo nginx -t && sudo nginx -s reload"
    else
        log "Nginx config already included, reloading..."
        if sudo nginx -t 2>&1; then
            sudo systemctl reload nginx || sudo nginx -s reload
            log "Nginx reloaded successfully"
        else
            err "Nginx config test failed"
            exit 1
        fi
    fi
fi

# ── Health checks ─────────────────────────────
log "Waiting for services to start..."
echo -n "  Jenkins: "
for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1:8080/jenkins/login &>/dev/null; then
        echo -e "${GREEN}UP${NC}"
        break
    fi
    [ "$i" -eq 60 ] && echo -e "${RED}TIMEOUT${NC}"
    sleep 5
done

echo -n "  SonarQube: "
for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1:9000/sonarqube/api/system/status 2>/dev/null | grep -q '"status":"UP"'; then
        echo -e "${GREEN}UP${NC}"
        break
    fi
    [ "$i" -eq 60 ] && echo -e "${RED}TIMEOUT${NC}"
    sleep 5
done

echo -n "  Grafana: "
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:3000/grafana/api/health &>/dev/null; then
        echo -e "${GREEN}UP${NC}"
        break
    fi
    [ "$i" -eq 30 ] && echo -e "${RED}TIMEOUT${NC}"
    sleep 3
done

echo -n "  Prometheus: "
for i in $(seq 1 15); do
    if curl -sf http://127.0.0.1:9090/prometheus/-/healthy &>/dev/null; then
        echo -e "${GREEN}UP${NC}"
        break
    fi
    [ "$i" -eq 15 ] && echo -e "${RED}TIMEOUT${NC}"
    sleep 3
done

# ── Auto-configure SonarQube tokens ───────────
NEED_RESTART=false
if grep -q '^SONARQUBE_TOKEN=$' "$PROJECT_DIR/.env" 2>/dev/null; then
    log "Generating SonarQube analysis token (GLOBAL_ANALYSIS_TOKEN)..."
    SQ_TOKEN=$(curl -sf -u admin:admin -X POST \
        "http://127.0.0.1:9000/sonarqube/api/user_tokens/generate" \
        -d "name=jenkins-ci&type=GLOBAL_ANALYSIS_TOKEN" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || true)
    if [ -n "$SQ_TOKEN" ]; then
        sed -i "s|^SONARQUBE_TOKEN=.*|SONARQUBE_TOKEN=$SQ_TOKEN|" "$PROJECT_DIR/.env"
        log "SonarQube analysis token saved"
        NEED_RESTART=true
    else
        warn "Could not auto-generate SonarQube token (change default password first?)"
    fi
fi
if grep -q '^SONARQUBE_EXPORTER_TOKEN=$' "$PROJECT_DIR/.env" 2>/dev/null; then
    log "Generating SonarQube exporter token (USER_TOKEN)..."
    SQ_EXP_TOKEN=$(curl -sf -u admin:admin -X POST \
        "http://127.0.0.1:9000/sonarqube/api/user_tokens/generate" \
        -d "name=exporter&type=USER_TOKEN" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || true)
    if [ -n "$SQ_EXP_TOKEN" ]; then
        sed -i "s|^SONARQUBE_EXPORTER_TOKEN=.*|SONARQUBE_EXPORTER_TOKEN=$SQ_EXP_TOKEN|" "$PROJECT_DIR/.env"
        log "SonarQube exporter token saved"
        NEED_RESTART=true
    fi
fi
if [ "$NEED_RESTART" = true ]; then
    log "Recreating services to pick up new tokens..."
    docker compose up -d jenkins
    docker compose -f docker-compose.monitoring.yml up -d sonarqube-exporter
fi

# ── Summary ───────────────────────────────────
log ""
log "Deployment complete!"
log ""
log "Service URLs:"
log "  Jenkins:    https://arcana.boo/jenkins/"
log "  SonarQube:  https://arcana.boo/sonarqube/"
log "  Grafana:    https://arcana.boo/grafana/"
log "  Prometheus: https://arcana.boo/prometheus/"
log ""
log "Next steps:"
log "  1. Manually trigger all 15 pipelines once (primes SCM polling)"
log "  2. Set up JNLP agents on Mac Mini and Windows:"
log "     Mac:     scripts/setup-jnlp-agent-mac.sh"
log "     Windows: scripts/setup-jnlp-agent-windows.ps1"
log "  3. Verify at: docker ps  (expect ~12 containers)"
