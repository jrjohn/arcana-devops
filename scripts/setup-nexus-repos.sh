#!/usr/bin/env bash
set -euo pipefail

# Setup Nexus proxy repositories via REST API
# Usage: ./scripts/setup-nexus-repos.sh [NEXUS_URL] [ADMIN_PASSWORD]
#
# Default: http://127.0.0.1:8081/nexus  admin

NEXUS_URL="${1:-http://127.0.0.1:8081/nexus}"
ADMIN_PASS="${2:-admin}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[NEXUS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

API="${NEXUS_URL}/service/rest/v1"

# ── Wait for Nexus to be ready ────────────────
log "Waiting for Nexus at ${NEXUS_URL}..."
for i in $(seq 1 60); do
    if curl -sf "${API}/status" &>/dev/null; then
        log "Nexus is ready"
        break
    fi
    if [ "$i" -eq 60 ]; then
        err "Nexus did not start within 5 minutes"
        exit 1
    fi
    sleep 5
done

# ── Get initial admin password ────────────────
# On first boot, Nexus generates a random password in /nexus-data/admin.password
# After first login, this file is deleted. Try the file first, then fall back to provided password.
INIT_PASS=""
CONTAINER_PASS=$(docker exec nexus cat /nexus-data/admin.password 2>/dev/null || true)
if [ -n "$CONTAINER_PASS" ]; then
    log "Found initial admin password from container"
    INIT_PASS="$CONTAINER_PASS"

    # Change to desired password
    log "Changing admin password..."
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        -u "admin:${INIT_PASS}" \
        -X PUT "${API}/security/users/admin/change-password" \
        -H "Content-Type: text/plain" \
        -d "${ADMIN_PASS}" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        log "Admin password changed successfully"
    else
        warn "Password change returned HTTP ${HTTP_CODE} (may already be changed)"
    fi
else
    log "No initial password file found, using provided password"
fi

AUTH="admin:${ADMIN_PASS}"

# ── Verify authentication ─────────────────────
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -u "${AUTH}" "${API}/status" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "200" ]; then
    err "Authentication failed (HTTP ${HTTP_CODE}). Check admin password."
    exit 1
fi
log "Authentication verified"

# ── Accept EULA (required for Nexus 3.70+) ────
EULA_STATUS=$(curl -sf -u "${AUTH}" "${API}/system/eula" 2>/dev/null || echo '{"accepted":true}')
EULA_ACCEPTED=$(echo "$EULA_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('accepted',True))" 2>/dev/null || echo "True")
if [ "$EULA_ACCEPTED" = "False" ]; then
    log "Accepting EULA..."
    DISCLAIMER=$(echo "$EULA_STATUS" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['disclaimer']))")
    curl -sf -u "${AUTH}" -X POST "${API}/system/eula" \
        -H "Content-Type: application/json" \
        -d "{\"accepted\":true,\"disclaimer\":${DISCLAIMER}}" >/dev/null
    log "EULA accepted"
fi

# ── Enable anonymous access ───────────────────
log "Enabling anonymous access for repository reads..."
curl -sf -u "${AUTH}" -X PUT "${API}/security/anonymous" \
    -H "Content-Type: application/json" \
    -d '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}' >/dev/null

# ── Helper: create repository ─────────────────
create_repo() {
    local NAME="$1"
    local FORMAT="$2"
    local JSON="$3"

    # Check if repo already exists
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        -u "${AUTH}" "${API}/repositories/${NAME}" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        warn "Repository '${NAME}' already exists — skipping"
        return 0
    fi

    log "Creating ${FORMAT} proxy: ${NAME}..."
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        -u "${AUTH}" -X POST "${API}/repositories/${FORMAT}/proxy" \
        -H "Content-Type: application/json" \
        -d "${JSON}" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
        log "  ✓ ${NAME} created"
    else
        err "  ✗ ${NAME} failed (HTTP ${HTTP_CODE})"
    fi
}

# ── CocoaPods proxy (raw) ─────────────────────
create_repo "cocoapods-proxy" "raw" '{
  "name": "cocoapods-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": false
  },
  "proxy": {
    "remoteUrl": "https://cdn.cocoapods.org/",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "raw": {
    "contentDisposition": "ATTACHMENT"
  }
}'

# ── CocoaPods GitHub source proxy (raw) ───────
create_repo "cocoapods-github-proxy" "raw" '{
  "name": "cocoapods-github-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": false
  },
  "proxy": {
    "remoteUrl": "https://github.com/",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "raw": {
    "contentDisposition": "ATTACHMENT"
  }
}'

# ── Node.js dist proxy (raw) ─────────────────
create_repo "nodejs-dist-proxy" "raw" '{
  "name": "nodejs-dist-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": false
  },
  "proxy": {
    "remoteUrl": "https://nodejs.org/dist/",
    "contentMaxAge": -1,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "raw": {
    "contentDisposition": "ATTACHMENT"
  }
}'

# ── GitHub releases proxy (raw) ──────────────
create_repo "github-releases-proxy" "raw" '{
  "name": "github-releases-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": false
  },
  "proxy": {
    "remoteUrl": "https://github.com/",
    "contentMaxAge": -1,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "raw": {
    "contentDisposition": "ATTACHMENT"
  }
}'

