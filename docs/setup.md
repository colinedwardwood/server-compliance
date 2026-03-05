# Linux Compliance Pipeline — Setup Guide

Automated CIS/DevSec baseline scanning with cinc-auditor, metric export via
Grafana Alloy, and dashboards in Grafana Cloud.

```
Linux host
  └─ cinc-auditor (cron — hourly + every 6 h)
       └─ compliance-json reporter → /var/log/cinc-auditor/compliance_<profile>_<ts>.log
                                     (one JSON line per control + scan summary)

Grafana Alloy
  └─ loki.source.file → stage.json → Grafana Cloud Loki

Grafana Cloud Loki
  └─ Recording rules → derive Prometheus metrics from log data:
       cinc_auditor_control_status, cinc_auditor_controls_total,
       cinc_auditor_compliance_score, cinc_auditor_scan_duration_seconds,
       cinc_auditor_last_scan_timestamp_seconds

Grafana Cloud
  ├─ Compliance dashboards (Fleet, Host, Control)
  ├─ SAAFE-model alert rules (PromQL against recording-rule metrics)
  └─ SLOs with burn-rate alerting
```

---

## 1. Prerequisites

On the **Ubuntu host** where scans will run:

```bash
sudo apt update && sudo apt install -y cron git wget shellcheck
```

---

## 2. Install cinc-auditor and the compliance-json reporter

```bash
curl -L https://omnitruck.cinc.sh/install.sh | sudo bash -s -- -P cinc-auditor -v 4
cinc-auditor version   # verify

# Build and install the custom reporter plugin using cinc-auditor's embedded Ruby
cd inspec-reporter-compliance-json
/opt/cinc-auditor/embedded/bin/gem build inspec-reporter-compliance-json.gemspec
cinc-auditor plugin install ./inspec-reporter-compliance-json-0.1.0.gem
cinc-auditor plugin list   # verify: should show inspec-reporter-compliance-json
cd ..
```

The `compliance-json` reporter outputs one JSON line per control result plus
a scan summary line. Grafana Alloy tails these files and pushes them to Loki.
Loki recording rules then derive all Prometheus metrics from the log data —
no textfile collector or separate metric exporter needed.

---

## 3. Download compliance profiles, inputs, and waivers

Two profiles are run on every scan cycle:

| Profile | Controls | Framework |
|---------|----------|-----------|
| `dev-sec/linux-baseline` | ~40 | Practical hardening quick-check |
| `dev-sec/cis-dil-benchmark` | ~250 | **CIS Level 1** — industry-standard, maps to SOC2/ISO27001 |

```bash
sudo mkdir -p /opt/audit-profiles

# linux-baseline (quick hourly check) — pinned to v2.9.0
sudo git clone --branch 2.9.0 --depth 1 \
  https://github.com/dev-sec/linux-baseline /opt/audit-profiles/linux-baseline
sudo cp compliance-profiles/linux-baseline/waivers.yaml \
  /opt/audit-profiles/linux-baseline/waivers.yaml

# CIS Distribution-Independent Linux Level 1 — pinned to v0.4.12
sudo git clone --branch 0.4.12 --depth 1 \
  https://github.com/dev-sec/cis-dil-benchmark /opt/audit-profiles/cis-dil-benchmark
sudo cp compliance-profiles/cis-dil-benchmark/inputs.yaml \
  /opt/audit-profiles/cis-dil-benchmark/inputs.yaml
sudo cp compliance-profiles/cis-dil-benchmark/waivers.yaml \
  /opt/audit-profiles/cis-dil-benchmark/waivers.yaml
```

> **Why CIS over STIG?** STIG targets classified government systems (DoD PKI,
> CAC readers, specific audit configurations). CIS Level 1 is the right choice
> for servers in general — it's what most compliance frameworks (SOC 2, ISO 27001,
> PCI-DSS, HIPAA) reference, and Level 1 is designed not to break legitimate
> workloads.

---

## 4. Set up output directory

```bash
sudo mkdir -p /var/log/cinc-auditor
sudo chown root:adm /var/log/cinc-auditor
sudo chmod 755 /var/log/cinc-auditor
```

---

## 5. Install the scan script

```bash
sudo cp verify.sh /usr/local/bin/verify.sh
sudo chmod +x /usr/local/bin/verify.sh

# Smoke test (runs the linux-baseline scan)
sudo AUDIT_PROFILES_BASE=/opt/audit-profiles /usr/local/bin/verify.sh linux-baseline
```

The script produces two outputs on every run:

