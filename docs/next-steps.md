# What to Do Next

Organized by effort and impact. Pick based on what you want to get out of
the project (portfolio piece, production tool, blog content, community project).

---

## Ship it (low effort, high impact)

- [ ] **Initialize git and push to GitHub.** The repo is not a git repo yet.
  Add a LICENSE (Apache 2.0 matches the tools), a top-level README.md (the
  blog post is a good starting point), and push.

- [ ] **Add a GitHub Actions CI workflow.** A 10-line workflow that runs
  `make check` (shellcheck) on every push. Demonstrates CI discipline and
  catches regressions.

- [ ] **Import the alert rules into Grafana Cloud.** The rules exist in
  `alerts/compliance-alerts.yaml` but are not deployed yet. Test them against
  live data and tune thresholds.

---

## Harden (medium effort, high impact)

- [ ] **Add a second host.** The fleet dashboard is designed for multi-host
  visibility but currently only has one host. Adding a second server (a
  cloud VM, a Raspberry Pi, another homelab box) validates the fleet view
  and makes the project more compelling as a portfolio piece.

- [ ] **Add a deploy-alerts.sh script.** Similar to `deploy-dashboards.sh`,
  use the Grafana HTTP API (`/api/v1/provisioning/alert-rules`) to push the
  alert rules from code — completing the "everything deployed from git" story.

- [ ] **Add Windows or container scanning.** cinc-auditor supports Windows
  profiles and Docker/Kubernetes targets. Adding a second OS or a container
  profile demonstrates the framework is extensible, not just a Linux one-trick.

---

## Write about it (medium effort, high visibility)

- [ ] **Publish the blog post.** The draft in `docs/blog-post.md` covers the
  three angles (compliance-as-code, open source, cost). Publish on your
  personal blog, dev.to, Medium, or Hashnode. Cross-post to LinkedIn.

- [ ] **Submit to the Grafana community.** Grafana has a community forum and
  a blog contribution program. A "how I built compliance dashboards with
  Alloy" post fits their content strategy perfectly.

- [ ] **Record a demo video.** A 5-minute screen recording showing the
  dashboards, a failing control, the alert firing, and the waiver workflow
  is more compelling than any README.

---

## Extend (higher effort, differentiating)

- [ ] **Build a Grafana SLO for compliance.** Grafana Cloud supports SLO
  tracking. Define an SLO like "95% compliance score over 30 days" using
  `cinc_auditor_compliance_score` and get burn-rate alerts for free.

- [ ] **Add remediation runbooks.** For each common failing control, write a
  linked runbook (Markdown or Grafana OnCall) that explains how to fix it.
  Link from the Control Detail dashboard panel.

- [ ] **Integrate with Grafana OnCall or PagerDuty.** Route the SAAFE alert
  rules through an incident management tool. This completes the loop from
  detection to response, which auditors love to see.

- [ ] **Add drift detection.** Compare the current scan results against a
  "golden" baseline stored in git. Alert when a host drifts from the
  expected state — not just when controls fail, but when they change at all.

- [ ] **Package as a Grafana plugin or Helm chart.** If you want community
  adoption, package the dashboards + alert rules as a Grafana dashboard
  bundle (via grafana.com) or a Helm chart for Kubernetes-based deployments.

---

## Learn and grow

- [ ] **Study for CIS benchmarks.** The waivers file is a great starting
  point for understanding what each control does and why. Review the CIS
  benchmark PDF alongside your scan results.

- [ ] **Explore SAAFE model deeper.** The demo in the
  [saafe-model repo](https://github.com/grafana/saafe-model) shows how to
  build assertion dashboards that correlate compliance alerts with
  operational events across your whole stack.

- [ ] **Contribute upstream.** If you find bugs or missing controls in
  `dev-sec/linux-baseline` or `dev-sec/cis-dil-benchmark`, submit PRs.
  Open-source contributions to security projects look great on a resume
  and help the community.
