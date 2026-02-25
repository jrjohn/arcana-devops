"""Jenkins Commit Exporter — polls Jenkins API for commit authors and pushes metrics to Pushgateway."""

import os
import time
import logging
import requests
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

JENKINS_URL = os.environ.get("JENKINS_URL", "http://jenkins:8080")
JENKINS_USER = os.environ.get("JENKINS_USER", "admin")
JENKINS_PASSWORD = os.environ.get("JENKINS_PASSWORD", "admin")
PUSHGATEWAY_URL = os.environ.get("PUSHGATEWAY_URL", "http://pushgateway:9091")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))

API_PATH = "/api/json?tree=jobs[name,builds[number,changeSets[items[author[fullName],msg,timestamp]]]{0,10}]"


def fetch_commit_data():
    """Fetch commit data from Jenkins API."""
    url = JENKINS_URL.rstrip("/") + API_PATH
    try:
        resp = requests.get(url, auth=(JENKINS_USER, JENKINS_PASSWORD), timeout=30)
        resp.raise_for_status()
        return resp.json()
    except Exception as e:
        logger.error("Failed to fetch Jenkins API: %s", e)
        return None


def process_and_push(data):
    """Extract commit authors from Jenkins data and push to Pushgateway."""
    registry = CollectorRegistry()

    commits_total = Gauge(
        "jenkins_commits_total",
        "Total commits per job and author",
        ["job", "author"],
        registry=registry,
    )

    commits_by_build = Gauge(
        "jenkins_commits_by_build",
        "Commits per build, job, and author",
        ["job", "build", "author"],
        registry=registry,
    )

    for job in data.get("jobs", []):
        job_name = job.get("name", "unknown")
        author_totals = {}

        for build in job.get("builds", []):
            build_number = str(build.get("number", "0"))
            build_authors = {}

            for change_set in build.get("changeSets", []):
                for item in change_set.get("items", []):
                    author = item.get("author", {}).get("fullName", "unknown")
                    build_authors[author] = build_authors.get(author, 0) + 1
                    author_totals[author] = author_totals.get(author, 0) + 1

            for author, count in build_authors.items():
                commits_by_build.labels(job=job_name, build=build_number, author=author).set(count)

        for author, count in author_totals.items():
            commits_total.labels(job=job_name, author=author).set(count)

    try:
        push_to_gateway(PUSHGATEWAY_URL, job="jenkins_commit_exporter", registry=registry)
        logger.info("Pushed commit metrics to Pushgateway")
    except Exception as e:
        logger.error("Failed to push to Pushgateway: %s", e)


def main():
    logger.info("Jenkins Commit Exporter started (interval=%ds)", POLL_INTERVAL)
    logger.info("Jenkins: %s, Pushgateway: %s", JENKINS_URL, PUSHGATEWAY_URL)

    while True:
        data = fetch_commit_data()
        if data:
            process_and_push(data)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
