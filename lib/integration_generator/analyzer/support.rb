# frozen_string_literal: true

module IntegrationGenerator
  module Analyzer
    module Support
      module_function

      def operation_key(operation)
        "#{operation.fetch('method')} #{operation.fetch('path')}"
      end

      def tokenize(value)
        value.to_s
             .gsub(/([[:lower:]\d])([[:upper:]])/, "\\1 \\2")
             .downcase
             .scan(/[[:alnum:]]+/)
      end

      def text_tokens(operation)
        tokenize(
          [
            operation["path"],
            operation["operation_id"],
            operation["tags"],
            operation["summary"],
            operation["description"]
          ].flatten.compact.join(" ")
        )
      end

      def text_blob(operation)
        [
          operation["path"],
          operation["operation_id"],
          operation["tags"],
          operation["summary"],
          operation["description"],
          operation.fetch("parameters", []).map { |parameter| [parameter["name"], parameter["description"]] }
        ].flatten.compact.join(" ")
      end

      def request_schema_entries(operation)
        content = operation.dig("request_body", "content") || {}
        content.flat_map do |media_type, media|
          schema_entries(media["schema"], prefix: nil, direction: :request).map do |path, schema|
            [path, schema, media_type]
          end
        end
      end

      def response_schema_entries(operation)
        operation.fetch("responses", {}).flat_map do |status, response|
          next [] unless success_response_status?(status)

          response.fetch("content", {}).flat_map do |media_type, media|
            schema_entries(media["schema"], prefix: nil, direction: :response).map do |path, schema|
              [path, schema, status, media_type]
            end
          end
        end
      end

      def schema_entries(schema, prefix: nil, direction: nil)
        return [] unless schema.is_a?(Hash)

        entries = []
        schema.fetch("properties", {}).each do |name, child|
          next if excluded_from_direction?(child, direction)

          path = [prefix, name].compact.join(".")
          entries << [path, child]
          entries.concat(schema_entries(child, prefix: path, direction: direction))
        end
        if schema["items"].is_a?(Hash)
          item_path = prefix ? "#{prefix}[]" : "[]"
          entries.concat(schema_entries(schema["items"], prefix: item_path, direction: direction))
        end
        entries
      end

      def success_response_status?(status)
        status.to_s.match?(/\A(?:2\d\d|2XX)\z/i)
      end

      def excluded_from_direction?(schema, direction)
        return false unless schema.is_a?(Hash)

        (direction == :request && schema["read_only"] == true) ||
          (direction == :response && schema["write_only"] == true)
      end

      def request_field_tokens(operation)
        field_tokens(request_schema_entries(operation).map(&:first))
      end

      def response_field_tokens(operation)
        field_tokens(response_schema_entries(operation).map(&:first))
      end

      def field_tokens(paths)
        paths.flat_map { |path| tokenize(path) }.uniq
      end

      def json_content(content)
        return [nil, nil] unless content.is_a?(Hash)

        pair = content.find { |media_type, _media| json_media_type?(media_type) }
        pair || content.first || [nil, nil]
      end

      def json_media_type?(media_type)
        media_type.to_s.match?(%r{\Aapplication/(?:json|[^;]+\+json)(?:;.*)?\z}i)
      end

      def compact_schema(schema)
        return nil unless schema.is_a?(Hash)

        result = {}
        %w[kind title format nullable description deprecated read_only write_only enum default example examples required constraints unsupported_keywords].each do |key|
          value = schema[key]
          next if value.nil? || value == false || value == [] || value == {}

          result[key] = deep_copy(value)
        end
        unless schema.fetch("properties", {}).empty?
          result["properties"] = schema["properties"].transform_values { |child| compact_schema(child) }
        end
        result["items"] = compact_schema(schema["items"]) if schema["items"]
        if schema.key?("additional_properties") && !schema["additional_properties"].nil?
          additional = schema["additional_properties"]
          result["additional_properties"] = additional.is_a?(Hash) ? compact_schema(additional) : additional
        end
        result
      end

      def media_example(media)
        return nil unless media.is_a?(Hash)
        return deep_copy(media["example"]) unless media["example"].nil?

        example = media.fetch("examples", {}).values.first
        example.is_a?(Hash) && example.key?("value") ? deep_copy(example["value"]) : deep_copy(example)
      end

      def deep_copy(value)
        case value
        when Hash
          value.transform_values { |item| deep_copy(item) }
        when Array
          value.map { |item| deep_copy(item) }
        else
          value
        end
      end

      def warning(code, message, location: nil)
        { "code" => code, "message" => message, "location" => location }
      end

      def intersection?(values, candidates)
        !(values & candidates).empty?
      end
    end
  end
end
