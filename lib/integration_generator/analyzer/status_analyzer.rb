# frozen_string_literal: true

module IntegrationGenerator
  module Analyzer
    class StatusAnalyzer
      NORMALIZED_STATUSES = {
        "approved" => %w[completed complete succeeded success paid done settled approved],
        "rejected" => %w[failed failure rejected declined cancelled canceled error aborted voided],
        "in_progress" => %w[pending processing created new queued in_progress initiated]
      }.freeze
      FIELD_NAMES = %w[status state payment_status transfer_status payout_status].freeze

      class << self
        def normalize(value)
          canonical = value.to_s.downcase.tr(" -", "_")
          match = NORMALIZED_STATUSES.find { |_normalized, provider_values| provider_values.include?(canonical) }
          match&.first
        end
      end

      CAPABILITY_PRIORITY = %w[fetch_status create_payout cancel_payout webhook].freeze

      def analyze(operations, capabilities)
        fields = extract_fields(operations, capabilities)
        warnings = []
        mappings = {}

        fields.each do |field|
          field["values"].each do |value|
            next if mappings.key?(value)

            normalized = self.class.normalize(value)
            if normalized
              mappings[value] = {
                "normalized" => normalized,
                "confidence" => 0.9,
                "provenance" => "default_rule",
                "evidence" => "known status synonym"
              }
            else
              mappings[value] = {
                "normalized" => "unknown",
                "confidence" => 0.0,
                "provenance" => "inferred",
                "requires_review" => true,
                "evidence" => "status value is not present in the default rule set"
              }
              warnings << Support.warning(
                "UNKNOWN_STATUS",
                "Provider status '#{value}' requires an explicit mapping",
                location: "#/status_mapping/mappings/#{value}"
              )
            end
          end
        end

        if fields.empty?
          warnings << Support.warning(
            "STATUS_FIELD_NOT_FOUND",
            "No enum-backed status/state field was found in operation schemas",
            location: "#/status_mapping"
          )
        else
          warnings << Support.warning(
            "STATUS_MAPPING_DEFAULT_RULES_APPLIED",
            "Status mappings use the generic default synonym rules and should be reviewed for provider semantics",
            location: "#/status_mapping/mappings"
          )
          enum_sets = fields.map { |field| field["values"].map { |value| value.to_s.downcase }.sort }.uniq
          if enum_sets.length > 1
            warnings << Support.warning(
              "CONFLICTING_STATUS_ENUMS",
              "Capability operations expose different status enum sets and require review",
              location: "#/status_mapping/fields"
            )
          end
        end

        {
          "status_mapping" => {
            "fields" => fields,
            "selected" => fields.first,
            "mappings" => mappings,
            "unknown_status" => "requires_review"
          },
          "warnings" => warnings
        }
      end

      private

      def extract_fields(operations, capabilities)
        fields = []
        CAPABILITY_PRIORITY.each do |intent|
          capability = capabilities.fetch(intent)
          next unless capability["operation_key"]

          operation = operations.find { |candidate| Support.operation_key(candidate) == capability["operation_key"] }
          next unless operation

          if intent == "webhook"
            Support.request_schema_entries(operation).each do |path, schema, _media_type|
              add_field(fields, intent, Support.operation_key(operation), "request", path, schema)
            end
          else
            Support.response_schema_entries(operation).each do |path, schema, status, _media_type|
              add_field(fields, intent, Support.operation_key(operation), "response:#{status}", path, schema)
            end
          end
        end
        fields.uniq { |field| [field["operation_key"], field["direction"], field["path"], field["values"]] }
      end

      def add_field(fields, intent, operation_key, direction, path, schema)
        field_name = path.split(".").last.to_s.delete_suffix("[]")
        return unless FIELD_NAMES.include?(field_name)

        values = schema.fetch("enum", []).select { |value| value.is_a?(String) }
        return if values.empty?

        fields << {
          "intent" => intent,
          "operation_key" => operation_key,
          "direction" => direction,
          "path" => path,
          "values" => values
        }
      end
    end
  end
end
