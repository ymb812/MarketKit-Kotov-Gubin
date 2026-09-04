# frozen_string_literal: true

module IntegrationGenerator
  module Analyzer
    class FieldMappingAnalyzer
      ROLE_RULES = {
        %w[amount value sum money] => ["amount", "operation.amount", 0.95],
        %w[currency asset currency_code] => ["currency", "operation.currency", 0.9],
        %w[external_id merchant_reference client_reference] => ["external_id", "operation.id", 0.85],
        %w[recipient destination beneficiary payee] => ["recipient", "operation.payout_requisite", 0.65],
        %w[phone phone_number] => ["recipient_phone", "operation.payout_requisite.phone", 0.65],
        %w[bank_code bic bank_id] => ["recipient_bank_code", "operation.payout_requisite.bank_code", 0.6],
        %w[bank_name] => ["recipient_bank_name", "operation.payout_requisite.bank_name", 0.6],
        %w[card_number pan] => ["recipient_card", "operation.payout_requisite.card_number", 0.6],
        %w[iban account_number] => ["recipient_account", "operation.payout_requisite.account", 0.6]
      }.freeze
      ID_PARAMETER_NAMES = %w[id payout_id transfer_id transaction_id operation_id].freeze
      IDEMPOTENCY_PARAMETER_NAMES = %w[idempotency_key idempotency_token].freeze

      RESPONSE_ROLES = {
        %w[id payout_id transfer_id transaction_id] => ["provider_operation_id", 0.85],
        %w[external_id merchant_reference client_reference] => ["external_id", 0.9],
        %w[status state payout_status transfer_status] => ["status", 0.95]
      }.freeze

      def analyze(operations, capabilities)
        warnings = []
        create_capability = capabilities.fetch("create_payout")
        create_operation = find_operation(operations, create_capability)
        create_mapping, request_schema = create_mapping(create_operation, create_capability, warnings)
        amount_transform = if create_operation
                             amount_transformation(create_operation, create_mapping["request"], warnings)
                           else
                             unknown_amount_value(nil, "Create payout operation is missing")
                           end
        conditions = create_operation ? conditional_requirements(request_schema, warnings) : []

        {
          "field_mappings" => {
            "create_payout" => create_mapping,
            "fetch_status" => operation_mapping("fetch_status", operations, capabilities, warnings),
            "cancel_payout" => operation_mapping("cancel_payout", operations, capabilities, warnings)
          },
          "transformations" => {
            "amount" => amount_transform,
            "conditional_requirements" => conditions
          },
          "warnings" => warnings
        }
      end

      private

      def find_operation(operations, capability)
        operations.find { |candidate| Support.operation_key(candidate) == capability["operation_key"] }
      end

      def create_mapping(operation, capability, warnings)
        return [{ "status" => "missing", "operation_key" => nil, "request" => [], "response" => [] }, nil] unless operation

        _media_type, request_media = Support.json_content(operation.dig("request_body", "content"))
        request_schema = request_media&.fetch("schema", nil)
        [{
          "status" => capability["status"],
          "operation_key" => Support.operation_key(operation),
          "request" => request_mappings(request_schema, warnings) + parameter_mappings(operation, warnings),
          "response" => response_mappings(operation)
        }, request_schema]
      end

      def operation_mapping(intent, operations, capabilities, warnings)
        capability = capabilities.fetch(intent)
        operation = find_operation(operations, capability)
        return { "status" => "missing", "operation_key" => nil, "request" => [], "response" => [] } unless operation

        candidates = operation.fetch("parameters", []).filter_map do |parameter|
          tokens = Support.tokenize(parameter["name"])
          next unless Support.intersection?(tokens, ID_PARAMETER_NAMES)

          confidence = parameter["in"] == "path" ? 0.95 : 0.75
          {
            "role" => "provider_operation_id",
            "target" => parameter["name"],
            "location" => parameter["in"],
            "source_candidate" => "operation.provider_operation_id",
            "required" => parameter["required"],
            "confidence" => confidence,
            "provenance" => "inferred",
            "requires_review" => confidence < 0.8,
            "evidence" => "identifier-like #{parameter['in']} parameter"
          }
        end
        if candidates.empty?
          warnings << Support.warning(
            "PROVIDER_OPERATION_ID_MAPPING_NOT_FOUND",
            "No provider operation id parameter mapping was found for '#{intent}'",
            location: "#/field_mappings/#{intent}/request"
          )
        elsif candidates.length > 1
          warnings << Support.warning(
            "AMBIGUOUS_PROVIDER_OPERATION_ID_MAPPING",
            "Multiple provider operation id parameter candidates were found for '#{intent}'",
            location: "#/field_mappings/#{intent}/request"
          )
        end

        {
          "status" => capability["status"],
          "operation_key" => Support.operation_key(operation),
          "request" => candidates,
          "response" => response_mappings(operation)
        }
      end

      def request_mappings(schema, warnings)
        required = required_paths(schema)
        mappings = Support.schema_entries(schema).filter_map do |path, child|
          rule = role_rule(path)
          next unless rule

          role, source, confidence = rule
          {
            "role" => role,
            "target" => path,
            "location" => "body",
            "source_candidate" => source,
            "required" => required.include?(path),
            "schema" => Support.compact_schema(child),
            "confidence" => confidence,
            "provenance" => "inferred",
            "requires_review" => confidence < 0.8,
            "evidence" => "provider field name matches '#{path.split('.').last}'"
          }
        end

        top_level_required = schema.is_a?(Hash) ? schema.fetch("required", []) : []
        top_level_required.each do |name|
          next if mappings.any? { |mapping| mapping["target"] == name }

          child = schema.dig("properties", name)
          warnings << Support.warning(
            "REQUIRED_REQUEST_BODY_MAPPING_NOT_FOUND",
            "Required request body field '#{name}' needs an explicit host operation source",
            location: "#/field_mappings/create_payout/request/#{name}"
          )
          mappings << {
            "role" => "unmapped_required",
            "target" => name,
            "location" => "body",
            "source_candidate" => nil,
            "required" => true,
            "schema" => Support.compact_schema(child),
            "confidence" => 0.0,
            "provenance" => "inferred",
            "requires_review" => true,
            "evidence" => "required provider field has no generic host mapping rule"
          }
        end
        mappings
      end

      def parameter_mappings(operation, warnings)
        operation.fetch("parameters", []).map do |parameter|
          normalized_name = Support.tokenize(parameter["name"]).join("_")
          if IDEMPOTENCY_PARAMETER_NAMES.include?(normalized_name)
            warnings << Support.warning(
              "IDEMPOTENCY_SOURCE_REQUIRES_REVIEW",
              "Idempotency parameter '#{parameter['name']}' needs an explicit host operation source",
              location: "#/field_mappings/create_payout/request/#{parameter['name']}"
            )
            {
              "role" => "idempotency_key",
              "target" => parameter["name"],
              "location" => parameter["in"],
              "source_candidate" => "operation.idempotency_key",
              "required" => parameter["required"],
              "schema" => Support.compact_schema(parameter["schema"]),
              "confidence" => 0.7,
              "provenance" => "inferred",
              "requires_review" => true,
              "evidence" => "parameter name has idempotency semantics; host field is a candidate"
            }
          else
            warnings << Support.warning(
              "REQUEST_PARAMETER_MAPPING_NOT_FOUND",
              "No internal source mapping was inferred for #{parameter['in']} parameter '#{parameter['name']}'",
              location: "#/field_mappings/create_payout/request/#{parameter['name']}"
            )
            {
              "role" => "unmapped_parameter",
              "target" => parameter["name"],
              "location" => parameter["in"],
              "source_candidate" => nil,
              "required" => parameter["required"],
              "schema" => Support.compact_schema(parameter["schema"]),
              "confidence" => 0.0,
              "provenance" => "inferred",
              "requires_review" => true,
              "evidence" => "no generic parameter rule matched"
            }
          end
        end
      end

      def response_mappings(operation)
        success = operation.fetch("responses", {}).find { |status, _response| status.to_s.match?(/\A2\d\d\z/) }
        return [] unless success

        status, response = success
        _media_type, media = Support.json_content(response["content"])
        Support.schema_entries(media&.fetch("schema", nil)).filter_map do |path, child|
          rule = response_role(path)
          next unless rule

          role, confidence = rule
          {
            "role" => role,
            "source" => path,
            "http_status" => status,
            "schema" => Support.compact_schema(child),
            "confidence" => confidence,
            "provenance" => "inferred"
          }
        end
      end

      def amount_transformation(operation, mappings, warnings)
        amount = mappings.find { |mapping| mapping["role"] == "amount" }
        return unknown_amount(warnings, "No amount-like request field was found") unless amount

        text = [operation["description"], amount.dig("schema", "description")].compact.join(" ")
        if text.match?(/копе(?:й|ек|йк)|kopecks?|cents?/i)
          {
            "provider_field" => amount["target"],
            "provider_unit" => "minor",
            "direction" => "major_to_minor",
            "factor" => 100,
            "confidence" => 0.95,
            "provenance" => "inferred",
            "requires_review" => false,
            "evidence" => "amount description declares a hundredth monetary subunit"
          }
        elsif text.match?(/minor[\s_-]*units?/i)
          warnings << Support.warning(
            "AMOUNT_FACTOR_AMBIGUOUS",
            "Provider expects minor units, but the exact currency exponent/factor requires review",
            location: "#/transformations/amount/factor"
          )
          {
            "provider_field" => amount["target"],
            "provider_unit" => "minor",
            "direction" => "major_to_minor",
            "factor" => nil,
            "confidence" => 0.7,
            "provenance" => "inferred",
            "requires_review" => true,
            "evidence" => "amount description declares minor units without an exact exponent"
          }
        else
          unknown_amount(warnings, "Amount unit is not structurally clear from OpenAPI", amount["target"])
        end
      end

      def unknown_amount(warnings, message, provider_field = nil)
        warnings << Support.warning(
          "AMOUNT_UNIT_AMBIGUOUS",
          message,
          location: "#/transformations/amount"
        )
        unknown_amount_value(provider_field, message)
      end

      def unknown_amount_value(provider_field, message)
        {
          "provider_field" => provider_field,
          "provider_unit" => "unknown",
          "direction" => nil,
          "factor" => nil,
          "confidence" => 0.0,
          "provenance" => "inferred",
          "requires_review" => true,
          "evidence" => message
        }
      end

      def conditional_requirements(schema, warnings)
        Support.schema_entries(schema).filter_map do |path, child|
          description = child["description"].to_s
          match = description.match(/(?:обязател(?:ен|ьна|ьно)|required(?:\s+only)?)[^=]*(?:для|when|for)\s+([a-zA-Z0-9_.-]+)\s*=\s*([a-zA-Z0-9_.-]+)/i)
          next unless match

          parent = path.split(".")[0...-1]
          condition_path = (parent + [match[1]]).join(".")
          warnings << Support.warning(
            "CONDITIONAL_REQUIREMENT_INFERRED",
            "Conditional requirement for '#{path}' was inferred from description text and requires review",
            location: "#/transformations/conditional_requirements/#{path}"
          )
          {
            "field" => path,
            "required_if" => { "field" => condition_path, "equals" => match[2] },
            "confidence" => 0.75,
            "provenance" => "inferred_text",
            "requires_review" => true,
            "evidence" => description
          }
        end
      end

      def required_paths(schema, prefix = nil)
        return [] unless schema.is_a?(Hash)

        paths = schema.fetch("required", []).map { |name| [prefix, name].compact.join(".") }
        schema.fetch("properties", {}).each do |name, child|
          child_prefix = [prefix, name].compact.join(".")
          paths.concat(required_paths(child, child_prefix))
        end
        paths
      end

      def role_rule(path)
        leaf = path.split(".").last.to_s.delete_suffix("[]")
        ROLE_RULES.each { |names, rule| return rule if names.include?(leaf) }
        nil
      end

      def response_role(path)
        leaf = path.split(".").last.to_s.delete_suffix("[]")
        RESPONSE_ROLES.each { |names, rule| return rule if names.include?(leaf) }
        nil
      end
    end
  end
end
