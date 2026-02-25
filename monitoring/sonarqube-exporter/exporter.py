"""SonarQube Prometheus Exporter — polls SonarQube Web API and exposes metrics."""

import os
import sys
import time
import logging
import requests
from prometheus_client import start_http_server, Gauge

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

SONARQUBE_URL = os.environ.get("SONARQUBE_URL", "http://sonarqube:9000")
SONARQUBE_TOKEN = os.environ.get("SONARQUBE_TOKEN", "")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9101"))

# Metric keys to fetch from SonarQube
METRIC_KEYS = [
    "bugs", "vulnerabilities", "security_hotspots",
    "code_smells", "coverage", "duplicated_lines_density",
    "ncloc", "sqale_index",  # technical debt in minutes
    "reliability_rating", "security_rating", "sqale_rating",
    "alert_status",  # quality gate: 1=OK, 2=WARN, 3=ERROR
]

# Prometheus gauges
gauges = {}
for key in METRIC_KEYS:
    gauges[key] = Gauge(
        f"sonarqube_{key}",
        f"SonarQube metric: {key}",
        ["project"],
    )

sonarqube_up = Gauge("sonarqube_exporter_up", "Whether SonarQube is reachable")

RATING_MAP = {"1.0": 1, "2.0": 2, "3.0": 3, "4.0": 4, "5.0": 5}
GATE_MAP = {"OK": 1, "WARN": 2, "ERROR": 3}


def fetch_projects(session):
    """Return list of project keys."""
    url = f"{SONARQUBE_URL}/api/projects/search"
    params = {"ps": 500}
    resp = session.get(url, params=params, timeout=30)
    resp.raise_for_status()
    return [c["key"] for c in resp.json().get("components", [])]


def fetch_measures(session, project_key):
    """Return dict of metric_key -> value for a project."""
    url = f"{SONARQUBE_URL}/api/measures/component"
    params = {
        "component": project_key,
        "metricKeys": ",".join(METRIC_KEYS),
    }
    resp = session.get(url, params=params, timeout=30)
    resp.raise_for_status()
    measures = {}
    for m in resp.json().get("component", {}).get("measures", []):
        measures[m["metric"]] = m["value"]
    return measures


def update_metrics(session):
    projects = fetch_projects(session)
    log.info("Found %d projects", len(projects))

    for project_key in projects:
        measures = fetch_measures(session, project_key)
        for key in METRIC_KEYS:
            val = measures.get(key)
            if val is None:
                continue
            if key == "alert_status":
                numeric = GATE_MAP.get(val, 0)
            elif key in ("reliability_rating", "security_rating", "sqale_rating"):
                numeric = RATING_MAP.get(val, float(val))
            else:
                numeric = float(val)
            gauges[key].labels(project=project_key).set(numeric)

    sonarqube_up.set(1)


def main():
    if not SONARQUBE_TOKEN:
        log.warning("SONARQUBE_TOKEN not set — waiting until configured")

    session = requests.Session()
    if SONARQUBE_TOKEN:
        session.auth = (SONARQUBE_TOKEN, "")

    start_http_server(METRICS_PORT)
    log.info("Exporter listening on :%d, polling %s every %ds",
             METRICS_PORT, SONARQUBE_URL, POLL_INTERVAL)

    while True:
        if not SONARQUBE_TOKEN:
            sonarqube_up.set(0)
            time.sleep(POLL_INTERVAL)
            continue
        try:
            update_metrics(session)
        except Exception:
            log.exception("Failed to fetch SonarQube metrics")
            sonarqube_up.set(0)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