| Output | Path | Consumer |
|--------|------|----------|
| JSON log lines (one per control + summary) | `/var/log/cinc-auditor/compliance_<profile>_<ts>.log` | Alloy → Loki → recording rules → Prometheus |
| Raw InSpec JSON report | `/var/log/cinc-auditor/report_<profile>_<ts>.json` | Archive / debugging |

---

## 6. Install the cron jobs

Both profiles are staggered to avoid resource contention.

```bash
sudo systemctl enable --now cron

(sudo crontab -l 2>/dev/null; cat <<'EOF'
# Linux compliance scans — staggered to avoid overlap
# linux-baseline: quick (~30s), every hour at :05
5 * * * *          AUDIT_PROFILES_BASE=/opt/audit-profiles /usr/local/bin/verify.sh linux-baseline >> /var/log/cinc-auditor/cron_linux_baseline.log 2>&1
# CIS Level 1: thorough (~3-5 min), every 6 hours at :15
15 0,6,12,18 * * * AUDIT_PROFILES_BASE=/opt/audit-profiles /usr/local/bin/verify.sh cis-dil-benchmark >> /var/log/cinc-auditor/cron_cis_dil_benchmark.log 2>&1
EOF
) | sudo crontab -

sudo crontab -l   # verify
```

---

## 7. Set up log rotation

```bash
sudo tee /etc/logrotate.d/cinc-auditor > /dev/null <<'EOF'
/var/log/cinc-auditor/*.log {
    daily
    rotate 14
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su root adm
}
EOF
```

> `verify.sh` prunes JSON report files automatically, keeping the last 48 runs
> per profile, so they do not need logrotate coverage.

---

## 8. Install and configure Grafana Alloy

### 8a. Install Alloy

```bash
sudo mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key \
  | gpg --dearmor \
  | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null

echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list

sudo apt update && sudo apt install -y alloy
```

### 8b. Store credentials securely

`config.alloy` reads credentials from environment variables so they are
never hard-coded in the config file.

```bash
# Find your instance IDs and tokens at:
#   Grafana Cloud → Your Stack → Grafana Data Sources → Prometheus / Loki
sudo tee /etc/default/alloy > /dev/null <<'EOF'
PROM_USERNAME=<your-prometheus-instance-id>
PROM_PASSWORD=<your-prometheus-api-token>
LOKI_USERNAME=<your-loki-instance-id>
LOKI_PASSWORD=<your-loki-api-token>
EOF

sudo chmod 600 /etc/default/alloy
```

### 8c. Deploy the Alloy config

```bash
sudo cp config.alloy /etc/alloy/config.alloy
sudo systemctl enable --now alloy
sudo systemctl status alloy
```

### 8d. Verify Alloy is shipping data

```bash
sudo journalctl -u alloy -f

# Confirm JSON log files are being written after the first scan
ls -1 /var/log/cinc-auditor/compliance_*.log
tail -5 /var/log/cinc-auditor/compliance_linux_baseline_*.log | jq .
```

---

## 9. Deploy to Grafana Cloud

Run these scripts from your **local machine** (not the Ubuntu host).

**Local requirements:** `curl` and `jq`.
- macOS: `brew install jq`
- Linux: `sudo apt install -y curl jq`

```bash
# Fill in your Grafana Cloud service account token (one-time)
cp .env.example .env
$EDITOR .env

# Deploy everything
./deploy-recording-rules.sh   # Loki recording rules → Prometheus metrics
./deploy-dashboards.sh        # 3 dashboards → Compliance folder
./deploy-alerts.sh            # 12 SAAFE-model alert rules (also needs python3-yaml)
./deploy-slos.sh              # 2 compliance score SLOs (needs Grafana Cloud SLO feature)
```

The scripts auto-detect your Prometheus and Loki datasource UIDs. If you have
multiple datasources of the same type, pin them explicitly in `.env`:

```bash
GRAFANA_PROM_DS=grafana-cloud-prom
GRAFANA_LOKI_DS=grafana-cloud-logs
```

Dashboards auto-populate once the first scan has run and Loki recording rules
have had one evaluation cycle (~5 minutes).

---

## 10. Updating pinned profile versions

Profiles are pinned to specific release tags for reproducible scans.
To upgrade:

1. Check for new releases:
   - <https://github.com/dev-sec/linux-baseline/releases>
   - <https://github.com/dev-sec/cis-dil-benchmark/releases>
2. Update the tag in `ansible/roles/server-compliance/defaults/main.yml`
3. Re-clone the profile at the new tag:

```bash
sudo rm -rf /opt/audit-profiles/linux-baseline
sudo git clone --branch <new-tag> --depth 1 \
  https://github.com/dev-sec/linux-baseline /opt/audit-profiles/linux-baseline
sudo cp compliance-profiles/linux-baseline/waivers.yaml \
  /opt/audit-profiles/linux-baseline/waivers.yaml
```

