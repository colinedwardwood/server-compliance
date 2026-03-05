# Why This Project Matters to Technology Practitioners in 2026

## The compliance landscape today

Compliance is no longer a checkbox exercise for large enterprises. In 2026,
security frameworks like SOC 2, ISO 27001, PCI-DSS, HIPAA, and the EU's NIS2
Directive increasingly require **continuous evidence of compliance** — not just
point-in-time audits. At the same time, cloud costs are rising, and teams are
under pressure to do more with less.

This project sits at the intersection of three converging trends:

### 1. Compliance-as-Code is becoming table stakes

Regulators and auditors are moving away from spreadsheets and screenshots. They
want to see automated evidence: scan results with timestamps, historical trends,
and audit trails. This project turns a compliance scan into a data pipeline —
every control result becomes a Prometheus metric and a Loki log line, queryable
and auditable for months.

**Who benefits:**
- **Platform engineers** building internal developer platforms who need to prove
  their infrastructure meets security baselines.
- **DevOps/SRE teams** at startups approaching SOC 2 or ISO 27001 certification
  who need to demonstrate continuous monitoring without hiring a dedicated GRC team.
- **Managed service providers** who need to prove their customer-facing
  infrastructure meets contractual security commitments.
- **Homelab enthusiasts** who want to apply production-grade security practices
  to personal infrastructure.

### 2. Open source observability has matured

Five years ago, building this pipeline would have required stitching together
half a dozen tools with custom glue code. Today, three open-source projects
handle the entire stack:

| Layer | Tool | Why it works |
|-------|------|-------------|
| Scanning | cinc-auditor (InSpec-compatible) | Declarative security profiles, 1000s of community controls |
| Collection | Grafana Alloy | Single binary, native Prometheus + Loki support, JSON log tailing |
| Visualization | Grafana | Industry-standard dashboarding, alerting, free cloud tier |

The entire pipeline is **vendor-neutral**. cinc-auditor runs the same profiles
as Chef InSpec. Grafana Alloy ships to any Prometheus/Loki-compatible backend.
The dashboards work on self-hosted Grafana or any cloud provider.

### 3. Cost pressure is driving consolidation

Security teams are being asked to justify tool spend. A typical commercial
compliance platform (Prisma Cloud, Wiz, Lacework, Qualys) costs $15–50/host/month.
This project achieves similar visibility using:

- **cinc-auditor**: Free, open source (Apache 2.0)
- **Grafana Alloy**: Free, open source (Apache 2.0)
- **Grafana Cloud free tier**: 10,000 series, 50 GB logs — enough for 10–20 hosts
- **Total cost for a small fleet**: $0

Even at scale (100+ hosts), the cost is the Grafana Cloud usage bill — typically
90%+ cheaper than commercial alternatives, with no per-host licensing.

## Who should care about this project

| Persona | Use case |
|---------|----------|
| **Startup CTO** | Need SOC 2 evidence without a security team? This is a weekend project that produces auditor-ready dashboards. |
| **Platform engineer** | Building a PaaS or IDP? Embed compliance scanning into your host provisioning pipeline via the Ansible role. |
| **MSP / consultant** | Managing client infrastructure? Deploy once via Ansible, monitor fleet-wide compliance from a single Grafana dashboard. |
| **Security engineer** | Want to shift-left on CIS benchmarks? This gives you continuous visibility instead of quarterly scan reports. |
| **Homelab operator** | Want production-grade security monitoring for your personal servers? This is exactly that, at zero cost. |

## What makes this approach different

1. **No agents, no SaaS lock-in.** cinc-auditor is a standalone binary that
   runs on cron. Alloy is a single binary that ships data. There is no
   persistent agent, no cloud-to-host control plane, no vendor lock-in.

2. **Compliance results are observability data.** By modeling compliance as
   metrics and logs (not a separate silo), teams can correlate security posture
   with operational health — e.g., "did this deploy cause a compliance
   regression?" — using the same tools they already use for monitoring.

3. **The SAAFE alert model turns compliance into incident response.** Instead
   of checking a dashboard weekly, the alert rules proactively notify when
   compliance degrades, new failures appear, or scans stop running.

4. **Everything is code.** The profiles, waivers, scan script, collection
   config, dashboards, and alert rules are all version-controlled. Changes
   are reviewable, auditable, and reproducible — which is exactly what
   auditors want to see.
