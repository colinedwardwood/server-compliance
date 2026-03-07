#!/usr/bin/env bash
# Deploy Grafana dashboards from grafana-cloud/dashboards/.
# Creates the target folder if it does not already exist, then upserts
# every *.json file found under grafana-cloud/dashboards/.
#
# Usage:
#   ./scripts/deploy-dashboards.sh
#   GRAFANA_URL=https://foo.grafana.net GRAFANA_TOKEN=glsa_... ./scripts/deploy-dashboards.sh
#
# Datasource names (optional — defaults to auto-detect by type):
#   GRAFANA_PROM_DS=grafana-cloud-prom GRAFANA_LOKI_DS=grafana-cloud-logs ./scripts/deploy-dashboards.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/grafana-lib.sh
source "${SCRIPT_DIR}/grafana-lib.sh"

gf_load_env "${REPO_DIR}"

DASHBOARDS_DIR="${REPO_DIR}/grafana-cloud/dashboards"
FOLDER_TITLE="Compliance"
FOLDER_UID="compliance"

# 1. Ensure folder exists
log "Ensuring folder '${FOLDER_TITLE}' exists (uid=${FOLDER_UID})..."
gf_ensure_folder "${FOLDER_UID}" "${FOLDER_TITLE}"

# 2. Resolve datasource UIDs
gf_resolve_datasources
log "  Prometheus UID: ${PROM_UID}"
log "  Loki UID:       ${LOKI_UID}"

# 3. Import each dashboard
shopt -s nullglob
DASHBOARDS=("${DASHBOARDS_DIR}"/*.json)

if [ ${#DASHBOARDS[@]} -eq 0 ]; then
  log "No dashboard JSON files found in ${DASHBOARDS_DIR}/"
  exit 0
fi

for DASHBOARD_FILE in "${DASHBOARDS[@]}"; do
  DASHBOARD_NAME="$(basename "${DASHBOARD_FILE}" .json)"
  log "Deploying dashboard: ${DASHBOARD_NAME}..."

  DASHBOARD_JSON=$(jq \
    --arg prom "${PROM_UID}" \
    --arg loki "${LOKI_UID}" \
    'del(.__inputs, .__requires) | .id = null |
     walk(if type == "object" and .uid? then
       .uid |= gsub("\\$\\{DS_PROMETHEUS\\}"; $prom) | .uid |= gsub("\\$\\{DS_LOKI\\}"; $loki)
     else . end)' \
    "${DASHBOARD_FILE}")

  PAYLOAD=$(jq -n \
    --argjson dashboard "${DASHBOARD_JSON}" \
    --arg folderUid "${FOLDER_UID}" \
    '{
      dashboard: $dashboard,
      folderUid: $folderUid,
      overwrite: true,
      message: "Deployed by deploy-dashboards.sh"
    }')

  RESULT=$(gf_api POST "/api/dashboards/db" -d "${PAYLOAD}")
  DASHBOARD_URL=$(echo "${RESULT}" | jq -r '.url // "unknown"')
  log "  Done → ${GRAFANA_URL}${DASHBOARD_URL}"
done

log "All dashboards deployed to folder '${FOLDER_TITLE}'."
