#!/bin/bash
# arch-qube-push-metrics.sh — Push Architecture Qube results to Prometheus Pushgateway
# Usage: bash arch-qube-push-metrics.sh <project-name> <framework> [report-dir]
#
# Reads arch-qube.json from report dir and pushes metrics to Pushgateway.
# Called from Jenkins pipeline after the Architecture Qube stage.

set -euo pipefail

PROJECT="${1:?Usage: $0 <project> <framework> [report-dir]}"
FRAMEWORK="${2:?Usage: $0 <project> <framework> [report-dir]}"
REPORT_DIR="${3:-arch-qube-reports}"
PUSHGATEWAY="${PUSHGATEWAY_URL:-http://pushgateway:9091}"

REPORT="${REPORT_DIR}/arch-qube.json"

if [ ! -f "$REPORT" ]; then
    echo "[arch-qube-push] No report found at ${REPORT}, skipping metrics push"
    exit 0
fi

# Extract metrics from JSON using python3 (available in Jenkins container)
METRICS=$(python3 -c "
import json, sys

with open('${REPORT}') as f:
    data = json.load(f)

score = data.get('score', {})
summary = data.get('summary', {})
rules = data.get('rules', [])

total = score.get('total', 0)
passed = 1 if score.get('pass', False) else 0
violations = summary.get('total_violations', 0)

lines = []
lines.append('# TYPE arch_qube_score gauge')
lines.append(f'arch_qube_score{{project=\"${PROJECT}\",framework=\"${FRAMEWORK}\"}} {total}')
lines.append('# TYPE arch_qube_passed gauge')
lines.append(f'arch_qube_passed{{project=\"${PROJECT}\",framework=\"${FRAMEWORK}\"}} {passed}')
lines.append('# TYPE arch_qube_violations gauge')
lines.append(f'arch_qube_violations{{project=\"${PROJECT}\",framework=\"${FRAMEWORK}\"}} {violations}')
lines.append('# TYPE arch_qube_rule_compliance gauge')

for r in rules:
    name = r.get('rule', r.get('name', 'unknown'))
    compliance = r.get('compliance', 0)
    lines.append(f'arch_qube_rule_compliance{{project=\"${PROJECT}\",rule=\"{name}\"}} {compliance}')

print('\n'.join(lines))
")

# Push to Pushgateway
echo "$METRICS" | curl -s --data-binary @- \
    "${PUSHGATEWAY}/metrics/job/arch_qube/instance/${PROJECT}" \
    && echo "[arch-qube-push] Metrics pushed for ${PROJECT}" \
    || echo "[arch-qube-push] WARNING: Failed to push metrics for ${PROJECT}"
