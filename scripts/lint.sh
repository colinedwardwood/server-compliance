#!/usr/bin/env bash
set -euo pipefail

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "Error: shellcheck is required. Install it first (e.g. sudo apt install -y shellcheck)." >&2
  exit 1
fi

shellcheck verify.sh deploy-dashboards.sh deploy-alerts.sh deploy-slos.sh deploy-recording-rules.sh
echo "shellcheck passed."
