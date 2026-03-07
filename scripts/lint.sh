#!/usr/bin/env bash
set -euo pipefail

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "Error: shellcheck is required. Install it first (e.g. sudo apt install -y shellcheck)." >&2
  exit 1
fi

shellcheck -x \
  scripts/grafana-lib.sh \
  scripts/lint.sh \
  scripts/deploy-alerts.sh \
  scripts/deploy-dashboards.sh \
  scripts/deploy-recording-rules.sh \
  scripts/deploy-slos.sh \
  scripts/validate-grafana.sh \
  verify.sh

echo "shellcheck passed."