# ── npm proxy ─────────────────────────────────
create_repo "npm-proxy" "npm" '{
  "name": "npm-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "proxy": {
    "remoteUrl": "https://registry.npmjs.org/",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  }
}'

# ── PyPI proxy ────────────────────────────────
create_repo "pypi-proxy" "pypi" '{
  "name": "pypi-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "proxy": {
    "remoteUrl": "https://pypi.org/",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  }
}'

# ── Maven Central proxy ──────────────────────
create_repo "maven-central-proxy" "maven" '{
  "name": "maven-central-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "proxy": {
    "remoteUrl": "https://repo1.maven.org/maven2/",
    "contentMaxAge": -1,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "maven": {
    "versionPolicy": "RELEASE",
    "layoutPolicy": "STRICT",
    "contentDisposition": "INLINE"
  }
}'

# ── NuGet proxy ───────────────────────────────
create_repo "nuget-proxy" "nuget" '{
  "name": "nuget-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "proxy": {
    "remoteUrl": "https://api.nuget.org/v3/index.json",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "nugetProxy": {
    "queryCacheItemMaxAge": 3600,
    "nugetVersion": "V3"
  }
}'

# ── Docker Hub proxy ─────────────────────────
create_repo "docker-hub-proxy" "docker" '{
  "name": "docker-hub-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "proxy": {
    "remoteUrl": "https://registry-1.docker.io",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "docker": {
    "v1Enabled": false,
    "forceBasicAuth": false
  },
  "dockerProxy": {
    "indexType": "HUB",
    "indexUrl": "https://index.docker.io/"
  }
}'

# ── SonarSource binaries proxy (raw) ─────────
create_repo "sonarsource-proxy" "raw" '{
  "name": "sonarsource-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": false
  },
  "proxy": {
    "remoteUrl": "https://binaries.sonarsource.com/",
    "contentMaxAge": -1,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "raw": {
    "contentDisposition": "ATTACHMENT"
  }
}'

# ── Go proxy ─────────────────────────────────
create_repo "go-proxy" "go" '{
  "name": "go-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "proxy": {
    "remoteUrl": "https://proxy.golang.org",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  }
}'

# ── Gradle distributions proxy (raw) ────────
create_repo "gradle-dist-proxy" "raw" '{
  "name": "gradle-dist-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": false
  },
  "proxy": {
    "remoteUrl": "https://services.gradle.org/distributions/",
    "contentMaxAge": -1,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "raw": {
    "contentDisposition": "ATTACHMENT"
  }
}'

# ── Gradle plugins proxy (maven) ────────────
create_repo "gradle-plugins-proxy" "maven" '{
  "name": "gradle-plugins-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "proxy": {
    "remoteUrl": "https://plugins.gradle.org/m2/",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "maven": {
    "versionPolicy": "RELEASE",
    "layoutPolicy": "STRICT",
    "contentDisposition": "INLINE"
  }
}'

# ── Google Maven proxy (Android) ────────────
create_repo "google-maven-proxy" "maven" '{
  "name": "google-maven-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "proxy": {
    "remoteUrl": "https://dl.google.com/dl/android/maven2/",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "maven": {
    "versionPolicy": "RELEASE",
    "layoutPolicy": "STRICT",
    "contentDisposition": "INLINE"
  }
}'

# ── Summary ───────────────────────────────────
log ""
log "Repository setup complete!"
log ""
log "Proxy repositories created:"
log "  cocoapods-proxy         → https://cdn.cocoapods.org/"
log "  cocoapods-github-proxy  → https://github.com/"
log "  nodejs-dist-proxy       → https://nodejs.org/dist/"
log "  github-releases-proxy   → https://github.com/"
log "  npm-proxy               → https://registry.npmjs.org/"
log "  pypi-proxy              → https://pypi.org/"
log "  maven-central-proxy     → https://repo1.maven.org/maven2/"
log "  nuget-proxy             → https://api.nuget.org/v3/index.json"
log "  docker-hub-proxy        → https://registry-1.docker.io"
log "  sonarsource-proxy       → https://binaries.sonarsource.com/"
log "  go-proxy                → https://proxy.golang.org"
log "  gradle-dist-proxy       → https://services.gradle.org/distributions/"
log "  gradle-plugins-proxy    → https://plugins.gradle.org/m2/"
log "  google-maven-proxy      → https://dl.google.com/dl/android/maven2/"
log ""
log "Usage examples:"
log "  npm:      npm config set registry http://172.17.0.1:8081/nexus/repository/npm-proxy/"
log "  pip:      pip install --index-url http://172.17.0.1:8081/nexus/repository/pypi-proxy/simple/ --trusted-host 172.17.0.1 <pkg>"
log "  go:       GOPROXY=http://172.17.0.1:8081/nexus/repository/go-proxy/,direct go mod download"
log "  gradle:   curl -O http://172.17.0.1:8081/nexus/repository/gradle-dist-proxy/gradle-8.10-bin.zip"
log "  nuget:    dotnet nuget add source http://172.17.0.1:8081/nexus/repository/nuget-proxy/index.json"
log ""
