# Compliance as Code: How I Built a $0 Security Monitoring Pipeline with Open Source Tools

*A weekend project that produces auditor-ready compliance dashboards for
Linux servers — using cinc-auditor, Grafana Alloy, and Grafana Cloud.*

---

## The Problem

Every compliance framework — SOC 2, ISO 27001, PCI-DSS, HIPAA — asks the
same question: *"Can you prove your servers are configured securely?"*

The traditional answer involves quarterly scans, PDF reports, and screenshots
stapled into audit binders. It is slow, expensive, and stale by the time
anyone reads it.

I wanted something better: **continuous, automated evidence** that my Linux
servers meet the CIS Level 1 benchmark — with dashboards I can share with an
auditor in real time, alerts that wake me up when something regresses, and a
total cost of zero dollars.

Here is what I built, and why I think this approach matters.

## The Architecture

The pipeline has three layers, each handled by a single open-source tool:

```
┌─────────────────────────────────────────────────────────┐
│  Linux Host                                             │
│                                                         │
│  cron ──► verify.sh ──► cinc-auditor                    │
│              │                                          │
│              └── compliance_*.log   (JSON → Loki)       │
│                                                         │
│  Grafana Alloy → Loki → recording rules → Prometheus   │
└─────────────────────────────────────────────────────────┘
```

**cinc-auditor** runs two InSpec-compatible profiles on a cron schedule: the
DevSec `linux-baseline` (every hour) and the CIS Distribution-Independent
Linux Benchmark at Level 1 (every six hours). A shell script (`verify.sh`)
wraps the scan and uses a custom InSpec reporter plugin (`compliance-json`) to
emit structured JSON log lines — one per control result, plus a scan summary.

**Grafana Alloy** tails the log files and ships them to Grafana Cloud Loki
with proper labels and structured metadata. **Loki recording rules** then
derive all Prometheus metrics (compliance score, control counts, per-control
status, scan duration) directly from the log data — no separate textfile
collector or metric exporter needed.

**Grafana Cloud** hosts three dashboards — Fleet Overview, Host Detail, and
Control Detail — providing drill-down from "how is my fleet doing?" to
"why is control os-05 failing on this specific host?"

## The Beauty of Open Source

What makes this possible is the maturity of the open-source ecosystem in 2026.

**cinc-auditor** is a community fork of Chef InSpec, licensed under Apache 2.0.
It runs the same profiles, the same waivers, the same test framework — without
requiring a Chef license. The DevSec project maintains hundreds of hardening
profiles that map directly to CIS, STIG, and other frameworks. You get
enterprise-grade compliance scanning for free.

**Grafana Alloy** replaced a zoo of collection agents (Prometheus node_exporter,
Promtail, Grafana Agent) with a single binary that handles metrics, logs, and
traces. Its `loki.source.file` component tails the JSON events and ships them
to Loki, where recording rules turn log data into Prometheus metrics — no
custom integration needed.

**Grafana** itself barely needs an introduction. The dashboards I built use
standard panels (stat, gauge, table, time series) with standard PromQL and
LogQL queries. They run on Grafana Cloud's free tier, self-hosted Grafana,
or any fork. There is no proprietary plugin, no vendor SDK, no lock-in.

Every component can be swapped. Don't like Grafana? Ship the metrics to
Datadog or VictoriaMetrics. Don't like cinc-auditor? Replace it with OpenSCAP
and adjust the reporter plugin. The interfaces are standard: JSON log lines and
PromQL. That is the power of open source done right.

## Compliance as Code

The entire pipeline is version-controlled:

```
server-compliance/
├── verify.sh                    ← scan wrapper
├── config.alloy                 ← collection config
├── waivers.yaml                 ← justified exceptions
├── cis-dil-benchmark/
│   ├── inputs.yaml              ← CIS Level 1 config
│   └── waivers.yaml             ← CIS-specific exceptions
├── dashboards/                  ← three Grafana dashboards
├── alerts/                      ← SAAFE-model alert rules
├── deploy-dashboards.sh         ← dashboard deployment script
└── ansible/                     ← full deployment automation
```

This means:

1. **Every waiver has a justification and an expiry date.** When an auditor
   asks "why is IPv4 forwarding enabled?", the answer is in `waivers.yaml`:
   *"Tailscale VPN requires it; managed and firewalled by Tailscale and ufw."*
   The waiver expires on a specific date and must be reviewed to renew.

2. **Changes are reviewable.** When someone adds a waiver or modifies the scan
   script, it goes through a pull request. The diff is the audit trail.

3. **Deployment is reproducible.** The Ansible role deploys the entire stack
   to a fresh Ubuntu 24 host with a single `ansible-playbook` command. Every
   host gets the same profiles, the same waivers, the same scan schedule.

4. **Alert rules are part of the codebase.** Using the
   [SAAFE model](https://github.com/grafana/saafe-model), the alert rules
   cover five categories: **Failure** (scan stopped, score at zero, critical
   controls failing), **Error** (score below threshold, excessive failures),
   **Amend** (score dropped, new failures appeared), **Anomaly** (scan
   duration spike, waiver count increase), and **Saturation** (CPU/disk
   pressure on scanned hosts). This turns compliance from a passive dashboard
   into an active incident-response workflow.

## The Cost Argument

Let me be concrete about money.

A commercial compliance platform — Wiz, Lacework, Prisma Cloud, Qualys —
typically costs **$15–50 per host per month**. For a 10-server fleet, that
is $1,800–6,000/year. For 100 servers, $18,000–60,000/year.

This project costs:

| Component | Cost |
|-----------|------|
| cinc-auditor | $0 (Apache 2.0) |
| Grafana Alloy | $0 (Apache 2.0) |
| Grafana Cloud free tier (10K series, 50 GB logs) | $0 |
| **Total for a small fleet (≤20 hosts)** | **$0** |

At scale, the only cost is Grafana Cloud usage. A 100-host fleet generating
five metrics per profile (two profiles) produces ~1,000 active series and
~50,000 log lines per day — well within the pay-as-you-go pricing that
typically runs a few dollars per month.

The trade-off is obvious: you invest engineering time instead of license fees.
For a team that already uses Grafana for monitoring (and most do), the
marginal effort is a weekend to set up and an hour per quarter to review
waivers.

## What This Is Not

This is not a replacement for a full GRC platform if you need policy
management, risk registers, vendor assessments, or board-level reporting.
Tools like Vanta, Drata, or ServiceNow GRC serve that layer.

What this project replaces is the **technical evidence layer** — the continuous
proof that your Linux hosts are actually configured according to the benchmark
you claim to follow. It is the difference between saying "we follow CIS" and
showing a live dashboard with a 96.3% compliance score, a list of justified
exceptions, and an alert history proving you responded to every regression.

## Getting Started

The full source, setup guide, Ansible role, dashboards, and alert rules are
available on GitHub. The setup guide walks through every step from installing
cinc-auditor to deploying dashboards — it takes about 30 minutes for a single
host, or a single `ansible-playbook` command for a fleet.

If you are preparing for SOC 2, hardening a homelab, or just want to know
whether your servers are actually secure — give it a try. The price is right.
