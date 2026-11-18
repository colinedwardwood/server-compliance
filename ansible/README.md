# Ansible — Server Compliance Deployment

Deploys the cinc-auditor compliance scanning stack to Ubuntu 24 hosts.

## What it installs

| Component | Notes |
|---|---|
| `cinc-auditor` | InSpec-compatible audit runner (via omnitruck installer) |
| `compliance-json` reporter | Custom InSpec plugin → JSON log lines for Loki |
| `curl`, `cron` | Runtime dependencies |
| `verify.sh` | Scan wrapper script → `/usr/local/bin/verify.sh` |
| `linux-baseline` profile | dev-sec/linux-baseline, hourly at :05 |
| `cis-dil-benchmark` profile | dev-sec/cis-dil-benchmark, every 6 h at :15 |
| Waivers (optional) | `compliance-profiles/<profile>/waivers.yaml`, only if you create one |
| Grafana Alloy | Ships JSON logs to Grafana Cloud Loki |
| logrotate | Rotates logs in `/var/log/cinc-auditor/` |

## Prerequisites

- Ansible ≥ 2.14 on your local machine
- SSH access to target hosts with passwordless `sudo`
- A Grafana Cloud stack (free tier is fine) with Prometheus and Loki credentials

## Quick start

```bash
# 1. Install Ansible if needed
pip install ansible

# 2. Copy and fill in endpoints and credentials
cp group_vars/all/vars.yml.example group_vars/all/vars.yml
$EDITOR group_vars/all/vars.yml

# 2b. Optional: start from the example waivers and keep only what applies to you
cp ../compliance-profiles/cis-dil-benchmark/waivers.example.yaml \
   ../compliance-profiles/cis-dil-benchmark/waivers.yaml

# 3. Encrypt the credential file with Vault (recommended)
ansible-vault encrypt group_vars/all/vars.yml

# 4. Update inventory.yml with your host(s)
$EDITOR inventory.yml

# 5. Run the playbook
ansible-playbook -i inventory.yml site.yml --ask-vault-pass
```

## Credentials

Grafana Cloud credentials are written to `/etc/default/alloy` (mode 0600) on
each host and loaded by Alloy via `sys.env()`. They are **never** embedded in the
Alloy config file itself.

Find your credentials at:
**Grafana Cloud → Your Stack → Grafana Data Sources → Prometheus / Loki**

The username is the numeric instance ID; the password is a Cloud Access Token.

## Variables

All variables are documented with defaults in
`roles/server-compliance/defaults/main.yml`.

| Variable | Default | Description |
|---|---|---|
| `grafana_prom_username` | *(required)* | Prometheus instance ID |
| `grafana_prom_password` | *(required)* | Prometheus API token |
| `grafana_loki_username` | *(required)* | Loki instance ID |
| `grafana_loki_password` | *(required)* | Loki API token |
| `grafana_prom_url` | *(required)* | Prometheus remote-write URL for your stack's region |
| `grafana_loki_url` | *(required)* | Loki push URL for your stack's region |
| `compliance_profiles` | linux-baseline, cis-dil-benchmark | Profiles, versions and cron schedules; `enabled: false` removes a profile's cron job |
| `compliance_waivers_dir` | `../compliance-profiles` | Where `<profile>/waivers.yaml` files are looked up on the controller |
| `audit_profiles_base` | `/opt/audit-profiles` | Where profiles are stored |
| `audit_log_dir` | `/var/log/cinc-auditor` | Log output directory |
| `compliance_cron_user` | `root` | User that runs cron jobs |
| `logrotate_rotate` | `14` | Days of logs to retain |
| `logrotate_size` | `50M` | Max size before rotation |

## Waivers

Nothing is waived by default. The repo ships `waivers.example.yaml` files with common
justifications (older CPUs, container hosts, VPN forwarding, partition layout). Copy one
to `waivers.yaml` next to it, keep only the entries that apply, and set your own
`expiration_date`s; the role deploys a profile's `waivers.yaml` only if it exists.

Upgrading from a version that deployed the example waivers automatically: those files
stay on your hosts until you create your own `waivers.yaml` (which replaces them) or
delete `/opt/audit-profiles/<profile>/waivers.yaml` yourself.

## Scan schedule and the compliance window

The Loki recording rules and the `ComplianceScanStale` alert use `COMPLIANCE_WINDOW`
(set in the repo's `.env`, default `13h`) when you deploy them with `scripts/`. It must
be longer than the longest interval between two scans of a profile. With the default
schedule above, 13h is right; if you scan once a day, deploy with `COMPLIANCE_WINDOW=26h`.

## Re-running safely

The playbook is fully idempotent. Re-running applies any config or file
changes and restarts Alloy only when its config changes.

## Updating profiles

Profiles are downloaded from GitHub on first run. To force a profile update,
delete the extracted profile directories and symlinks on the target host, then
re-run the playbook:

```bash
rm -rf /opt/audit-profiles/linux-baseline /opt/audit-profiles/linux-baseline-2.9.0
rm -rf /opt/audit-profiles/cis-dil-benchmark /opt/audit-profiles/cis-dil-benchmark-0.4.12
ansible-playbook -i inventory.yml site.yml
```
