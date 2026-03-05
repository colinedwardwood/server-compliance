#!/usr/bin/env bash
# Deploy Loki recording rules from grafana-cloud/recording-rules/compliance-recording-rules.yaml.
# Uses the Grafana ruler API proxy to manage Loki recording rules.
#
# Usage:
#   ./deploy-recording-rules.sh
#   GRAFANA_URL=https://foo.grafana.net GRAFANA_TOKEN=glsa_... ./deploy-recording-rules.sh

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

RULES_FILE="${SCRIPT_DIR}/grafana-cloud/recording-rules/compliance-recording-rules.yaml"

if [ ! -f "${RULES_FILE}" ]; then
  echo "Error: Recording rules file not found: ${RULES_FILE}" >&2
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

gf_api() {
  local method="$1" path="$2"
  shift 2
  curl --silent --show-error --fail-with-body \
    -X "$method" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    "$@" \
    "${GRAFANA_URL}${path}"
}

# ── 1. Resolve Loki datasource UID ───────────────────────────────────────────
log "Resolving Loki datasource UID..."
DATASOURCES=$(gf_api GET "/api/datasources" -H "Content-Type: application/json")

if [ -n "${GRAFANA_LOKI_DS:-}" ]; then
  LOKI_UID=$(echo "${DATASOURCES}" | jq -r --arg name "${GRAFANA_LOKI_DS}" \
    '.[] | select(.name == $name) | .uid')
  [ -z "${LOKI_UID}" ] && { echo "Error: Loki datasource '${GRAFANA_LOKI_DS}' not found." >&2; exit 1; }
else
  LOKI_UID=$(echo "${DATASOURCES}" | jq -r \
    '[.[] | select(.type == "loki")] | sort_by(.name) | first | .uid // ""')
fi

[ -z "${LOKI_UID}" ] && { echo "Error: No Loki datasource found. Set GRAFANA_LOKI_DS." >&2; exit 1; }
log "  Loki UID: ${LOKI_UID}"

# ── 2. Deploy recording rules via Grafana ruler API proxy ─────────────────────
NAMESPACE="compliance"

log "Deploying recording rules to namespace '${NAMESPACE}'..."

gf_api POST "/api/ruler/${LOKI_UID}/api/v1/rules/${NAMESPACE}" \
  -H "Content-Type: application/yaml" \
  --data-binary "@${RULES_FILE}" > /dev/null

log "Recording rules deployed successfully."
log "  View at: ${GRAFANA_URL}/alerting/list?search=type:recording"
