#!/usr/bin/env bash
# cinc-auditor compliance scan wrapper
# Usage: verify.sh [profile-name]
#   profile-name: one of the subdirectory names under $AUDIT_PROFILES_BASE
#                 defaults to linux-baseline
#
# Outputs per run:
#   /var/log/cinc-auditor/compliance_<profile>_<ts>.log  — JSON events (Loki)
#   /var/log/cinc-auditor/report_<profile>_<ts>.json     — raw InSpec JSON

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: verify.sh must run as root (use sudo or root cron)." >&2
  exit 1
fi

# Configuration
PROFILE_NAME="${1:-${AUDIT_PROFILE_NAME:-linux-baseline}}"
PROFILE_BASE="${AUDIT_PROFILES_BASE:-/opt/audit-profiles}"
PROFILE_PATH="${AUDIT_PROFILE_DIR:-${PROFILE_BASE}/${PROFILE_NAME}}"
AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-/var/log/cinc-auditor}"

mkdir -p "$AUDIT_LOG_DIR"

RUN_TS=$(date -u +"%Y%m%dT%H%M%SZ")
PROFILE_SLUG="${PROFILE_NAME//[^a-zA-Z0-9]/_}"
REPORT_JSON="${AUDIT_LOG_DIR}/report_${PROFILE_SLUG}_${RUN_TS}.json"
EVENTS_LOG="${AUDIT_LOG_DIR}/compliance_${PROFILE_SLUG}_${RUN_TS}.log"

# Build cinc-auditor flags
EXTRA_FLAGS=()
[ -f "${PROFILE_PATH}/waivers.yaml" ] && EXTRA_FLAGS+=(--waiver-file "${PROFILE_PATH}/waivers.yaml")
[ -f "${PROFILE_PATH}/inputs.yaml" ]  && EXTRA_FLAGS+=(--input-file "${PROFILE_PATH}/inputs.yaml")

# Run scan
# Exit codes: 0=all pass, 100=failures present, 101=skips only, other=error
# stderr is kept (not discarded) so runtime errors appear in the cron log.
set +e
cinc-auditor exec "$PROFILE_PATH" \
  "${EXTRA_FLAGS[@]}" \
  --reporter json:"$REPORT_JSON" compliance-json:"$EVENTS_LOG"
SCAN_EXIT=$?
set -e

case "$SCAN_EXIT" in
  0|100|101) ;;
  *) echo "Error: cinc-auditor exited with code ${SCAN_EXIT}" >&2; exit 1 ;;
esac

# Fix permissions so Alloy can read the files
for f in "$REPORT_JSON" "$EVENTS_LOG"; do
  [ -f "$f" ] && chown syslog:adm "$f" && chmod 640 "$f"
done

# Prune old files (keep last 48 runs per profile)
# find + sort by filename (timestamps are embedded: _YYYYMMDDTHHMMSSZ) so the
# sort is locale-independent and does not rely on mtime or ls ordering.
prune_old_files() {
  local pattern="$1" keep="$2"
  local files
  mapfile -t files < <(find "${AUDIT_LOG_DIR}" -maxdepth 1 -name "${pattern}" | sort -r)
  local excess=("${files[@]:${keep}}")
  [ "${#excess[@]}" -gt 0 ] && rm -- "${excess[@]}"
}

prune_old_files "report_${PROFILE_SLUG}_*.json" 48
prune_old_files "compliance_${PROFILE_SLUG}_*.log" 48
