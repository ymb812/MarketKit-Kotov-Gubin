# frozen_string_literal: true

module IntegrationGenerator
  module Generator
    module Support
      module_function

      def manifest_hash(manifest)
        attributes = manifest.respond_to?(:to_h) ? manifest.to_h : manifest
        ProviderIR::Manifest.new(deep_copy(attributes)).to_h
      rescue ArgumentError, KeyError, NoMethodError, TypeError => e
        raise Error.new("MANIFEST_INVALID", e.message)
      end

      def operation_for(manifest, intent)
        operation_key = manifest.dig("capabilities", intent, "operation_key")
        manifest.fetch("operations").find { |operation| operation["key"] == operation_key }
      end

      def capability_row(manifest, intent)
        capability = manifest.fetch("capabilities").fetch(intent)
        operation = operation_for(manifest, intent)
        [capability, operation]
      end

      def json_media(content)
        return [nil, nil] unless content.is_a?(Hash)

        content.find { |type, _media| type.to_s.match?(%r{\Aapplication/(?:json|[^;]+\+json)(?:;.*)?\z}i) } || content.first
      end

      def media_examples(media)
        return [] unless media.is_a?(Hash)
        return [{ "name" => nil, "value" => deep_copy(media["example"]), "provenance" => "openapi_example" }] unless media["example"].nil?

        media.fetch("examples", {}).filter_map do |name, example|
          value = example.is_a?(Hash) && example.key?("value") ? example["value"] : example
          next if value.nil?

          {
            "name" => name,
            "summary" => example.is_a?(Hash) ? example["summary"] : nil,
            "value" => deep_copy(value),
            "provenance" => "openapi_example"
          }.compact
        end
      end

      def schema_fixture(schema, path: "value")
        return nil unless schema.is_a?(Hash)
        return deep_copy(schema["example"]) unless schema["example"].nil?
        return deep_copy(schema["default"]) unless schema["default"].nil?
        return deep_copy(schema["enum"].first) unless schema.fetch("enum", []).empty?

        case schema["kind"]
        when "object"
          properties = schema.fetch("properties", {})
          required = schema.fetch("required", [])
          selected = required.empty? ? properties.keys : required
          selected.each_with_object({}) do |name, result|
            child = properties[name]
            result[name] = schema_fixture(child, path: [path, name].join(".")) if child
          end
        when "array"
          [schema_fixture(schema["items"], path: "#{path}[]")]
        when "integer"
          schema.dig("constraints", "minimum") || 0
        when "number"
          schema.dig("constraints", "minimum") || 0.0
        when "boolean"
          true
        when "string"
          case schema["format"]
          when "date-time" then "2026-01-01T00:00:00Z"
          when "uuid" then "00000000-0000-4000-8000-000000000000"
          else "#{path.split('.').last.delete_suffix('[]')}_example"
          end
        else
          nil
        end
      end

      def example_or_schema(media, path: "value")
        example = media_examples(media).first
        return example if example

        {
          "name" => nil,
          "value" => schema_fixture(media&.fetch("schema", nil), path: path),
          "provenance" => "schema_generated"
        }
      end

      def dig_path(value, path)
        path.to_s.split(".").reduce(value) do |current, segment|
          break nil unless current.is_a?(Hash)

          current.key?(segment) ? current[segment] : current[segment.to_sym]
        end
      end

      def escape_markdown(value)
        value.to_s.gsub(/\r?\n/, " ").gsub("`", "'").gsub("|", "\\|")
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
    end
  end
end
