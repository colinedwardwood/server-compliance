# server-compliance

Automated Linux compliance scanning with cinc-auditor, shipped to Grafana Cloud
via Grafana Alloy. CIS and DevSec baseline profiles run on a cron schedule;
results flow as structured JSON logs into Loki, where recording rules derive
Prometheus metrics used by dashboards, alert rules, and SLOs.

## Architecture

```
Linux host
  ├─ cinc-auditor + compliance-json reporter  (cron: hourly + every 6h)
  │    └─ /var/log/cinc-auditor/compliance_<profile>_<ts>.log
  └─ Grafana Alloy
       └─ stage.json → Grafana Cloud Loki

Grafana Cloud
  ├─ Loki recording rules  →  Prometheus metrics
  ├─ Dashboards            —  Fleet · Host · Control drill-down
  ├─ Alert rules (SAAFE)   —  12 rules across Failure/Error/Amend/Anomaly/Saturation
  └─ SLOs                  —  Compliance score objectives with burn-rate alerting
```

No textfile collector, no separate exporter. The custom `compliance-json` InSpec
reporter emits one JSON line per control and a scan summary line. Everything else
is derived from logs.

## Repository layout

```
compliance-profiles/          Inputs and example waivers for each scan profile
  linux-baseline/               dev-sec/linux-baseline (hourly, ~40 controls)
  cis-dil-benchmark/            dev-sec/cis-dil-benchmark (every 6h, ~250 controls)

grafana-cloud/                Everything deployed to Grafana Cloud
  alerts/                       SAAFE-model Prometheus alert rules
  dashboards/                   Fleet, Host, and Control JSON dashboards
  recording-rules/              Loki recording rules → Prometheus metrics
  slos/                         Compliance score SLO definitions

inspec-reporter-compliance-json/  Custom InSpec reporter gem (Ruby)

ansible/                      Automated deployment to Ubuntu hosts
  roles/server-compliance/

docs/                         Documentation
  setup.md                      Step-by-step manual setup guide
ROADMAP.md                    Planned work

scripts/
  grafana-lib.sh                Shared Grafana API helpers (sourced by deploy scripts)
  deploy-alerts.sh              Push alert rules to Grafana Cloud
  deploy-dashboards.sh          Push dashboards to Grafana Cloud
  deploy-recording-rules.sh     Push Loki recording rules to Grafana Cloud
  deploy-slos.sh                Push SLOs to Grafana Cloud
  validate-grafana.sh           Read back and verify everything deployed to Grafana Cloud
  lint.sh                       shellcheck wrapper

config.alloy                  Grafana Alloy configuration (deploy to /etc/alloy/)
verify.sh                     Compliance scan wrapper script (deploy to /usr/local/bin/)
.env.example                  Settings for the deploy scripts (Grafana URL/token, window)
```

## Quick start

### On the Linux host (manual)

See **[docs/setup.md](docs/setup.md)** for the full step-by-step guide.

The short version (setup.md also covers the CIS profile, cron, log rotation and
Alloy):

```bash
# 1. Install cinc-auditor
curl -L https://omnitruck.cinc.sh/install.sh | sudo bash -s -- -P cinc-auditor -v 6.8.11

# 2. Install the compliance-json reporter plugin
cd inspec-reporter-compliance-json
/opt/cinc-auditor/embedded/bin/gem build inspec-reporter-compliance-json.gemspec
cinc-auditor plugin install ./inspec-reporter-compliance-json-0.1.0.gem
cd ..

# 3. Copy profiles, scripts, and Alloy config
sudo mkdir -p /opt/audit-profiles
sudo git clone --branch 2.9.0 --depth 1 https://github.com/dev-sec/linux-baseline /opt/audit-profiles/linux-baseline
sudo cp verify.sh /usr/local/bin/verify.sh && sudo chmod +x /usr/local/bin/verify.sh
sudo cp config.alloy /etc/alloy/config.alloy
# 4. Put PROM_URL, PROM_USERNAME, PROM_PASSWORD, LOKI_URL, LOKI_USERNAME and
#    LOKI_PASSWORD in /etc/default/alloy (mode 0600), then start Alloy
```

### On the Linux host (Ansible)

```bash
cd ansible
cp group_vars/all/vars.yml.example group_vars/all/vars.yml
$EDITOR group_vars/all/vars.yml        # Grafana Cloud endpoints and credentials
ansible-vault encrypt group_vars/all/vars.yml
$EDITOR inventory.yml                  # add your host(s)
ansible-playbook -i inventory.yml site.yml --ask-vault-pass
```

### Deploy to Grafana Cloud (from your local machine)

Requires `curl`, `jq`, and `python3-yaml`.

```bash
cp .env.example .env
$EDITOR .env   # GRAFANA_URL, GRAFANA_TOKEN; COMPLIANCE_WINDOW if you scan less often

./scripts/deploy-recording-rules.sh   # must run first
./scripts/deploy-dashboards.sh
./scripts/deploy-alerts.sh
./scripts/deploy-slos.sh

./scripts/validate-grafana.sh         # confirm everything landed correctly
```

## Compliance profiles

| Profile | Frequency | Controls | Purpose |
|---------|-----------|----------|---------|
| `linux-baseline` | Every hour at :05 | ~40 | Fast daily posture check |
| `cis-dil-benchmark` | Every 6h at :15 | ~250 | CIS Level 1 — SOC2/ISO27001 reference |

Nothing is waived by default. Each profile directory has a `waivers.example.yaml`
with common justifications; copy it to `waivers.yaml`, keep what applies to your
hosts and set your own expiry dates (the Ansible role and `verify.sh` only use
`waivers.yaml`). Review waivers quarterly.

If you change the schedule, set `COMPLIANCE_WINDOW` in `.env` to more than the
longest interval between two scans of a profile (default `13h`; `26h` for daily
scans) and redeploy the recording rules and alerts.

## Metrics

All Prometheus metrics are derived from Loki recording rules — no scraping required
on the host.

| Metric | Description |
|--------|-------------|
| `cinc_auditor_compliance_score` | Fraction of controls passing (0.0–1.0) |
| `cinc_auditor_controls_total{status}` | Count by passed/failed/waived/skipped/total |
| `cinc_auditor_control_status` | Per-control, failed controls only (value 0) |
| `cinc_auditor_scan_duration_seconds` | Last scan runtime |
| `cinc_auditor_last_scan_timestamp_seconds` | Unix timestamp of last completed scan |

## Developer tooling

```bash
./scripts/lint.sh   # runs shellcheck on all shell scripts
```

## Credential files (gitignored)

| File | Purpose |
|------|---------|
| `.env` | Grafana URL/token and settings for the deploy scripts |
| `ansible/group_vars/all/vars.yml` | Alloy endpoints and credentials for the Ansible role |

## Stack

| Component | Role |
|-----------|------|
| [cinc-auditor](https://cinc.sh/) | InSpec-compatible audit runner (open-source) |
| [dev-sec profiles](https://dev-sec.io/) | Community-maintained hardening profiles |
| [Grafana Alloy](https://grafana.com/docs/alloy/) | Telemetry collection agent |
| [Grafana Cloud](https://grafana.com/products/cloud/) | Loki, Prometheus, dashboards, alerting, SLOs |
