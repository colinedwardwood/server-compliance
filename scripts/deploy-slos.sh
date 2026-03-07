#!/usr/bin/env bash
# Deploy Grafana SLOs from grafana-cloud/slos/compliance-slos.json.
# Creates or updates SLOs via the Grafana SLO plugin API.
#
# Usage:
#   ./scripts/deploy-slos.sh
#   GRAFANA_URL=https://foo.grafana.net GRAFANA_TOKEN=glsa_... ./scripts/deploy-slos.sh
#
# Note: SLOs require Grafana Cloud with the SLO feature enabled.
#       The grafana-slo-app plugin must be installed in your stack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/grafana-lib.sh
source "${SCRIPT_DIR}/grafana-lib.sh"

gf_load_env "${REPO_DIR}"

SLOS_FILE="${REPO_DIR}/grafana-cloud/slos/compliance-slos.json"

if [ ! -f "${SLOS_FILE}" ]; then
  echo "Error: SLO definitions file not found: ${SLOS_FILE}" >&2
  exit 1
fi

SLO_API="/api/plugins/grafana-slo-app/resources/v1/slo"

# 1. Check SLO plugin availability
log "Checking SLO plugin availability..."

SLO_CHECK=$(gf_api GET "${SLO_API}" 2>/dev/null || echo "UNAVAILABLE")

if [ "${SLO_CHECK}" = "UNAVAILABLE" ]; then
  echo "Error: Grafana SLO plugin is not available on this stack." >&2
  echo "  SLOs require Grafana Cloud with the grafana-slo-app plugin enabled." >&2
  echo "  You can still use the SLO definitions in ${SLOS_FILE} as reference" >&2
  echo "  or create them manually via the Grafana UI." >&2
  exit 1
fi

log "  SLO plugin is available"

# 2. Resolve Prometheus datasource UID
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

# 3. Fetch existing SLOs to enable upsert
log "Fetching existing SLOs..."
EXISTING_SLOS=$(echo "${SLO_CHECK}" | jq -r '.slos // []')

# 4. Deploy each SLO
SLO_COUNT=$(jq 'length' "${SLOS_FILE}")
log "Deploying ${SLO_COUNT} SLOs..."

jq -c '.[]' "${SLOS_FILE}" | while read -r slo_def; do
  SLO_NAME=$(echo "${slo_def}" | jq -r '.name')
  log "  Deploying SLO: ${SLO_NAME}..."

  PAYLOAD=$(echo "${slo_def}" | jq --arg uid "${PROM_UID}" \
    '. + {destinationDatasource: {uid: $uid}}')

  EXISTING_UUID=$(echo "${EXISTING_SLOS}" | jq -r \
    --arg name "${SLO_NAME}" \
    '.[] | select(.name == $name) | .uuid // empty')

  if [ -n "${EXISTING_UUID}" ]; then
    log "    Updating existing SLO (uuid=${EXISTING_UUID})..."
    PAYLOAD=$(echo "${PAYLOAD}" | jq --arg uuid "${EXISTING_UUID}" '. + {uuid: $uuid}')
    gf_api PUT "${SLO_API}/${EXISTING_UUID}" -d "${PAYLOAD}" > /dev/null
  else
    log "    Creating new SLO..."
    gf_api POST "${SLO_API}" -d "${PAYLOAD}" > /dev/null
  fi

  log "    Done"
done

log "All SLOs deployed."
