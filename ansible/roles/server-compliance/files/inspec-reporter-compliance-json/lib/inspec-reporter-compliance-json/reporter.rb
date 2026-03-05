require "json"
require "socket"

module InspecPlugins
  module ComplianceJson
    class Reporter < Inspec.plugin(2, :reporter)
      # Emit one JSON log line per control, then a scan summary line.
      # Output is designed to be tailed by Grafana Alloy and ingested
      # into Loki, with recording rules deriving Prometheus metrics.
      def render
        host = Socket.gethostname
        ts   = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

        run_data[:profiles].each do |profile|
          profile_name = profile[:name]
          counts = { passed: 0, failed: 0, waived: 0, skipped: 0 }

          (profile[:controls] || []).each do |control|
            status  = determine_status(control)
            impact  = control[:impact] || 0
            sev     = severity(impact)
            sval    = status_value(status)
            level   = %w[failed waived].include?(status) ? "warn" : "info"

            counts[status.to_sym] += 1

            output(JSON.generate(
              ts:         ts,
              type:       "control",
              level:      level,
              host:       host,
              profile:    profile_name,
              control:    control[:id],
              status:     status,
              severity:   sev,
              impact:     impact,
              status_val: sval,
              title:      control[:title] || "",
              desc:       (control[:desc] || "").gsub(/[\n\r\t]/, " ")
            ))
          end

          total     = counts.values.sum
          evaluated = counts[:passed] + counts[:failed]
          score     = evaluated.positive? ? (counts[:passed].to_f / evaluated * 1000).round / 1000.0 : 0

          output(JSON.generate(
            ts:       ts,
            type:     "scan_summary",
            host:     host,
            profile:  profile_name,
            duration: run_data.dig(:statistics, :duration) || 0,
            scan_ts:  Time.now.to_i,
            passed:   counts[:passed],
            failed:   counts[:failed],
            waived:   counts[:waived],
            skipped:  counts[:skipped],
            total:    total,
            score:    score
          ))
        end
      end

      def self.run_data_schema_constraints
        "~> 0.0"
      end

      private

      def determine_status(control)
        wd = control[:waiver_data] || {}
        if wd.is_a?(Hash) && wd.length.positive?
          return wd[:skipped_due_to_waiver] ? "skipped" : "waived"
        end

        results = control[:results] || []
        return "skipped" if results.empty?
        return "failed"  if results.any? { |r| r[:status] == "failed" }
        return "skipped" if results.any? { |r| r[:status] == "skipped" }

        "passed"
      end

      def severity(impact)
        case impact
        when 0.9..Float::INFINITY then "critical"
        when 0.7...0.9            then "high"
        when 0.4...0.7            then "medium"
        when 0.01...0.4           then "low"
        else                           "informational"
        end
      end

      def status_value(status)
        case status
        when "passed"  then  1
        when "failed"  then  0
        when "skipped" then -1
        when "waived"  then -2
        else                -1
        end
      end
    end
  end
end
