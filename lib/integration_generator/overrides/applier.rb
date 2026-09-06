# frozen_string_literal: true

module IntegrationGenerator
  module Overrides
    class Applier
      VERSION = "1.0"
      ROOT_KEYS = %w[
        override_version source reason operations status_mapping transformations
        field_mappings webhook resolve_warnings
      ].freeze
      OPERATION_KEYS = %w[intent].freeze
      AMOUNT_KEYS = %w[provider_unit direction factor].freeze
      TRANSFORMATION_KEYS = %w[amount conditional_requirements].freeze
      FIELD_MAPPING_KEYS = %w[request].freeze
      REQUEST_MAPPING_KEYS = %w[target location source value confirm].freeze
      CONDITION_KEYS = %w[field required_if].freeze
      REQUIRED_IF_KEYS = %w[field equals].freeze
      WEBHOOK_KEYS = %w[signature payload].freeze
      SIGNATURE_KEYS = %w[header algorithm encoding].freeze
      PAYLOAD_KEYS = %w[event_path status_path provider_operation_id_path external_id_path error_path].freeze
      WARNING_KEYS = %w[code location].freeze
      MAPPABLE_CAPABILITIES = %w[create_payout fetch_status cancel_payout].freeze
      NORMALIZED_STATUSES = %w[approved rejected in_progress unknown].freeze
      AMOUNT_UNITS = %w[major minor].freeze
      AMOUNT_DIRECTIONS = %w[major_to_minor none].freeze
      SIGNATURE_ALGORITHMS = %w[hmac_sha256].freeze
      SIGNATURE_ENCODINGS = %w[hex base64].freeze
      REANALYZED_WARNING_PREFIXES = %w[
        #/operations/ #/capabilities/ #/status_mapping #/webhook #/field_mappings/ #/transformations/
      ].freeze

      def initialize(manifest, overrides, path: nil)
        @attributes = deep_copy(manifest.respond_to?(:to_h) ? manifest.to_h : manifest)
        @overrides = deep_stringify_keys(overrides)
        @path = path
        @changes = []
        @resolved_warnings = []
      end

      def apply
        validate_root!
        apply_operations!
        apply_status_mapping!
        apply_field_mappings!
        apply_amount!
        apply_conditional_requirements!
        apply_webhook!
        apply_warning_resolutions!
        attach_audit!
        ProviderIR::Manifest.new(@attributes)
      rescue ArgumentError, KeyError, NoMethodError, TypeError => e
        raise e if e.is_a?(IntegrationGenerator::Error)

        raise Error.new("OVERRIDES_INVALID", e.message, location: @path)
      end

      private

      def validate_root!
        expect_hash!(@attributes, "inferred manifest", "#")
        expect_hash!(@overrides, "overrides", "#")
        reject_unknown_keys!(@overrides, ROOT_KEYS, "#")

        version = @overrides["override_version"]
        unless version == VERSION
          invalid_value!("override_version must be #{VERSION.inspect}, got #{version.inspect}", "#/override_version")
        end
        %w[source reason].each do |key|
          value = @overrides[key]
          unless value.is_a?(String) && !value.strip.empty?
            invalid_value!("#{key} must be a non-empty string", "#/#{key}")
          end
        end

        actionable = ROOT_KEYS - %w[override_version source reason resolve_warnings]
        unless actionable.any? { |key| @overrides.key?(key) }
          invalid_value!("At least one override section must be provided", "#")
        end

        if @overrides.key?("transformations")
          transformations = expect_hash!(@overrides["transformations"], "transformations", "#/transformations")
          reject_unknown_keys!(transformations, TRANSFORMATION_KEYS, "#/transformations")
        end
      end

      def apply_operations!
        return unless @overrides.key?("operations")

        section = expect_hash!(@overrides["operations"], "operations", "#/operations")
        section.each do |operation_key, override|
          path = "#/operations/#{operation_key}"
          operation = @attributes.fetch("operations").find { |candidate| candidate["key"] == operation_key }
          unknown!("OVERRIDE_UNKNOWN_OPERATION", "Unknown operation #{operation_key.inspect}", path) unless operation

          override = expect_hash!(override, "operation override", path)
          reject_unknown_keys!(override, OPERATION_KEYS, path)
          require_keys!(override, OPERATION_KEYS, path)
          intent = override["intent"]
          unless ProviderIR::Operation::INTENTS.include?(intent)
            unknown!("OVERRIDE_UNKNOWN_CAPABILITY", "Unknown operation intent/capability #{intent.inspect}", "#{path}/intent")
          end

          before = operation.slice("intent", "confidence", "decision", "provenance")
          operation["intent"] = intent
          operation["confidence"] = 1.0
          operation["decision"] = intent == "unknown" ? "unsupported" : "accepted"
          mark_overridden!(operation)
          operation["evidence"] = [
            *operation.fetch("evidence", []),
            { "rule" => "override", "score" => nil, "detail" => override_reason }
          ]
          record_change!("#{path}/intent", before, operation.slice("intent", "confidence", "decision", "provenance"))
        end

        rebuild_dependent_sections!(section.keys)
      end

      def rebuild_dependent_sections!(overridden_operation_keys)
        previous_warnings = @attributes.fetch("warnings")
        operations = @attributes.fetch("operations").map { |operation| ProviderIR::Operation.new(operation) }
        source_operations = @attributes.fetch("operations").map { |operation| source_operation(operation) }
        resolution = Analyzer::CapabilityResolver.new.resolve(operations)
        statuses = Analyzer::StatusAnalyzer.new.analyze(source_operations, resolution.fetch("capabilities"))
        webhook = Analyzer::WebhookAnalyzer.new.analyze(
          { "security" => root_security },
          source_operations,
          resolution.fetch("capabilities")
        )
        fields = Analyzer::FieldMappingAnalyzer.new.analyze(source_operations, resolution.fetch("capabilities"))

        @attributes["capabilities"] = resolution.fetch("capabilities")
        @attributes["unsupported_operations"] = resolution.fetch("unsupported_operations")
        @attributes["status_mapping"] = statuses.fetch("status_mapping")
        @attributes["webhook"] = webhook.fetch("webhook")
        @attributes["field_mappings"] = fields.fetch("field_mappings")
        @attributes["transformations"] = fields.fetch("transformations")

        overridden_operation_keys.each do |operation_key|
          operation = @attributes.fetch("operations").find { |candidate| candidate["key"] == operation_key }
          capability = @attributes.fetch("capabilities")[operation["intent"]]
          mark_overridden!(capability) if capability && capability["operation_key"] == operation_key
        end

        preserved = previous_warnings.reject { |warning| reanalyzed_warning?(warning) }
        current = [
          *resolution.fetch("warnings"),
          *statuses.fetch("warnings"),
          *webhook.fetch("warnings"),
          *fields.fetch("warnings")
        ]
        @attributes["warnings"] = (preserved + current).uniq do |warning|
          [warning["code"], warning["message"], warning["location"]]
        end

        removed = previous_warnings.select { |warning| reanalyzed_warning?(warning) }.reject do |warning|
          @attributes["warnings"].any? { |current_warning| same_warning?(warning, current_warning) }
        end
        removed.each do |warning|
          @resolved_warnings << resolved_warning_entry(
            warning,
            overridden_operation_keys.map { |key| "#/operations/#{key}/intent" },
            "operation intent reanalysis"
          )
        end
      end

      def apply_status_mapping!
        return unless @overrides.key?("status_mapping")

        section = expect_hash!(@overrides["status_mapping"], "status_mapping", "#/status_mapping")
        section.each do |provider_status, normalized|
          path = "#/status_mapping/mappings/#{provider_status}"
          mapping = @attributes.dig("status_mapping", "mappings", provider_status)
          unknown!("OVERRIDE_UNKNOWN_STATUS", "Unknown provider status #{provider_status.inspect}", path) unless mapping
          unless NORMALIZED_STATUSES.include?(normalized)
            invalid_value!("Unsupported normalized status #{normalized.inspect}", path)
          end

          before = mapping.slice("normalized", "confidence", "provenance", "requires_review")
          mapping["normalized"] = normalized
          mapping["confidence"] = 1.0
          mapping["requires_review"] = false
          mapping["evidence"] = override_reason
          mark_overridden!(mapping)
          record_change!(path, before, mapping.slice("normalized", "confidence", "provenance", "requires_review"))
        end
      end

      def apply_field_mappings!
        return unless @overrides.key?("field_mappings")

        section = expect_hash!(@overrides["field_mappings"], "field_mappings", "#/field_mappings")
        section.each do |capability, override|
          capability_path = "#/field_mappings/#{capability}"
          unless MAPPABLE_CAPABILITIES.include?(capability)
            unknown!("OVERRIDE_UNKNOWN_CAPABILITY", "Unknown or non-mappable capability #{capability.inspect}", capability_path)
          end

          override = expect_hash!(override, "field mapping override", capability_path)
          reject_unknown_keys!(override, FIELD_MAPPING_KEYS, capability_path)
          require_keys!(override, FIELD_MAPPING_KEYS, capability_path)
          request_overrides = expect_array!(override["request"], "request mappings", "#{capability_path}/request")
          request_overrides.each_with_index do |request_override, index|
            apply_request_mapping!(capability, request_override, "#{capability_path}/request/#{index}")
          end
        end
      end

      def apply_request_mapping!(capability, override, override_path)
        override = expect_hash!(override, "request mapping override", override_path)
        reject_unknown_keys!(override, REQUEST_MAPPING_KEYS, override_path)
        require_keys!(override, %w[target location], override_path)
        unless override.key?("source") || override.key?("value") || override.key?("confirm")
          invalid_value!("Request mapping must provide source, value and/or confirm", override_path)
        end
        if override.key?("source") && override.key?("value")
          invalid_value!("Request mapping cannot provide both source and value", override_path)
        end

        target = override["target"]
        location = override["location"]
        mappings = @attributes.dig("field_mappings", capability, "request") || []
        mapping = mappings.find { |candidate| candidate["target"] == target && candidate["location"] == location }
        mapping ||= add_schema_mapping(capability, target, location, mappings)
        unless mapping
          unknown!(
            "OVERRIDE_UNKNOWN_FIELD",
            "Unknown #{capability} request field #{target.inspect} at #{location.inspect}",
            override_path
          )
        end

        if override.key?("source")
          source = override["source"]
          unless source == "request_method" || (source.is_a?(String) && source.match?(/\Aoperation(?:\.[a-zA-Z0-9_]+)+\z/))
            invalid_value!("Field mapping source must be request_method or an explicit operation.* host path", "#{override_path}/source")
          end
        end
        if override.key?("value") && !scalar?(override["value"])
          invalid_value!("Field mapping value must be a scalar constant", "#{override_path}/value")
        end
        if override.key?("confirm") && override["confirm"] != true
          invalid_value!("confirm must be true when provided", "#{override_path}/confirm")
        end

        audit_keys = %w[source_candidate constant_value requires_review confidence provenance]
        before = mapping.slice(*audit_keys)
        if override.key?("source")
          mapping["source_candidate"] = override["source"]
          mapping.delete("constant_value")
        elsif override.key?("value")
          mapping["source_candidate"] = nil
          mapping["constant_value"] = deep_copy(override["value"])
        end
        mapping["requires_review"] = false if override["confirm"]
        mapping["confidence"] = 1.0 if override["confirm"]
        mapping["evidence"] = override_reason
        mark_overridden!(mapping)
        record_change!("#/field_mappings/#{capability}/request/#{target}", before, mapping.slice(*audit_keys))
      end

      def add_schema_mapping(capability, target, location, mappings)
        return unless location == "body" && target.is_a?(String)

        key = @attributes.dig("capabilities", capability, "operation_key")
        operation = @attributes["operations"].find { |candidate| candidate["key"] == key }
        _type, media = Analyzer::Support.json_content(operation&.dig("contract", "request_body", "content"))
        entry = Analyzer::Support.schema_entries(media && media["schema"]).find { |path, _schema| path == target }
        return unless entry && !target.include?("[]")

        mapping = {
          "role" => "explicit_field", "target" => target, "location" => location,
          "source_candidate" => nil, "schema" => deep_copy(entry.last),
          "required" => false, "requires_review" => true, "confidence" => 0.0,
          "provenance" => "inferred"
        }
        mappings << mapping
        mapping
      end

      def apply_amount!
        transformations = @overrides["transformations"]
        return unless transformations&.key?("amount")

        amount_override = expect_hash!(transformations["amount"], "amount override", "#/transformations/amount")
        reject_unknown_keys!(amount_override, AMOUNT_KEYS, "#/transformations/amount")
        require_keys!(amount_override, AMOUNT_KEYS, "#/transformations/amount")

        unit = amount_override["provider_unit"]
        direction = amount_override["direction"]
        factor = amount_override["factor"]
        invalid_value!("Unsupported provider_unit #{unit.inspect}", "#/transformations/amount/provider_unit") unless AMOUNT_UNITS.include?(unit)
        unless AMOUNT_DIRECTIONS.include?(direction)
          invalid_value!("Unsupported amount direction #{direction.inspect}", "#/transformations/amount/direction")
        end
        unless factor.is_a?(Numeric) && factor.positive?
          invalid_value!("Amount factor must be a positive number", "#/transformations/amount/factor")
        end
        if direction == "major_to_minor" && unit != "minor"
          invalid_value!("major_to_minor requires provider_unit minor", "#/transformations/amount")
        end
        if direction == "none" && factor != 1
          invalid_value!("direction none requires factor 1", "#/transformations/amount")
        end

        amount = @attributes.dig("transformations", "amount")
        unknown!("OVERRIDE_UNKNOWN_FIELD", "No inferred amount field is available to override", "#/transformations/amount") unless amount&.fetch("provider_field", nil)

        before = deep_copy(amount)
        amount.merge!(amount_override)
        amount["confidence"] = 1.0
        amount["requires_review"] = false
        amount["evidence"] = override_reason
        mark_overridden!(amount)
        record_change!("#/transformations/amount", before, amount)
      end

      def apply_conditional_requirements!
        transformations = @overrides["transformations"]
        return unless transformations&.key?("conditional_requirements")

        overrides = expect_array!(
          transformations["conditional_requirements"],
          "conditional_requirements",
          "#/transformations/conditional_requirements"
        )
        provider_fields = create_request_schema_paths
        overrides.each_with_index do |override, index|
          path = "#/transformations/conditional_requirements/#{index}"
          override = expect_hash!(override, "conditional requirement", path)
          reject_unknown_keys!(override, CONDITION_KEYS, path)
          require_keys!(override, CONDITION_KEYS, path)
          required_if = expect_hash!(override["required_if"], "required_if", "#{path}/required_if")
          reject_unknown_keys!(required_if, REQUIRED_IF_KEYS, "#{path}/required_if")
          require_keys!(required_if, REQUIRED_IF_KEYS, "#{path}/required_if")

          field = override["field"]
          condition_field = required_if["field"]
          [field, condition_field].each do |provider_field|
            unless provider_field.is_a?(String) && provider_fields.include?(provider_field)
              unknown!("OVERRIDE_UNKNOWN_FIELD", "Unknown create_payout request field #{provider_field.inspect}", path)
            end
          end
          unless scalar?(required_if["equals"])
            invalid_value!("required_if.equals must be a scalar value", "#{path}/required_if/equals")
          end
          [field, condition_field].each do |provider_field|
            unless confirmed_source_for_provider_field(provider_field)
              invalid_value!(
                "Conditional field #{provider_field.inspect} needs a confirmed field mapping source",
                path
              )
            end
          end

          rule = {
            "field" => field,
            "required_if" => deep_copy(required_if),
            "confidence" => 1.0,
            "provenance" => "overridden",
            "requires_review" => false,
            "evidence" => override_reason,
            "override_source" => override_source,
            "override_reason" => override_reason
          }
          rules = @attributes.dig("transformations", "conditional_requirements")
          existing_index = rules.index { |candidate| candidate["field"] == field }
          before = existing_index ? deep_copy(rules[existing_index]) : nil
          existing_index ? rules[existing_index] = rule : rules << rule
          record_change!("#/transformations/conditional_requirements/#{field}", before, rule)
        end
      end

      def apply_webhook!
        return unless @overrides.key?("webhook")

        section = expect_hash!(@overrides["webhook"], "webhook", "#/webhook")
        reject_unknown_keys!(section, WEBHOOK_KEYS, "#/webhook")
        invalid_value!("Webhook override cannot be empty", "#/webhook") if section.empty?
        webhook = @attributes.fetch("webhook")
        unless webhook["status"] == "detected"
          unknown!("OVERRIDE_UNKNOWN_CAPABILITY", "Webhook capability is not detected", "#/webhook")
        end
        apply_webhook_payload!(section["payload"]) if section.key?("payload")
        return unless section.key?("signature")

        signature_override = expect_hash!(section["signature"], "webhook signature", "#/webhook/signature")
        reject_unknown_keys!(signature_override, SIGNATURE_KEYS, "#/webhook/signature")
        invalid_value!("Webhook signature override cannot be empty", "#/webhook/signature") if signature_override.empty?

        signature = webhook["signature"]
        if signature_override.key?("header")
          operation = @attributes["operations"].find { |item| item["key"] == webhook["operation_key"] }
          headers = operation.dig("contract", "parameters").select { |item| item["in"] == "header" }.map { |item| item["name"] }
          unless headers.include?(signature_override["header"])
            unknown!("OVERRIDE_UNKNOWN_FIELD", "Webhook header is not declared", "#/webhook/signature/header")
          end
        end
        unless signature.is_a?(Hash) && (signature["header"] || signature_override["header"])
          unknown!("OVERRIDE_UNKNOWN_FIELD", "Webhook signature header is not available", "#/webhook/signature")
        end

        algorithm = signature_override["algorithm"]
        if algorithm && !SIGNATURE_ALGORITHMS.include?(algorithm)
          invalid_value!("Unsupported webhook signature algorithm #{algorithm.inspect}", "#/webhook/signature/algorithm")
        end
        encoding = signature_override["encoding"]
        if encoding && !SIGNATURE_ENCODINGS.include?(encoding)
          invalid_value!("Unsupported webhook signature encoding #{encoding.inspect}", "#/webhook/signature/encoding")
        end

        before = deep_copy(signature)
        signature.merge!(signature_override)
        signature["confidence"] = 1.0
        signature["evidence"] = override_reason
        mark_overridden!(signature)
        record_change!("#/webhook/signature", before, signature)
      end

      def apply_webhook_payload!(override)
        override = expect_hash!(override, "webhook payload", "#/webhook/payload")
        reject_unknown_keys!(override, PAYLOAD_KEYS, "#/webhook/payload")
        invalid_value!("Payload override cannot be empty", "#/webhook/payload") if override.empty?
        webhook = @attributes.fetch("webhook")
        operation = @attributes["operations"].find { |item| item["key"] == webhook["operation_key"] }
        _type, media = Analyzer::Support.json_content(operation.dig("contract", "request_body", "content"))
        paths = schema_paths(media && media["schema"])
        override.each do |role, path|
          unless paths.include?(path)
            unknown!("OVERRIDE_UNKNOWN_FIELD", "Webhook payload path is not declared", "#/webhook/payload/#{role}")
          end
          before = webhook["payload"][role]
          webhook["payload"][role] = path
          record_change!("#/webhook/payload/#{role}", before, path)
        end
      end

      def apply_warning_resolutions!
        return unless @overrides.key?("resolve_warnings")

        selectors = expect_array!(@overrides["resolve_warnings"], "resolve_warnings", "#/resolve_warnings")
        selectors.each_with_index do |selector, index|
          path = "#/resolve_warnings/#{index}"
          selector = expect_hash!(selector, "warning selector", path)
          reject_unknown_keys!(selector, WARNING_KEYS, path)
          require_keys!(selector, WARNING_KEYS, path)
          warning = @attributes.fetch("warnings").find { |candidate| same_warning?(candidate, selector) }
          unknown!("OVERRIDE_UNKNOWN_WARNING", "Warning #{selector.inspect} is not unresolved", path) unless warning

          related = @changes.select { |change| related_paths?(change["path"], warning["location"]) }
          if related.empty?
            invalid_value!("Warning resolution must be backed by a related applied override", path)
          end
          unless warning_state_resolved?(warning)
            invalid_value!("Applied overrides do not resolve warning #{warning['code']}", path)
          end
          @attributes["warnings"].delete(warning)
          @resolved_warnings << resolved_warning_entry(
            warning,
            related.map { |change| change["path"] },
            "explicitly resolved by override"
          )
        end
      end

      def attach_audit!
        invalid_value!("No override changes were applied", "#") if @changes.empty?

        @attributes["overrides"] = {
          "applied" => true,
          "override_version" => VERSION,
          "file" => @path,
          "source" => override_source,
          "reason" => override_reason,
          "applied_changes" => @changes,
          "resolved_warnings" => @resolved_warnings.uniq do |entry|
            warning = entry.fetch("warning")
            [warning["code"], warning["location"]]
          end
        }
      end

      def source_operation(operation)
        operation.slice("key", "operation_id", "method", "path", "summary", "description")
                 .merge(deep_copy(operation.fetch("contract")))
      end

      def root_security
        requirements = @attributes.dig("auth", "default", "requirements") || []
        requirements.map { |requirement| deep_copy(requirement.fetch("scopes", {})) }
      end

      def create_request_schema_paths
        operation_key = @attributes.dig("capabilities", "create_payout", "operation_key")
        unless operation_key
          unknown!("OVERRIDE_UNKNOWN_CAPABILITY", "create_payout capability is not detected", "#/transformations/conditional_requirements")
        end
        operation = @attributes.fetch("operations").find { |candidate| candidate["key"] == operation_key }
        content = operation.dig("contract", "request_body", "content") || {}
        media = content.find { |type, _value| type.to_s.match?(%r{\Aapplication/(?:json|[^;]+\+json)}) }&.last || content.values.first
        schema_paths(media&.fetch("schema", nil))
      end

      def schema_paths(schema, prefix = nil)
        return [] unless schema.is_a?(Hash)

        schema.fetch("properties", {}).flat_map do |name, child|
          path = [prefix, name].compact.join(".")
          [path, *schema_paths(child, path)]
        end
      end

      def confirmed_source_for_provider_field(provider_field)
        mappings = @attributes.dig("field_mappings", "create_payout", "request") || []
        mapping = mappings.select do |candidate|
          target = candidate["target"].to_s
          provider_field == target || provider_field.start_with?("#{target}.")
        end.max_by { |candidate| candidate["target"].to_s.length }
        return nil unless mapping && !mapping["requires_review"]

        suffix = provider_field.delete_prefix(mapping["target"].to_s).delete_prefix(".")
        source = mapping["source_candidate"]
        return [source, suffix.empty? ? nil : suffix].compact.join(".") if source
        return "constant" if suffix.empty? && mapping.key?("constant_value")

        nil
      end

      def mark_overridden!(value)
        value["provenance"] = "overridden"
        value["override_source"] = override_source
        value["override_reason"] = override_reason
      end

      def record_change!(path, before, after)
        @changes << {
          "path" => path,
          "before" => deep_copy(before),
          "after" => deep_copy(after),
          "source" => override_source,
          "reason" => override_reason
        }
      end

      def resolved_warning_entry(warning, paths, resolution)
        {
          "warning" => deep_copy(warning),
          "resolution" => resolution,
          "resolved_by" => paths,
          "source" => override_source,
          "reason" => override_reason
        }
      end

      def reanalyzed_warning?(warning)
        location = warning["location"].to_s
        REANALYZED_WARNING_PREFIXES.any? { |prefix| location.start_with?(prefix) }
      end

      def related_paths?(change_path, warning_location)
        return false unless warning_location.is_a?(String)

        change_path.start_with?(warning_location) || warning_location.start_with?(change_path) ||
          normalized_warning_path(warning_location) == normalized_warning_path(change_path)
      end

      def warning_state_resolved?(warning)
        case warning["code"]
        when "STATUS_MAPPING_DEFAULT_RULES_APPLIED"
          mappings = @attributes.dig("status_mapping", "mappings") || {}
          !mappings.empty? && mappings.values.all? { |mapping| mapping["provenance"] == "overridden" }
        when "UNKNOWN_STATUS"
          provider_status = warning["location"].to_s.split("/").last
          mapping = @attributes.dig("status_mapping", "mappings", provider_status)
          mapping && mapping["normalized"] != "unknown" && mapping["requires_review"] == false
        when "WEBHOOK_SIGNATURE_ENCODING_UNKNOWN"
          !@attributes.dig("webhook", "signature", "encoding").nil?
        when "WEBHOOK_SIGNATURE_ALGORITHM_UNKNOWN"
          !@attributes.dig("webhook", "signature", "algorithm").nil?
        when "AMBIGUOUS_WEBHOOK_SIGNATURE_HEADER"
          !@attributes.dig("webhook", "signature", "header").nil?
        when "AMBIGUOUS_WEBHOOK_PAYLOAD_PATH"
          !@attributes.dig("webhook", "payload", warning["location"].split("/").last).nil?
        when "IDEMPOTENCY_SOURCE_REQUIRES_REVIEW", "REQUEST_PARAMETER_MAPPING_NOT_FOUND",
             "REQUIRED_REQUEST_BODY_MAPPING_NOT_FOUND"
          field_warning_resolved?(warning)
        when "CONDITIONAL_REQUIREMENT_INFERRED"
          field = warning["location"].to_s.split("/").last
          rule = @attributes.dig("transformations", "conditional_requirements")&.find do |candidate|
            candidate["field"] == field
          end
          rule && rule["requires_review"] == false
        when "AMOUNT_UNIT_AMBIGUOUS", "AMOUNT_FACTOR_AMBIGUOUS"
          amount = @attributes.dig("transformations", "amount") || {}
          amount["requires_review"] == false && amount["provider_unit"] != "unknown" && !amount["factor"].nil?
        else
          false
        end
      end

      def field_warning_resolved?(warning)
        parts = warning["location"].to_s.split("/")
        capability = parts[2]
        target = parts[4..]&.join("/")
        mapping = @attributes.dig("field_mappings", capability, "request")&.find do |candidate|
          candidate["target"] == target
        end
        mapping && mapping["requires_review"] == false &&
          (!mapping["source_candidate"].nil? || mapping.key?("constant_value"))
      end

      def normalized_warning_path(path)
        path.to_s.sub(%r{/\d+\z}, "")
      end

      def same_warning?(left, right)
        left["code"] == right["code"] && left["location"] == right["location"]
      end

      def scalar?(value)
        value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      end

      def reject_unknown_keys!(value, allowed, path)
        unknown = value.keys - allowed
        return if unknown.empty?

        unknown!("OVERRIDE_UNKNOWN_KEY", "Unknown override key #{unknown.first.inspect}", "#{path}/#{unknown.first}")
      end

      def require_keys!(value, required, path)
        missing = required.reject { |key| value.key?(key) }
        return if missing.empty?

        invalid_value!("Missing required override key(s): #{missing.join(', ')}", path)
      end

      def expect_hash!(value, name, path)
        return value if value.is_a?(Hash)

        invalid_value!("#{name} must be an object", path)
      end

      def expect_array!(value, name, path)
        return value if value.is_a?(Array)

        invalid_value!("#{name} must be an array", path)
      end

      def invalid_value!(message, path)
        raise Error.new("OVERRIDE_INVALID_VALUE", message, location: location(path))
      end

      def unknown!(code, message, path)
        raise Error.new(code, message, location: location(path))
      end

      def location(path)
        @path ? "#{@path}:#{path}" : path
      end

      def override_source
        @overrides.fetch("source")
      end

      def override_reason
        @overrides.fetch("reason")
      end

      def deep_stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            result[key.to_s] = deep_stringify_keys(item)
          end
        when Array
          value.map { |item| deep_stringify_keys(item) }
        else
          value
        end
      end

      def deep_copy(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = deep_copy(item) }
        when Array
          value.map { |item| deep_copy(item) }
        else
          value
        end
      end
    end
  end
end
