#!/usr/bin/env bash
# Deploy Loki recording rules from grafana-cloud/recording-rules/compliance-recording-rules.yaml.
# Uses the Grafana ruler API proxy with a Grafana service account token (glsa_...).
#
# Usage:
#   ./scripts/deploy-recording-rules.sh
#   GRAFANA_URL=https://foo.grafana.net GRAFANA_TOKEN=glsa_... ./scripts/deploy-recording-rules.sh
#   COMPLIANCE_WINDOW=26h ./scripts/deploy-recording-rules.sh   # e.g. for daily scans
#
# ${COMPLIANCE_WINDOW} in the rules file is replaced with COMPLIANCE_WINDOW
# (default 13h, set in .env); see the rules file header for how to size it.
# COMPLIANCE_PROFILES (optional, space-separated, e.g. "cis-dil-benchmark") limits the
# per-control groups to the profiles you actually scan; unset deploys all of them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/grafana-lib.sh
source "${SCRIPT_DIR}/grafana-lib.sh"

gf_load_env "${REPO_DIR}"

RULES_FILE="${REPO_DIR}/grafana-cloud/recording-rules/compliance-recording-rules.yaml"
[ -f "${RULES_FILE}" ] || { echo "Error: Rules file not found: ${RULES_FILE}" >&2; exit 1; }

gf_compliance_window

# 1. Resolve Loki datasource UID
log "Resolving Loki datasource UID..."
DATASOURCES=$(gf_api GET "/api/datasources" -H "Content-Type: application/json")

if [ -n "${GRAFANA_LOKI_DS:-}" ]; then
  LOKI_UID=$(echo "${DATASOURCES}" | jq -r --arg name "${GRAFANA_LOKI_DS}" \
    '.[] | select(.name == $name) | .uid')
  [ -z "${LOKI_UID}" ] && { echo "Error: Loki datasource '${GRAFANA_LOKI_DS}' not found." >&2; exit 1; }
else
  LOKI_UID=$(gf_pick_loki_uid "${DATASOURCES}")
fi

[ -z "${LOKI_UID}" ] && { echo "Error: No Loki datasource found. Set GRAFANA_LOKI_DS in .env." >&2; exit 1; }
LOKI_NAME=$(echo "${DATASOURCES}" | jq -r --arg uid "${LOKI_UID}" '.[] | select(.uid == $uid) | .name')
log "  Loki datasource: ${LOKI_NAME} (${LOKI_UID})"

# 2. Deploy each rule group separately
NAMESPACE="compliance"
log "Deploying recording rules to namespace '${NAMESPACE}'..."

# Single-quoted heredoc — no shell expansion. Runtime values are passed via
# environment variables and read with os.environ inside Python.
#
# The token is written to a mode-0600 temp file and passed to curl with -K
# (config file) so it never appears in process arguments (visible via ps aux).
# curl is used rather than urllib so macOS system SSL certificates are used
# automatically, avoiding python.org Python's missing keychain integration.
_RULES_FILE="${RULES_FILE}" \
_GRAFANA_URL="${GRAFANA_URL}" \
_GRAFANA_TOKEN="${GRAFANA_TOKEN}" \
_LOKI_UID="${LOKI_UID}" \
_NAMESPACE="${NAMESPACE}" \
_COMPLIANCE_WINDOW="${COMPLIANCE_WINDOW}" \
_COMPLIANCE_PROFILES="${COMPLIANCE_PROFILES:-}" \
python3 - <<'PYEOF'
import json, os, subprocess, sys, tempfile, yaml

rules_file    = os.environ["_RULES_FILE"]
grafana_url   = os.environ["_GRAFANA_URL"]
grafana_token = os.environ["_GRAFANA_TOKEN"]
loki_uid      = os.environ["_LOKI_UID"]
namespace     = os.environ["_NAMESPACE"]
window        = os.environ["_COMPLIANCE_WINDOW"]
profiles      = os.environ["_COMPLIANCE_PROFILES"].split()

with open(rules_file) as f:
    data = yaml.safe_load(f.read().replace("${COMPLIANCE_WINDOW}", window))

curlrc = tempfile.NamedTemporaryFile(mode="w", suffix=".curlrc", delete=False)
try:
    curlrc.write(f'header = "Authorization: Bearer {grafana_token}"\n')
    curlrc.close()
    os.chmod(curlrc.name, 0o600)

    prefix = "compliance-per-control-"
    for group in data["groups"]:
        name = group.get("name", "unknown")
        if profiles and name.startswith(prefix) and name[len(prefix):] not in profiles:
            print(f"  [SKIP] group '{name}' (profile not in COMPLIANCE_PROFILES)")
            continue
        payload = json.dumps(group)
        url = f"{grafana_url}/api/ruler/{loki_uid}/api/v1/rules/{namespace}"
        result = subprocess.run(
            [
                "curl", "--silent", "--show-error", "--fail-with-body",
                "-K", curlrc.name,
                "-X", "POST",
                "-H", "Content-Type: application/json",
                "-d", payload,
                url,
            ],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            print(f"  [OK] group '{name}'")
        else:
            print(f"  [FAIL] group '{name}': {result.stdout or result.stderr}", file=sys.stderr)
            sys.exit(result.returncode)
finally:
    os.unlink(curlrc.name)
PYEOF

log "Recording rules deployed successfully."
log "  View at: ${GRAFANA_URL}/alerting/list?search=type:recording"
