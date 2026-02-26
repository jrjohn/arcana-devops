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
if [ -d /etc/nginx ]; then
    log "Installing nginx config..."
    sudo cp "$PROJECT_DIR/nginx/arcana-devops.conf" /etc/nginx/conf.d/arcana-devops.conf
    if sudo nginx -t 2>&1; then
        sudo systemctl reload nginx
        log "Nginx reloaded successfully"
    else
        err "Nginx config test failed — check /etc/nginx/conf.d/arcana-devops.conf"
        exit 1
    fi
else
    warn "Nginx not found. Install the config manually:"
    warn "  sudo cp $PROJECT_DIR/nginx/arcana-devops.conf /etc/nginx/conf.d/"
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
