#!/usr/bin/env bash
# Validate that what is deployed in Grafana Cloud matches the local source files.
#
# Checks:
#   1. Compliance folder exists
#   2. All three dashboards are present (uid + title)
#   3. All recording rule groups and metric names match
#   4. All alert rule groups and alert titles match
#   5. SLO plugin availability and SLO names match  (skipped gracefully if plugin absent)
#
# Usage:
#   ./scripts/validate-grafana.sh
#   GRAFANA_URL=https://foo.grafana.net GRAFANA_TOKEN=glsa_... ./scripts/validate-grafana.sh
#
# Exit code: 0 if all checks pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/grafana-lib.sh
source "${SCRIPT_DIR}/grafana-lib.sh"
# shellcheck disable=SC2034  # GRAFANA_URL/TOKEN set by gf_load_env via sourced lib

gf_load_env "${REPO_DIR}"

FOLDER_UID="compliance"
FOLDER_TITLE="Compliance"
RECORDING_RULES_FILE="${REPO_DIR}/grafana-cloud/recording-rules/compliance-recording-rules.yaml"
ALERTS_FILE="${REPO_DIR}/grafana-cloud/alerts/compliance-alerts.yaml"
DASHBOARDS_DIR="${REPO_DIR}/grafana-cloud/dashboards"
SLOS_FILE="${REPO_DIR}/grafana-cloud/slos/compliance-slos.json"
NAMESPACE="compliance"

# Formatting
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}✓${RESET} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}✗${RESET} $*"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}–${RESET} $*"; }
section() { echo -e "\n${BOLD}$*${RESET}"; }

# Helpers
# gf_api_soft: like gf_api but does not exit on HTTP error (returns empty on failure)
gf_api_soft() {
  local method="$1" path="$2"
  shift 2
  curl --silent \
    -X "$method" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GRAFANA_URL}${path}" \
    "$@" || true
}

# 1. Folder
section "1. Compliance folder"
FOLDER_RESP=$(gf_api_soft GET "/api/folders/${FOLDER_UID}")
REMOTE_TITLE=$(echo "${FOLDER_RESP}" | jq -r '.title // empty' 2>/dev/null || true)

if [ "${REMOTE_TITLE}" = "${FOLDER_TITLE}" ]; then
  pass "Folder '${FOLDER_TITLE}' exists (uid=${FOLDER_UID})"
else
  fail "Folder '${FOLDER_TITLE}' not found (got: '${REMOTE_TITLE:-<empty>}')"
fi

# 2. Dashboards
section "2. Dashboards"
REMOTE_DASHBOARDS=$(gf_api_soft GET "/api/search?folderUIDs=${FOLDER_UID}&type=dash-db")

