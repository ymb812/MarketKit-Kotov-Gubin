# frozen_string_literal: true

module IntegrationGenerator
  module Analyzer
    class AuthAnalyzer
      def initialize(provider_slug)
        @provider_slug = provider_slug
      end

      def analyze(document, operations)
        schemes = normalize_schemes(document.fetch("security_schemes", {}))
        default_requirements, source = default_requirements(document, operations)
        warnings = []
        if default_requirements.nil? || default_requirements.empty?
          warnings << Support.warning(
            "AUTH_NOT_DETECTED",
            "No default authentication requirement could be determined",
            location: "#/auth/default"
          )
        end
        non_empty_requirements = operations.map { |operation| operation["security"].nil? ? document["security"] : operation["security"] }
                                           .compact.reject(&:empty?).uniq
        if non_empty_requirements.length > 1
          warnings << Support.warning(
            "AUTH_REQUIREMENTS_VARY_BY_OPERATION",
            "Capability operations use different authentication requirements; use per-operation auth",
            location: "#/auth/operations"
          )
        end

        {
          "auth" => {
            "schemes" => schemes,
            "default" => {
              "source" => source,
              "suggested" => source == "operation_consensus",
              "requirements" => normalize_requirements(default_requirements, schemes)
            },
            "operations" => operations.each_with_object({}) do |operation, result|
              requirements = operation["security"].nil? ? document["security"] : operation["security"]
              result[Support.operation_key(operation)] = {
                "source" => operation["security"].nil? ? "inherited" : "operation",
                "requirements" => normalize_requirements(requirements, schemes)
              }
            end
          },
          "warnings" => warnings
        }
      end

      private

      def normalize_schemes(schemes)
        schemes.map do |name, scheme|
          {
            "name" => name,
            "type" => scheme["type"],
            "scheme" => scheme["scheme"],
            "location" => scheme["in"],
            "parameter_name" => scheme["name"],
            "bearer_format" => scheme["bearer_format"],
            "supported" => scheme["supported"],
            "config_env" => config_env(scheme)
          }
        end
      end

      def config_env(scheme)
        suffix = case scheme["type"]
                 when "api_key" then "API_KEY"
                 when "http"
                   scheme["scheme"] == "basic" ? "BASIC_AUTH" : "BEARER_TOKEN"
                 else "CREDENTIALS"
                 end
        "#{@provider_slug.upcase.gsub(/[^A-Z0-9]+/, '_')}_#{suffix}"
      end

      def default_requirements(document, operations)
        return [document["security"], "root"] unless document["security"].nil?

        candidates = operations.map { |operation| operation["security"] }.compact.reject(&:empty?)
        return [nil, "none"] if candidates.empty?

        winner = candidates.tally.max_by { |_requirements, count| count }.first
        [winner, "operation_consensus"]
      end

      def normalize_requirements(requirements, schemes)
        return nil if requirements.nil?

        scheme_index = schemes.to_h { |scheme| [scheme["name"], scheme] }
        requirements.map do |requirement|
          names = requirement.keys
          {
            "schemes" => names,
            "scopes" => requirement,
            "supported" => names.all? { |name| scheme_index[name] && scheme_index[name]["supported"] }
          }
        end
      end
    end
  end
end