Review the profile changelog before upgrading — new controls may introduce
failures that need waivers.

---

## Metrics reference

All Prometheus metrics are derived from Loki log data via recording rules
(`grafana-cloud/recording-rules/compliance-recording-rules.yaml`).

| Metric | Labels | Description |
|--------|--------|-------------|
| `cinc_auditor_compliance_score` | host, profile | Fraction passing (0.0–1.0), excluding waived/skipped |
| `cinc_auditor_controls_total` | host, profile, status | Count by passed/failed/waived/skipped/total |
| `cinc_auditor_control_status` | host, profile, control, severity | 1=passed, 0=failed, -1=skipped, -2=waived |
| `cinc_auditor_scan_duration_seconds` | host, profile | How long the last scan took |
| `cinc_auditor_last_scan_timestamp_seconds` | host, profile | Unix timestamp of last scan |

---

## Loki label reference

| Label | Values | Description |
|-------|--------|-------------|
| `job` | `custom/cinc_auditor` | Stream selector |
| `instance` | hostname | Which host the scan ran on |
| `host` | hostname | From JSON log line |
| `profile` | `linux-baseline`, `cis-dil-benchmark` | Profile name |
| `status` | `passed`, `failed`, `waived`, `skipped` | Control result |
| `severity` | `critical`, `high`, `medium`, `low`, `informational` | From InSpec impact score |
| `level` | `info`, `warn` | `warn` for failed/waived controls |

High-cardinality fields are stored as **structured metadata** (not stream labels).
Query them with `| json`:

| Field | Description |
|-------|-------------|
| `control` | Control ID (e.g. `os-05`, `cis-dil-benchmark-1.1.2`) |
| `impact` | Numeric impact score (0.0–1.0) |
| `title` | One-line control title |
| `desc` | Full control description |

```logql
# All failed controls on any host
{job="custom/cinc_auditor", status="failed"}

# Critical failures on a specific host
{job="custom/cinc_auditor", host="myserver", severity="critical", status="failed"}

# All results for a specific control across all hosts
{job="custom/cinc_auditor"} | json | control="os-05"

# Controls that changed to failed in the last hour
count_over_time({job="custom/cinc_auditor", status="failed"}[1h])
```

---

## Alert rules

Pre-built Prometheus alert rules in `grafana-cloud/alerts/compliance-alerts.yaml`,
organized using the [SAAFE model](https://github.com/grafana/saafe-model):

| Category | Alert | Severity | What it catches |
|----------|-------|----------|-----------------|
| **Failure** | `ComplianceScanStale` | critical | No scan results in >2 hours |
| **Failure** | `ComplianceScoreZero` | critical | 0% compliance score (total breakdown) |
| **Failure** | `CriticalControlFailing` | critical | Any critical-severity control failing |
| **Error** | `ComplianceScoreLow` | warning | Score below 90% for >30 min |
| **Error** | `HighSeverityFailures` | warning | Any critical/high control failing |
| **Error** | `ExcessiveFailures` | warning | >20% of controls failing |
| **Amend** | `ComplianceScoreDrop` | warning | Score dropped >5% in the last hour |
| **Amend** | `NewFailuresDetected` | info | 3+ new failures in the last hour |
| **Anomaly** | `ScanDurationAnomaly` | info | Scan taking 2× longer than 24h average |
| **Anomaly** | `WaivedControlsIncreasing` | info | 5+ new waivers in 24 hours |
| **Saturation** | `ScanHostHighCPU` | info | >90% CPU on a scanned host |
| **Saturation** | `ScanHostDiskPressure` | warning | <10% disk free on a scanned host |

---

## SLOs (Service Level Objectives)

Defined in `grafana-cloud/slos/compliance-slos.json`, deployed via `./deploy-slos.sh`.
Requires Grafana Cloud with the **grafana-slo-app** plugin enabled.

| SLO | Objective | Window |
|-----|-----------|--------|
| Compliance Score — linux-baseline | avg score ≥ 0.95 | 28 days |
| Compliance Score — cis-dil-benchmark | avg score ≥ 0.90 | 28 days |

Both use a freeform query type — the compliance score is already a 0.0–1.0 value.
Each SLO auto-generates **fast-burn** and **slow-burn** alerts based on error
budget consumption rate. Scan freshness is covered by the `ComplianceScanStale`
alert rule instead of an SLO (the Grafana SLO API cannot evaluate `time()`
expressions in freeform queries).
