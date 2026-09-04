# frozen_string_literal: true

module IntegrationGenerator
  module Analyzer
    class ManifestBuilder
      RULESET_VERSION = "1.0"

      def initialize(document, provider_slug: nil)
        @document = document
        @generic = document.to_h
        @provider_slug = normalize_slug(provider_slug || @generic.dig("info", "title") || "provider")
      end

      def build
        source_operations = @generic.fetch("operations")
        classified_operations = source_operations.map { |operation| build_operation(operation) }
        resolution = CapabilityResolver.new.resolve(classified_operations)
        auth = AuthAnalyzer.new(@provider_slug).analyze(@generic, source_operations)
        statuses = StatusAnalyzer.new.analyze(source_operations, resolution["capabilities"])
        errors = ErrorAnalyzer.new.analyze(source_operations)
        webhook = WebhookAnalyzer.new.analyze(@generic, source_operations, resolution["capabilities"])
        fields = FieldMappingAnalyzer.new.analyze(source_operations, resolution["capabilities"])

        warnings = [
          *@generic.fetch("warnings", []),
          *resolution["warnings"],
          *auth["warnings"],
          *statuses["warnings"],
          *errors["warnings"],
          *webhook["warnings"],
          *fields["warnings"]
        ].uniq { |warning| [warning["code"], warning["message"], warning["location"]] }

        ProviderIR::Manifest.new(
          "provider" => provider,
          "analyzer" => {
            "version" => IntegrationGenerator::VERSION,
            "ruleset_version" => RULESET_VERSION
          },
          "source" => source,
          "servers" => @generic.fetch("servers"),
          "auth" => auth["auth"],
          "operations" => classified_operations,
          "capabilities" => resolution["capabilities"],
          "status_mapping" => statuses["status_mapping"],
          "errors" => errors["errors"],
          "webhook" => webhook["webhook"],
          "field_mappings" => fields["field_mappings"],
          "transformations" => fields["transformations"],
          "unsupported_operations" => resolution["unsupported_operations"],
          "warnings" => warnings,
          "overrides" => {
            "applied" => false,
            "override_version" => nil,
            "file" => nil,
            "source" => nil,
            "reason" => nil,
            "applied_changes" => [],
            "resolved_warnings" => []
          }
        )
      end

      private

      def provider
        {
          "display_name" => @generic.dig("info", "title"),
          "slug" => @provider_slug,
          "api_version" => @generic.dig("info", "version")
        }
      end

      def source
        {
          "openapi_version" => @generic["openapi"],
          "display_path" => @generic.dig("source", "path"),
          "sha256" => @generic.dig("source", "sha256")
        }
      end

      def build_operation(operation)
        classification = OperationClassifier.new.classify(operation)
        ProviderIR::Operation.new(
          "key" => Support.operation_key(operation),
          "operation_id" => operation["operation_id"],
          "method" => operation["method"],
          "path" => operation["path"],
          "summary" => operation["summary"],
          "description" => operation["description"],
          "intent" => classification["intent"],
          "confidence" => classification["confidence"],
          "decision" => classification["decision"],
          "evidence" => classification["evidence"],
          "alternatives" => classification["alternatives"],
          "contract" => compact_contract(operation)
        )
      end

      def compact_contract(operation)
        {
          "servers" => operation["servers"],
          "security" => operation["security"],
          "parameters" => operation.fetch("parameters", []).map { |parameter| compact_parameter(parameter) },
          "request_body" => compact_request_body(operation["request_body"]),
          "responses" => operation.fetch("responses", {}).transform_values { |response| compact_response(response) }
        }
      end

      def compact_parameter(parameter)
        {
          "name" => parameter["name"],
          "in" => parameter["in"],
          "required" => parameter["required"],
          "description" => parameter["description"],
          "schema" => Support.compact_schema(parameter["schema"]),
          "example" => parameter["example"],
          "examples" => parameter["examples"]
        }.reject { |_key, value| value.nil? || value == {} }
      end

      def compact_request_body(request_body)
        return nil unless request_body

        {
          "required" => request_body["required"],
          "description" => request_body["description"],
          "content" => compact_content(request_body["content"])
        }.reject { |_key, value| value.nil? }
      end

      def compact_response(response)
        {
          "description" => response["description"],
          "headers" => response.fetch("headers", {}).transform_values do |header|
            {
              "description" => header["description"],
              "required" => header["required"],
              "schema" => Support.compact_schema(header["schema"]),
              "example" => header["example"]
            }.reject { |_key, value| value.nil? || value == false }
          end,
          "content" => compact_content(response["content"])
        }.reject { |_key, value| value.nil? || value == {} }
      end

      def compact_content(content)
        content.fetch("content", content).transform_values do |media|
          {
            "schema" => Support.compact_schema(media["schema"]),
            "example" => media["example"],
            "examples" => media["examples"]
          }.reject { |_key, value| value.nil? || value == {} }
        end
      end

      def normalize_slug(value)
        slug = value.to_s
                    .gsub(/([[:lower:]\d])([[:upper:]])/, "\\1_\\2")
                    .downcase
                    .gsub(/[^a-z0-9]+/, "_")
                    .gsub(/\A_+|_+\z/, "")
        slug.empty? ? "provider" : slug
      end
    end
  end
end
