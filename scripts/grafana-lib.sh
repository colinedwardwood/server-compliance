#!/usr/bin/env bash
# Shared Grafana Cloud helpers — source this file, do not execute directly.
#
# Requires the following variables to be set by the caller:
#   GRAFANA_URL   — e.g. https://your-org.grafana.net
#   GRAFANA_TOKEN — Grafana service account token (glsa_...)
#
# Optional:
#   GRAFANA_PROM_DS — exact Prometheus datasource name (skips auto-detection)
#   GRAFANA_LOKI_DS — exact Loki datasource name (skips auto-detection)

# Logging
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# Core API helper
# Usage: gf_api METHOD /api/path [-d '{}'] [extra curl args...]
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

# Folder management
# Usage: gf_ensure_folder <uid> <title>
gf_ensure_folder() {
  local uid="$1" title="$2"
  local response
  response=$(gf_api GET "/api/folders/${uid}" 2>/dev/null || true)
  if echo "${response}" | jq -e '.uid' > /dev/null 2>&1; then
    log "  Folder '${title}' already exists"
  else
    log "  Creating folder '${title}'..."
    gf_api POST "/api/folders" \
      -d "{\"uid\": \"${uid}\", \"title\": \"${title}\"}" > /dev/null
    log "  Folder created"
  fi
}

# Datasource UID resolution
# Usage: gf_resolve_datasources
# Sets PROM_UID and LOKI_UID; exits on failure.
gf_resolve_datasources() {
  log "Resolving datasource UIDs..."
  local datasources
  datasources=$(gf_api GET "/api/datasources")

  if [ -n "${GRAFANA_PROM_DS:-}" ]; then
    PROM_UID=$(echo "${datasources}" | jq -r --arg name "${GRAFANA_PROM_DS}" \
      '.[] | select(.name == $name) | .uid')
    [ -z "${PROM_UID}" ] && {
      echo "Error: Prometheus datasource '${GRAFANA_PROM_DS}' not found." >&2; exit 1
    }
  else
    PROM_UID=$(echo "${datasources}" | jq -r \
      '[.[] | select(.type == "prometheus")] | sort_by(.name) | first | .uid // ""')
  fi

  if [ -n "${GRAFANA_LOKI_DS:-}" ]; then
    LOKI_UID=$(echo "${datasources}" | jq -r --arg name "${GRAFANA_LOKI_DS}" \
      '.[] | select(.name == $name) | .uid')
    [ -z "${LOKI_UID}" ] && {
      echo "Error: Loki datasource '${GRAFANA_LOKI_DS}' not found." >&2; exit 1
    }
  else
    LOKI_UID=$(echo "${datasources}" | jq -r \
      '[.[] | select(
          .type == "loki" and
          (.name | ascii_downcase | test("alert.state.history") | not)
        )] | sort_by(.name) | first | .uid // ""')
  fi

  [ -z "${PROM_UID}" ] && {
    echo "Error: No Prometheus datasource found. Set GRAFANA_PROM_DS in .env." >&2; exit 1
  }
  [ -z "${LOKI_UID}" ] && {
    echo "Error: No Loki datasource found. Set GRAFANA_LOKI_DS in .env." >&2; exit 1
  }

  log "  Prometheus UID : ${PROM_UID}"
  log "  Loki UID       : ${LOKI_UID}"
}

# Credential loading
# Usage: gf_load_env <script_dir>
# Sources .env from <script_dir> if present; validates required vars.
gf_load_env() {
  local script_dir="$1"
  local env_file="${script_dir}/.env"
  if [ -f "${env_file}" ]; then
    set -a
    # shellcheck source=/dev/null
    source "${env_file}"
    set +a
  fi

  GRAFANA_URL="${GRAFANA_URL:-}"
  GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"

  if [ -z "${GRAFANA_URL}" ] || [ -z "${GRAFANA_TOKEN}" ]; then
    echo "Error: GRAFANA_URL and GRAFANA_TOKEN must be set (via environment or .env file)." >&2
    echo "  Copy .env.example to .env and fill in your values, or export the vars directly." >&2
    exit 1
  fi
}
