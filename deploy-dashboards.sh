#!/usr/bin/env bash
# Deploy Grafana dashboards from grafana-cloud/dashboards/.
# Creates the target folder if it does not already exist, then upserts
# every *.json file found under grafana-cloud/dashboards/.
#
# Usage:
#   ./deploy-dashboards.sh
#   GRAFANA_URL=https://foo.grafana.net GRAFANA_TOKEN=glsa_... ./deploy-dashboards.sh
#
# Datasource names (optional — defaults to auto-detect by type):
#   GRAFANA_PROM_DS=grafana-cloud-prom GRAFANA_LOKI_DS=grafana-cloud-logs ./deploy-dashboards.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Credentials ───────────────────────────────────────────────────────────────
# Load from .env if it exists; environment variables take precedence.
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

DASHBOARDS_DIR="${SCRIPT_DIR}/grafana-cloud/dashboards"

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

# ── 2. Resolve datasource UIDs ────────────────────────────────────────────────
# Set GRAFANA_PROM_DS / GRAFANA_LOKI_DS to an exact datasource name to skip
# auto-detection. Otherwise, the first Prometheus/Loki source is used.
log "Resolving datasource UIDs..."
DATASOURCES=$(gf_api GET "/api/datasources")

if [ -n "${GRAFANA_PROM_DS:-}" ]; then
  PROM_UID=$(echo "${DATASOURCES}" | jq -r --arg name "${GRAFANA_PROM_DS}" \
    '.[] | select(.name == $name) | .uid')
  [ -z "${PROM_UID}" ] && { echo "Error: Prometheus datasource '${GRAFANA_PROM_DS}' not found." >&2; exit 1; }
else
  PROM_UID=$(echo "${DATASOURCES}" | jq -r \
    '[.[] | select(.type == "prometheus")] | sort_by(.name) | first | .uid // ""')
fi

if [ -n "${GRAFANA_LOKI_DS:-}" ]; then
  LOKI_UID=$(echo "${DATASOURCES}" | jq -r --arg name "${GRAFANA_LOKI_DS}" \
    '.[] | select(.name == $name) | .uid')
  [ -z "${LOKI_UID}" ] && { echo "Error: Loki datasource '${GRAFANA_LOKI_DS}' not found." >&2; exit 1; }
else
  LOKI_UID=$(echo "${DATASOURCES}" | jq -r \
    '[.[] | select(.type == "loki")] | sort_by(.name) | first | .uid // ""')
fi

[ -z "${PROM_UID}" ] && { echo "Error: No Prometheus datasource found. Set GRAFANA_PROM_DS." >&2; exit 1; }
[ -z "${LOKI_UID}" ] && { echo "Error: No Loki datasource found. Set GRAFANA_LOKI_DS." >&2; exit 1; }

log "  Prometheus UID: ${PROM_UID}"
log "  Loki UID:       ${LOKI_UID}"

# ── 3. Import each dashboard ──────────────────────────────────────────────────
shopt -s nullglob
DASHBOARDS=("${DASHBOARDS_DIR}"/*.json)

if [ ${#DASHBOARDS[@]} -eq 0 ]; then
  log "No dashboard JSON files found in ${DASHBOARDS_DIR}/"
  exit 0
fi

for DASHBOARD_FILE in "${DASHBOARDS[@]}"; do
  DASHBOARD_NAME="$(basename "${DASHBOARD_FILE}" .json)"
  log "Deploying dashboard: ${DASHBOARD_NAME}..."

  # Strip __inputs/__requires (import-wizard metadata), set id=null, and
  # substitute the datasource UID placeholders with real UIDs.
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
