#!/bin/bash
# Push arch-qube metrics to Prometheus Pushgateway.
# Usage: arch-qube-metrics.sh <project-dir> <project-name>
# Deployed at /data/projects/_scripts/arch-qube-metrics.sh (called from the fleet Jenkinsfiles).
#
# Fixed 2026-10-02. The old version had never delivered real numbers:
#   * it bind-mounted "$DIR/arch-qube-reports" into a container, but this runs inside the Jenkins
#     container and the Docker daemon is the host's — /var/jenkins_home/... does not exist on the
#     host (it is /opt/arcana-state/jenkins-home/...), so the mount was empty and parsing failed;
#   * the push step still ran and sent a shared /tmp/aq_metrics.txt left over from some earlier
#     run ("score 100, violations 4, passed 0"), so half the fleet showed "failed, 4 violations"
#     in Prometheus while every repo was passing; concurrent builds also shared that file.
# Now: the report goes in on stdin and the metrics come out on stdout — no mounts, no temp file.
# If the report cannot be read nothing is pushed (stale data is never sent under a project name).
# Metrics are informational: this script never fails the build.
set -u
DIR="${1:?project dir}"
PROJ="${2:?project name}"
JSON="$DIR/arch-qube-reports/arch-qube.json"

if [ ! -f "$JSON" ]; then
    echo "arch-qube-metrics: no report at $JSON — nothing pushed"
    exit 0
fi

BODY=$(docker run --rm -i --entrypoint python3 arcana.boo/arcana/arch-qube:latest -c '
import json, sys
d = json.load(sys.stdin)
s = d["summary"]
print("arch_qube_score %s" % d["score"]["total"])
print("arch_qube_passed %d" % (1 if d["score"]["pass"] else 0))
print("arch_qube_violations %s" % s["total_violations"])
print("arch_qube_critical_violations %s" % s["critical_violations"])
if "rules_evaluated" in s:  # arch-qube >= 0.3.0
    print("arch_qube_rules_evaluated %s" % s["rules_evaluated"])
    print("arch_qube_rules_not_evaluated %s" % s["rules_not_evaluated"])
' < "$JSON" 2>&1)
if [ $? -ne 0 ] || ! printf '%s' "$BODY" | grep -q '^arch_qube_score '; then
    echo "arch-qube-metrics: could not parse $JSON — nothing pushed"
    printf '%s\n' "$BODY" | tail -3
    exit 0
fi

# PUT replaces every metric of this project's group in one request (no delete-then-post gap).
if printf '%s\n' "$BODY" | docker run --rm -i --network devops_default curlimages/curl:latest \
       -sf -X PUT --data-binary @- "http://pushgateway:9091/metrics/job/arch_qube/project/${PROJ}"; then
    echo "arch-qube-metrics: pushed for $PROJ: $(printf '%s' "$BODY" | tr '\n' ' ')"
else
    echo "arch-qube-metrics: push to pushgateway failed (non-fatal)"
fi
exit 0
