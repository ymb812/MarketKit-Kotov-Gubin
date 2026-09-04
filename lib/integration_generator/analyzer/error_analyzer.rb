# frozen_string_literal: true

module IntegrationGenerator
  module Analyzer
    class ErrorAnalyzer
      CODE_FIELDS = %w[code error_code errorCode].freeze
      MESSAGE_FIELDS = %w[message error_message errorMessage title detail].freeze

      def analyze(operations)
        errors = []
        warnings = []

        operations.each do |operation|
          operation.fetch("responses", {}).each do |status, response|
            next unless error_status?(status)

            error = extract_error(operation, status, response)
            errors << error
            if error["possible_provider_codes"].empty?
              warnings << Support.warning(
                "PROVIDER_ERROR_CODE_NOT_FOUND",
                "Error response #{status} for '#{Support.operation_key(operation)}' has no machine-readable provider code",
                location: "#/errors/#{Support.operation_key(operation)}/#{status}"
              )
            end
          end
        end

        {
          "errors" => errors,
          "warnings" => warnings
        }
      end

      private

      def error_status?(status)
        value = status.to_s
        return true if value.casecmp("default").zero?
        return true if value.match?(/\A[45]XX\z/i)

        value.match?(/\A\d{3}\z/) && value.to_i >= 400
      end

      def extract_error(operation, status, response)
        code_paths = []
        message_paths = []
        schema_provider_codes = []
        example_provider_codes = []
        examples = []

        response.fetch("content", {}).each_value do |media|
          schema = media["schema"]
          Support.schema_entries(schema).each do |path, child|
            field_name = path.split(".").last.to_s.delete_suffix("[]")
            if CODE_FIELDS.include?(field_name)
              code_paths << path
              schema_provider_codes.concat(child.fetch("enum", []).select { |value| scalar?(value) })
            end
            message_paths << path if MESSAGE_FIELDS.include?(field_name)
          end

          example = Support.media_example(media)
          unless example.nil?
            examples << example
            example_provider_codes.concat(find_values(example, CODE_FIELDS))
          end
        end

        {
          "operation_key" => Support.operation_key(operation),
          "operation_id" => operation["operation_id"],
          "http_status" => status.to_s,
          "description" => response["description"],
          "provider_code_paths" => code_paths.uniq,
          "message_paths" => message_paths.uniq,
          "schema_provider_codes" => schema_provider_codes.map(&:to_s).uniq,
          "example_provider_codes" => example_provider_codes.map(&:to_s).uniq,
          "possible_provider_codes" => (schema_provider_codes + example_provider_codes).map(&:to_s).uniq,
          "headers" => response.fetch("headers", {}).keys,
          "examples" => examples
        }
      end

      def find_values(value, names)
        case value
        when Hash
          value.flat_map do |key, child|
            own = names.include?(key.to_s) && scalar?(child) ? [child] : []
            own + find_values(child, names)
          end
        when Array
          value.flat_map { |item| find_values(item, names) }
        else
          []
        end
      end

      def scalar?(value)
        value.is_a?(String) || value.is_a?(Numeric)
      end
    end
  end
end
