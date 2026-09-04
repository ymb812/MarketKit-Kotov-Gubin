# frozen_string_literal: true

module IntegrationGenerator
  module ProviderIR
    class Manifest
      VERSION = "1.0"
      REQUIRED_SECTIONS = %w[
        provider analyzer source servers auth operations capabilities status_mapping errors
        webhook field_mappings transformations unsupported_operations warnings
      ].freeze
      CAPABILITIES = %w[create_payout fetch_status cancel_payout webhook balance].freeze
      CAPABILITY_STATUSES = %w[detected missing requires_review].freeze

      attr_reader :operations

      def initialize(attributes)
        @attributes = { "manifest_version" => VERSION }.merge(attributes)
        @operations = @attributes.fetch("operations")
        validate!
      end

      def to_h
        serialize(@attributes)
      end

      private

      def validate!
        validate_sections!
        validate_provider!
        validate_operations!
        validate_capabilities!
        validate_contract_sections!
      end

      def validate_sections!
        unless @attributes["manifest_version"] == VERSION
          raise ArgumentError, "Unsupported manifest version #{@attributes['manifest_version'].inspect}"
        end

        missing = REQUIRED_SECTIONS.reject { |section| @attributes.key?(section) }
        raise ArgumentError, "Missing manifest sections: #{missing.join(', ')}" unless missing.empty?

        expected_types = {
          "provider" => Hash,
          "analyzer" => Hash,
          "source" => Hash,
          "servers" => Array,
          "auth" => Hash,
          "operations" => Array,
          "capabilities" => Hash,
          "status_mapping" => Hash,
          "errors" => Array,
          "webhook" => Hash,
          "field_mappings" => Hash,
          "transformations" => Hash,
          "unsupported_operations" => Array,
          "warnings" => Array
        }
        invalid = expected_types.filter_map do |section, expected|
          section unless @attributes[section].is_a?(expected)
        end
        return if invalid.empty?

        raise ArgumentError, "Invalid manifest section types: #{invalid.join(', ')}"
      end

      def validate_provider!
        slug = @attributes.dig("provider", "slug")
        raise ArgumentError, "Manifest provider slug must be present" unless slug.is_a?(String) && !slug.empty?

        %w[version ruleset_version].each do |key|
          value = @attributes.dig("analyzer", key)
          raise ArgumentError, "Manifest analyzer #{key} must be present" unless value.is_a?(String) && !value.empty?
        end
      end

      def validate_operations!
        keys = operations.map { |operation| manifest_operation_key(operation) }
        duplicates = keys.tally.select { |_key, count| count > 1 }.keys
        raise ArgumentError, "Duplicate manifest operation keys: #{duplicates.join(', ')}" unless duplicates.empty?

        invalid = keys.reject { |key| key.is_a?(String) && key.match?(/\A[A-Z]+ \/\S*/) }
        raise ArgumentError, "Invalid manifest operation keys: #{invalid.map(&:inspect).join(', ')}" unless invalid.empty?

        operations.each do |operation|
          attributes = manifest_operation_attributes(operation)
          Operation.new(attributes)
          method = attributes["method"]
          path = attributes["path"]
          unless method.is_a?(String) && method.match?(/\A[A-Z]+\z/) && path.is_a?(String) && path.start_with?("/")
            raise ArgumentError, "Manifest operation #{attributes['key'].inspect} requires uppercase method and absolute path"
          end
          unless attributes["key"] == "#{method} #{path}"
            raise ArgumentError, "Manifest operation key does not match method/path for #{attributes['key'].inspect}"
          end
          ensure_type!(attributes["contract"], Hash, "operation #{attributes['key']} contract")
          ensure_type!(attributes["evidence"], Array, "operation #{attributes['key']} evidence")
          ensure_type!(attributes["alternatives"], Array, "operation #{attributes['key']} alternatives")
        end
      end

      def validate_capabilities!
        capabilities = @attributes["capabilities"]
        missing = CAPABILITIES.reject { |intent| capabilities.key?(intent) }
        raise ArgumentError, "Missing manifest capabilities: #{missing.join(', ')}" unless missing.empty?

        operation_keys = operations.map { |operation| manifest_operation_key(operation) }
        CAPABILITIES.each do |intent|
          capability = capabilities[intent]
          raise ArgumentError, "Capability #{intent} must be an object" unless capability.is_a?(Hash)

          status = capability["status"]
          unless CAPABILITY_STATUSES.include?(status)
            raise ArgumentError, "Unknown status #{status.inspect} for capability #{intent}"
          end

          operation_key = capability["operation_key"]
          confidence = capability["confidence"]
          unless confidence.is_a?(Numeric) && confidence.between?(0.0, 1.0)
            raise ArgumentError, "Capability #{intent} confidence must be between 0.0 and 1.0"
          end
          ensure_type!(capability["candidates"], Array, "capability #{intent} candidates")
          if status == "detected" && !operation_keys.include?(operation_key)
            raise ArgumentError, "Detected capability #{intent} must reference a manifest operation"
          end
          if status == "missing" && !operation_key.nil?
            raise ArgumentError, "Missing capability #{intent} cannot reference an operation"
          end
          if !operation_key.nil? && !operation_keys.include?(operation_key)
            raise ArgumentError, "Capability #{intent} references unknown operation #{operation_key.inspect}"
          end
        end
      end

      def validate_contract_sections!
        auth = @attributes["auth"]
        ensure_type!(auth["schemes"], Array, "auth.schemes")
        ensure_type!(auth["default"], Hash, "auth.default")
        ensure_type!(auth["operations"], Hash, "auth.operations")
        auth["schemes"].each { |scheme| ensure_type!(scheme, Hash, "auth scheme") }
        auth["operations"].each_value { |value| ensure_type!(value, Hash, "operation auth") }

        status_mapping = @attributes["status_mapping"]
        ensure_type!(status_mapping["fields"], Array, "status_mapping.fields")
        ensure_type!(status_mapping["mappings"], Hash, "status_mapping.mappings")

        required_field_mappings = %w[create_payout fetch_status cancel_payout]
        missing = required_field_mappings.reject { |intent| @attributes["field_mappings"].key?(intent) }
        raise ArgumentError, "Missing field mappings: #{missing.join(', ')}" unless missing.empty?
        @attributes["field_mappings"].each do |intent, mapping|
          ensure_type!(mapping, Hash, "field_mappings.#{intent}")
          ensure_type!(mapping["request"], Array, "field_mappings.#{intent}.request")
          ensure_type!(mapping["response"], Array, "field_mappings.#{intent}.response")
        end

        transformations = @attributes["transformations"]
        ensure_type!(transformations["amount"], Hash, "transformations.amount")
        ensure_type!(transformations["conditional_requirements"], Array, "transformations.conditional_requirements")
        @attributes["servers"].each { |server| ensure_type!(server, Hash, "server") }
        @attributes["errors"].each { |error| ensure_type!(error, Hash, "error mapping") }
        @attributes["warnings"].each { |warning| ensure_type!(warning, Hash, "warning") }
        unless @attributes["unsupported_operations"].all? { |key| key.is_a?(String) }
          raise ArgumentError, "unsupported_operations must contain operation keys"
        end

        webhook_status = @attributes.dig("webhook", "status")
        unless CAPABILITY_STATUSES.include?(webhook_status)
          raise ArgumentError, "Unknown webhook status #{webhook_status.inspect}"
        end
      end

      def manifest_operation_key(operation)
        operation.is_a?(Hash) ? operation.fetch("key") : operation.key
      end

      def manifest_operation_attributes(operation)
        operation.is_a?(Hash) ? operation : operation.to_h
      end

      def ensure_type!(value, type, name)
        return if value.is_a?(type)

        raise ArgumentError, "Manifest #{name} must be a #{type}"
      end

      def serialize(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = serialize(item) }
        when Array
          value.map { |item| serialize(item) }
        when nil, String, Numeric, true, false
          value
        else
          value.respond_to?(:to_h) ? serialize(value.to_h) : value
        end
      end
    end
  end
end
