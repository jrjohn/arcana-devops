# Jenkins DevOps Starter Kit

Production-tested Jenkins CI/CD environment with 15 pre-built pipelines, SonarQube code analysis, Docker Registry, and a full monitoring stack (Prometheus + Grafana + Loki). One command to deploy.

**15 pipelines tested and verified** across Go, Rust, Vue, .NET, Spring Boot, Python/Flask, Node.js/Express, React, Angular, ESP32, STM32, Android, HarmonyOS, iOS, and Windows — covering web, cloud, embedded, and mobile platforms.

---

## Quick Start

### Prerequisites

- Docker Engine 24+
- Docker Compose v2

### 1. Clone and configure

```bash
git clone https://github.com/anthropics/devops-starter-kit.git
cd devops-starter-kit
cp .env.example .env
```

### 2. Start core services

```bash
docker compose up -d
```

Wait ~2 minutes for Jenkins to initialize, then:

| Service | URL | Credentials |
|---------|-----|-------------|
| Jenkins | http://localhost:8080 | admin / admin |
| SonarQube | http://localhost:9000 | admin / admin |
| Registry | http://localhost:5000/v2/_catalog | — |

### 3. (Optional) Start monitoring stack

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d
```

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | — |
| Pushgateway | http://localhost:9091 | — |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Docker Host                              │
│                                                                 │
│  ┌──────────┐  ┌───────────┐  ┌──────────┐                     │
│  │ Jenkins  │  │ SonarQube │  │ Registry │   Core Services      │
│  │  :8080   │  │   :9000   │  │  :5000   │                     │
│  └────┬─────┘  └─────┬─────┘  └──────────┘                     │
│       │              │                                          │
│  ┌────┴──────────────┴──────────────────────────────────┐       │
│  │                Monitoring Stack (optional)            │       │
│  │                                                      │       │
│  │  ┌────────────┐  ┌─────────┐  ┌──────────────────┐  │       │
│  │  │ Prometheus │  │ Grafana │  │      Loki        │  │       │
│  │  │   :9090    │  │  :3000  │  │     :3100        │  │       │
│  │  └──────┬─────┘  └────┬────┘  └────────┬─────────┘  │       │
│  │         │             │               │              │       │
│  │  ┌──────┴──────────┐  │  ┌────────────┴───────────┐  │       │
│  │  │  Exporters      │  │  │  Promtail (log agent)  │  │       │
│  │  │  - Node         │  │  └────────────────────────┘  │       │
│  │  │  - cAdvisor     │  │                              │       │
│  │  │  - SonarQube    │  │  ┌────────────────────────┐  │       │
│  │  │  - Pushgateway  │  │  │ Jenkins Commit Exporter│  │       │
│  │  └─────────────────┘  │  └────────────────────────┘  │       │
│  └───────────────────────┴──────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────┘
```

---

## Pipelines

All 15 pipelines are pre-loaded via Groovy init script on first boot:

| # | Pipeline | Type | Platform |
|---|----------|------|----------|
| 1 | go-app-pipeline | Docker compose build + push | Cloud / Web |
| 2 | rust-app-pipeline | Docker compose build + push | Cloud / Web |
| 3 | vue-app-pipeline | Docker compose build + push | Frontend |
| 4 | dotnet-app-pipeline | Docker compose build + push | Cloud / Web |
| 5 | springboot-app-pipeline | Docker compose build + push | Cloud / Web |
| 6 | python-app-pipeline | Docker compose build + push | Cloud / Web |
| 7 | node-app-pipeline | Docker compose build + push | Cloud / Web |
| 8 | react-app-pipeline | Docker compose build + push | Frontend |
| 9 | angular-app-pipeline | Docker compose build + push | Frontend |
| 10 | esp32-app-pipeline | Docker compose run (embedded) | Embedded |
| 11 | stm32-app-pipeline | Docker compose build | Embedded |
| 12 | android-app-pipeline | Docker compose build + run (amd64) | Mobile |
| 13 | harmonyos-app-pipeline | Docker compose build + run (amd64) | Mobile |
| 14 | ios-app | Swift build + test (Mac agent) | Mobile |
| 15 | windows-app-pipeline | dotnet build + test (Windows agent) | Desktop |

