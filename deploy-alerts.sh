#!/usr/bin/env bash
# Deploy Grafana alert rules from grafana-cloud/alerts/compliance-alerts.yaml.
# Creates the target folder if it does not already exist, then upserts
# each rule group via the Grafana Alerting Provisioning API.
#
# Usage:
#   ./deploy-alerts.sh
#   GRAFANA_URL=https://foo.grafana.net GRAFANA_TOKEN=glsa_... ./deploy-alerts.sh
#
# Requirements: curl, jq, python3 with PyYAML (sudo apt install python3-yaml)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Credentials ───────────────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  # shellcheck source=/dev/null
  set -a; source "${ENV_FILE}"; set +a
fi

GRAFANA_URL="${GRAFANA_URL:-}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"

if [ -z "${GRAFANA_URL}" ] || [ -z "${GRAFANA_TOKEN}" ]; then
  echo "Error: GRAFANA_URL and GRAFANA_TOKEN must be set (via environment or .env file)." >&2
  echo "  Copy .env.example to .env and fill in your values, or set the env vars directly." >&2
  exit 1
fi

ALERTS_FILE="${SCRIPT_DIR}/grafana-cloud/alerts/compliance-alerts.yaml"

if [ ! -f "${ALERTS_FILE}" ]; then
  echo "Error: Alert rules file not found: ${ALERTS_FILE}" >&2
  exit 1
fi

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "Error: python3 with PyYAML is required." >&2
  echo "  Install with: pip3 install pyyaml  or  sudo apt install python3-yaml" >&2
  exit 1
fi

# ── Folder config ─────────────────────────────────────────────────────────────
FOLDER_TITLE="Compliance"
FOLDER_UID="compliance"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

gf_api() {
  local method="$1" path="$2"
  shift 2
  curl --silent --show-error --fail-with-body \
    -X "$method" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "X-Disable-Provenance: true" \
    "${GRAFANA_URL}${path}" \
    "$@"
}

# ── 1. Ensure folder exists ───────────────────────────────────────────────────
log "Ensuring folder '${FOLDER_TITLE}' exists (uid=${FOLDER_UID})..."

FOLDER_RESPONSE=$(gf_api GET "/api/folders/${FOLDER_UID}" 2>/dev/null || true)

if echo "${FOLDER_RESPONSE}" | jq -e '.uid' > /dev/null 2>&1; then
  log "  Folder already exists"
else
  log "  Creating folder..."
  gf_api POST "/api/folders" \
    -d "{\"uid\": \"${FOLDER_UID}\", \"title\": \"${FOLDER_TITLE}\"}" > /dev/null
  log "  Created folder"
fi

# ── 2. Resolve Prometheus datasource UID ──────────────────────────────────────
log "Resolving Prometheus datasource UID..."
DATASOURCES=$(gf_api GET "/api/datasources")

if [ -n "${GRAFANA_PROM_DS:-}" ]; then
  PROM_UID=$(echo "${DATASOURCES}" | jq -r --arg name "${GRAFANA_PROM_DS}" \
    '.[] | select(.name == $name) | .uid')
  [ -z "${PROM_UID}" ] && { echo "Error: Prometheus datasource '${GRAFANA_PROM_DS}' not found." >&2; exit 1; }
else
  PROM_UID=$(echo "${DATASOURCES}" | jq -r \
    '[.[] | select(.type == "prometheus")] | sort_by(.name) | first | .uid // ""')
fi

[ -z "${PROM_UID}" ] && { echo "Error: No Prometheus datasource found. Set GRAFANA_PROM_DS." >&2; exit 1; }
log "  Prometheus UID: ${PROM_UID}"

# ── 3. Convert YAML to Grafana provisioning format and deploy ─────────────────
log "Parsing alert rules from ${ALERTS_FILE}..."

# Python converts YAML → JSON and transforms each Prometheus-style rule into
# the Grafana Alerting Provisioning API format.
GROUPS_JSON=$(python3 - "${ALERTS_FILE}" "${PROM_UID}" "${FOLDER_UID}" <<'PYEOF'
import json, sys, yaml

alerts_file, prom_uid, folder_uid = sys.argv[1], sys.argv[2], sys.argv[3]

with open(alerts_file) as f:
    data = yaml.safe_load(f)

def convert_rule(rule):
    """Convert a Prometheus-style alert rule to Grafana provisioning format."""
    expr = rule["expr"].strip()
    for_duration = rule.get("for", "5m")
    return {
        "title": rule["alert"],
        "condition": "B",
        "data": [
            {
                "refId": "A",
                "queryType": "",
                "relativeTimeRange": {"from": 600, "to": 0},
                "datasourceUid": prom_uid,
                "model": {
                    "editorMode": "code",
                    "expr": expr,
                    "instant": True,
                    "intervalMs": 1000,
                    "maxDataPoints": 43200,
                    "refId": "A",
                },
            },
            {
                "refId": "B",
                "queryType": "",
                "relativeTimeRange": {"from": 0, "to": 0},
                "datasourceUid": "-100",
                "model": {
                    "conditions": [
                        {
                            "evaluator": {"params": [0], "type": "gte"},
                            "operator": {"type": "and"},
                            "query": {"params": ["A"]},
                            "reducer": {"params": [], "type": "last"},
                            "type": "query",
                        }
                    ],
                    "datasource": {"type": "__expr__", "uid": "-100"},
                    "hide": False,
                    "intervalMs": 1000,
                    "maxDataPoints": 43200,
                    "refId": "B",
                    "type": "classic_conditions",
                },
            },
        ],
        "noDataState": "OK",
        "execErrState": "Error",
        "for": for_duration,
        "labels": rule.get("labels", {}),
        "annotations": rule.get("annotations", {}),
        "isPaused": False,
        "folderUID": folder_uid,
    }

def parse_interval(interval_str):
    """Convert Prometheus interval string (e.g. '5m') to seconds."""
    s = interval_str.strip()
    if s.endswith("m"):
        return int(s[:-1]) * 60
    if s.endswith("s"):
        return int(s[:-1])
    if s.endswith("h"):
        return int(s[:-1]) * 3600
    return 300

result = []
for group in data.get("groups", []):
    interval = parse_interval(group.get("interval", "5m"))
    converted_rules = [convert_rule(r) for r in group.get("rules", [])]
    result.append({
        "name": group["name"],
        "interval": interval,
        "rules": converted_rules,
    })

json.dump(result, sys.stdout)
PYEOF
)

GROUP_COUNT=$(echo "${GROUPS_JSON}" | jq 'length')
log "  Found ${GROUP_COUNT} rule groups"

echo "${GROUPS_JSON}" | jq -c '.[]' | while read -r group; do
  GROUP_NAME=$(echo "${group}" | jq -r '.name')
  RULE_COUNT=$(echo "${group}" | jq '.rules | length')
  INTERVAL=$(echo "${group}" | jq '.interval')

  log "Deploying rule group: ${GROUP_NAME} (${RULE_COUNT} rules, interval=${INTERVAL}s)..."

  PAYLOAD=$(jq -n \
    --argjson interval "${INTERVAL}" \
    --argjson rules "$(echo "${group}" | jq '.rules')" \
    '{interval: $interval, rules: $rules}')

  gf_api PUT "/api/v1/provisioning/folder/${FOLDER_UID}/rule-groups/${GROUP_NAME}" \
    -d "${PAYLOAD}" > /dev/null

  log "  Done"
done

log "All alert rules deployed to folder '${FOLDER_TITLE}'."
