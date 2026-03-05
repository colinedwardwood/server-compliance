module InspecPlugins
  module ComplianceJson
    class Plugin < Inspec.plugin(2)
      plugin_name :"inspec-reporter-compliance-json"

      reporter :"compliance-json" do
        require_relative "reporter"
        InspecPlugins::ComplianceJson::Reporter
      end
    end
  end
end
