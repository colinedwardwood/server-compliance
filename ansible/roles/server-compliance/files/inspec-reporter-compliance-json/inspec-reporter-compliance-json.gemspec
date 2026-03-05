require_relative "lib/inspec-reporter-compliance-json/version"

Gem::Specification.new do |s|
  s.name        = "inspec-reporter-compliance-json"
  s.version     = InspecPlugins::ComplianceJson::VERSION
  s.summary     = "InSpec reporter that emits one JSON line per control for Loki ingestion"
  s.description = <<~DESC
    A cinc-auditor / InSpec reporter plugin that outputs one JSON log line per
    control result, plus a scan summary line. Designed to be tailed by Grafana
    Alloy and ingested into Loki, with Loki recording rules deriving Prometheus
    metrics from the log data.
  DESC
  s.authors     = ["Colin Wilson"]
  s.license     = "Apache-2.0"
  s.homepage    = "https://github.com/colinwilson/server-compliance"

  s.files       = Dir["lib/**/*", "*.gemspec", "LICENSE", "README.md"]
  s.require_paths = ["lib"]

  s.required_ruby_version = ">= 3.0"
  s.add_dependency "inspec", ">= 4.0", "< 8.0"
end