shopt -s nullglob
LOCAL_DASH_FILES=("${DASHBOARDS_DIR}"/*.json)

if [ ${#LOCAL_DASH_FILES[@]} -eq 0 ]; then
  skip "No local dashboard JSON files found in ${DASHBOARDS_DIR}/"
else
  for LOCAL_FILE in "${LOCAL_DASH_FILES[@]}"; do
    EXPECTED_UID="$(basename "${LOCAL_FILE}" .json)"
    EXPECTED_TITLE="$(jq -r '.title' "${LOCAL_FILE}")"

    REMOTE_TITLE=$(echo "${REMOTE_DASHBOARDS}" | \
      jq -r --arg uid "${EXPECTED_UID}" \
      '.[] | select(.uid == $uid) | .title // empty')

    if [ -z "${REMOTE_TITLE}" ]; then
      fail "Dashboard '${EXPECTED_UID}' not found in Grafana Cloud"
    elif [ "${REMOTE_TITLE}" = "${EXPECTED_TITLE}" ]; then
      pass "Dashboard '${EXPECTED_UID}': title matches ('${EXPECTED_TITLE}')"
    else
      fail "Dashboard '${EXPECTED_UID}': title mismatch (local='${EXPECTED_TITLE}', remote='${REMOTE_TITLE}')"
    fi
  done
fi

# 3. Recording rules
section "3. Recording rules"

if ! python3 -c "import yaml" 2>/dev/null; then
  skip "PyYAML not available — skipping recording rules check (pip3 install pyyaml)"
else
  LOKI_DATASOURCES=$(gf_api_soft GET "/api/datasources")
  if [ -n "${GRAFANA_LOKI_DS:-}" ]; then
    LOKI_UID=$(echo "${LOKI_DATASOURCES}" | jq -r --arg n "${GRAFANA_LOKI_DS}" \
      '.[] | select(.name == $n) | .uid')
  else
    LOKI_UID=$(echo "${LOKI_DATASOURCES}" | jq -r \
      '[.[] | select(
          .type == "loki" and
          (.name | ascii_downcase | test("alert.state.history") | not)
        )] | sort_by(.name) | first | .uid // ""')
  fi

  if [ -z "${LOKI_UID}" ]; then
    skip "Could not resolve Loki datasource UID — skipping recording rules check"
  else
    REMOTE_RULES=$(gf_api_soft GET "/api/ruler/${LOKI_UID}/api/v1/rules/${NAMESPACE}")

    _RULES_FILE="${RECORDING_RULES_FILE}" \
    _REMOTE_RULES="${REMOTE_RULES}" \
    python3 - <<'PYEOF'
import json, os, sys, yaml

rules_file   = os.environ["_RULES_FILE"]
remote_json  = os.environ["_REMOTE_RULES"]

with open(rules_file) as f:
    local_data = yaml.safe_load(f)

try:
    remote_data = json.loads(remote_json)
except json.JSONDecodeError:
    print("  SKIP: Could not parse remote recording rules response", file=sys.stderr)
    sys.exit(0)

GREEN, RED, RESET = "\033[0;32m", "\033[0;31m", "\033[0m"
passed = failed = 0

remote_groups = {}
for groups in remote_data.values():
    for g in groups:
        remote_groups[g["name"]] = g

for local_group in local_data.get("groups", []):
    gname = local_group["name"]
    remote_group = remote_groups.get(gname)

    if remote_group is None:
        print(f"  {RED}✗{RESET} Group '{gname}': not found remotely")
        failed += 1
        continue

    local_metrics  = [r["record"] for r in local_group.get("rules", [])]
    remote_metrics = [r["record"] for r in remote_group.get("rules", [])]
    local_count    = len(local_metrics)
    remote_count   = len(remote_metrics)

    if local_count != remote_count:
        print(f"  {RED}✗{RESET} Group '{gname}': rule count mismatch "
              f"(local={local_count}, remote={remote_count})")
        failed += 1
        continue

    missing = [m for m in local_metrics if m not in remote_metrics]
    if missing:
        print(f"  {RED}✗{RESET} Group '{gname}': missing metrics remotely: {missing}")
        failed += 1
    else:
        print(f"  {GREEN}✓{RESET} Group '{gname}': {local_count} rule(s) match "
              f"({', '.join(dict.fromkeys(local_metrics))})")
        passed += 1

sys.exit(0 if failed == 0 else 1)
PYEOF
    RR_EXIT=$?
    if [ "${RR_EXIT}" -ne 0 ]; then
      FAIL=$((FAIL + 1))
      PASS=$((PASS > 0 ? PASS - 1 : 0))
    fi
  fi
fi

# 4. Alert rules
# The provisioning API returns rules with group=null, so we validate by alert
# title across the full set rather than per-group.
section "4. Alert rules"

if ! python3 -c "import yaml" 2>/dev/null; then
  skip "PyYAML not available — skipping alert rules check"
else
  REMOTE_ALERT_RULES=$(gf_api_soft GET "/api/v1/provisioning/alert-rules")
  REMOTE_ALERT_TITLES=$(echo "${REMOTE_ALERT_RULES}" | \
    jq -r --arg f "${FOLDER_UID}" '[.[] | select(.folderUID == $f) | .title] | sort | .[]')

  _ALERTS_FILE="${ALERTS_FILE}" \
  _REMOTE_TITLES="${REMOTE_ALERT_TITLES}" \
  python3 - <<'PYEOF'
import os, sys, yaml

alerts_file   = os.environ["_ALERTS_FILE"]
remote_titles = set(os.environ["_REMOTE_TITLES"].splitlines())

with open(alerts_file) as f:
    local_data = yaml.safe_load(f)

GREEN, RED, RESET = "\033[0;32m", "\033[0;31m", "\033[0m"
failed = 0

for group in local_data.get("groups", []):
    gname        = group["name"]
    local_alerts = [r["alert"] for r in group.get("rules", [])]
    missing      = [a for a in local_alerts if a not in remote_titles]

    if missing:
        for alert in missing:
            print(f"  {RED}✗{RESET} [{gname}] '{alert}': not found in Grafana Cloud")
        failed += 1
    else:
        print(f"  {GREEN}✓{RESET} [{gname}]: {len(local_alerts)} alert(s) present "
              f"({', '.join(local_alerts)})")

sys.exit(0 if failed == 0 else 1)
PYEOF
  ALERT_EXIT=$?
  if [ "${ALERT_EXIT}" -ne 0 ]; then
    FAIL=$((FAIL + 1))
  fi
fi

# 5. SLOs
section "5. SLOs"
SLO_API="/api/plugins/grafana-slo-app/resources/v1/slo"
SLO_RESP=$(gf_api_soft GET "${SLO_API}")

if echo "${SLO_RESP}" | jq -e '.slos' > /dev/null 2>&1; then
  REMOTE_SLO_NAMES=$(echo "${SLO_RESP}" | jq -r '[.slos[].name] | sort | .[]')

  while IFS= read -r expected_name; do
    if echo "${REMOTE_SLO_NAMES}" | grep -qxF "${expected_name}"; then
      pass "SLO '${expected_name}' exists"
    else
      fail "SLO '${expected_name}' not found in Grafana Cloud"
    fi
  done < <(jq -r '.[].name' "${SLOS_FILE}" | sort)
else
  skip "SLO plugin not available on this stack — skipping SLO check"
fi

# Summary
echo
echo -e "${BOLD}────────────────────────────────────────${RESET}"
TOTAL=$((PASS + FAIL))
if [ "${FAIL}" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}All ${TOTAL} check(s) passed.${RESET}"
else
  echo -e "${RED}${BOLD}${FAIL} of ${TOTAL} check(s) failed.${RESET}"
fi
echo -e "${BOLD}────────────────────────────────────────${RESET}"

[ "${FAIL}" -eq 0 ]