> **Note:** iOS and Windows pipelines require dedicated agents (Mac Mini / Windows machine). See [Adding SSH Agents](#adding-ssh-agents) below.

---

## Monitoring Dashboards

Five pre-loaded Grafana dashboards in the **DevOps Starter Kit** folder:

| Dashboard | Description |
|-----------|-------------|
| **Jenkins CI/CD** | Build success rate, duration trends, pipeline comparison, commit author activity |
| **SonarQube Code Quality** | Bugs, code smells, coverage trends, LOC by language |
| **SonarQube Security** | Vulnerabilities, hotspots, security rating trends |
| **Docker Host** | CPU, memory, disk I/O, network (Node Exporter) |
| **Container Metrics** | Per-container CPU, memory, network I/O (cAdvisor) |

### SonarQube Token Setup

For SonarQube dashboards to display data:

1. Login to SonarQube (http://localhost:9000)
2. Go to **My Account** > **Security** > **Generate Token**
3. Add the token to `.env`:
   ```
   SONARQUBE_TOKEN=squ_xxxxxxxxxxxxxxxxxxxx
   ```
4. Restart the monitoring stack

---

## Customization

### Adding a New Pipeline

1. Create a Jenkins pipeline config XML (use any existing file in `jobs/` as a template)
2. Save it to `jobs/my-new-pipeline.xml`
3. Restart Jenkins — the Groovy init script will auto-create the job

### Changing the Docker Registry

Edit `.env`:
```env
DOCKER_REGISTRY=your-registry.example.com:5000
```

### Adding SSH Agents

For iOS (Mac) or Windows pipelines, configure agents in Jenkins UI:

1. **Manage Jenkins** > **Nodes** > **New Node**
2. Set labels: `macos` (for iOS) or `windows` (for Windows)
3. Configure SSH credentials for the agent machine
4. The corresponding pipeline will automatically use the labeled agent

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `JENKINS_ADMIN_PASSWORD` | `admin` | Jenkins admin password |
| `DOCKER_GID` | `999` | Docker group ID on host (run `getent group docker \| cut -d: -f3`) |
| `TZ` | `Asia/Taipei` | Timezone |
| `DOCKER_REGISTRY` | `localhost:5000` | Docker registry address |
| `SONAR_DB_USER` | `sonarqube` | SonarQube PostgreSQL user |
| `SONAR_DB_PASSWORD` | `sonarqube` | SonarQube PostgreSQL password |
| `GRAFANA_ADMIN_USER` | `admin` | Grafana admin user |
| `GRAFANA_ADMIN_PASSWORD` | `admin` | Grafana admin password |
| `SONARQUBE_TOKEN` | *(empty)* | SonarQube API token for exporter |

---

## Troubleshooting

### Docker GID Mismatch

If Jenkins cannot access Docker:
```bash
# Find your Docker group ID
getent group docker | cut -d: -f3
# Update .env
echo "DOCKER_GID=<your-gid>" >> .env
docker compose up -d
```

### ARM64 / Apple Silicon

Most images support ARM64 natively. For Android and HarmonyOS pipelines, QEMU x86_64 emulation is used automatically (`platform: linux/amd64` in their compose files).

### SonarQube Exporter on ARM64

The `ekino/sonarqube-exporter` image may not have ARM64 builds. If it fails to start, you can comment it out in `docker-compose.monitoring.yml` — the other dashboards will still work.

### First Boot is Slow

Jenkins needs to install plugins on first startup. This typically takes 2-5 minutes. Check progress:
```bash
docker compose logs -f jenkins
```

### Memory Requirements

Recommended minimum: **4 GB RAM** for core services, **8 GB RAM** with monitoring stack.

If SonarQube fails with `vm.max_map_count` error:
```bash
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
```

### Pipeline Paths

The pre-loaded pipeline XMLs reference original project paths from the test environment. You will need to modify the `dir()` paths in each pipeline's Jenkinsfile script to point to your own project locations, or switch to SCM-based checkout.

---

## Sample Project

A minimal Go app is included in `samples/go-app/` for testing the pipeline setup:

```bash
cd samples/go-app
docker compose -f docker-compose.ci.yml build
docker compose -f docker-compose.ci.yml push  # pushes to local registry
```

---

## License

[MIT](LICENSE)
