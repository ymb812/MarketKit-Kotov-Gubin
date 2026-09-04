# frozen_string_literal: true

module IntegrationGenerator
  module OpenAPI
    class SchemaParser
      CONSTRAINTS = {
        "minimum" => "minimum",
        "maximum" => "maximum",
        "exclusiveMinimum" => "exclusive_minimum",
        "exclusiveMaximum" => "exclusive_maximum",
        "multipleOf" => "multiple_of",
        "minLength" => "min_length",
        "maxLength" => "max_length",
        "pattern" => "pattern",
        "minItems" => "min_items",
        "maxItems" => "max_items",
        "uniqueItems" => "unique_items",
        "minProperties" => "min_properties",
        "maxProperties" => "max_properties"
      }.freeze
      SUPPORTED_KEYWORDS = (
        %w[
          type title format nullable description deprecated readOnly writeOnly enum default
          example examples properties required items additionalProperties
        ] + CONSTRAINTS.keys
      ).freeze
      KNOWN_KINDS = %w[object array string integer number boolean null].freeze

      def initialize(warnings)
        @warnings = warnings
      end

      def parse(schema, location:)
        unless schema.is_a?(Hash)
          warning("UNSUPPORTED_SCHEMA", "Schema must be an object", location)
          return IR::Schema.new(empty_schema("unknown"))
        end

        unsupported = schema.keys.reject { |keyword| SUPPORTED_KEYWORDS.include?(keyword) || keyword.start_with?("x-") }
        unsupported << "type" if unsupported_type_union?(schema["type"])
        unsupported.uniq!
        unsupported.each do |keyword|
          warning(
            "UNSUPPORTED_SCHEMA_KEYWORD",
            "Schema keyword '#{keyword}' is not normalized in V0",
            "#{location}/#{keyword}"
          )
        end

        kind = infer_kind(schema)
        attributes = empty_schema(kind).merge(
          "title" => schema["title"],
          "format" => schema["format"],
          "nullable" => schema["nullable"] == true || nullable_type?(schema["type"]),
          "description" => schema["description"],
          "deprecated" => schema["deprecated"] == true,
          "read_only" => schema["readOnly"] == true,
          "write_only" => schema["writeOnly"] == true,
          "enum" => array_or_empty(schema["enum"]),
          "default" => schema["default"],
          "example" => schema["example"],
          "examples" => array_or_empty(schema["examples"]),
          "properties" => parse_properties(schema["properties"], location),
          "required" => array_or_empty(schema["required"]).map(&:to_s),
          "items" => parse_items(schema["items"], location),
          "additional_properties" => parse_additional_properties(schema, location),
          "constraints" => parse_constraints(schema),
          "unsupported_keywords" => unsupported
        )

        IR::Schema.new(attributes)
      end

      private

      def empty_schema(kind)
        {
          "kind" => kind,
          "title" => nil,
          "format" => nil,
          "nullable" => false,
          "description" => nil,
          "deprecated" => false,
          "read_only" => false,
          "write_only" => false,
          "enum" => [],
          "default" => nil,
          "example" => nil,
          "examples" => [],
          "properties" => {},
          "required" => [],
          "items" => nil,
          "additional_properties" => nil,
          "constraints" => {},
          "unsupported_keywords" => []
        }
      end

      def infer_kind(schema)
        type = schema["type"]
        if type.is_a?(Array)
          types = type.uniq
          return "null" if types == ["null"]
          return "unknown" if unsupported_type_union?(types)

          type = types.find { |candidate| candidate != "null" }
        end
        return type if KNOWN_KINDS.include?(type)
        return "object" if schema["properties"].is_a?(Hash)
        return "array" if schema.key?("items")

        "unknown"
      end

      def nullable_type?(type)
        type.is_a?(Array) && type.uniq.include?("null") && !unsupported_type_union?(type)
      end

      def unsupported_type_union?(type)
        return false unless type.is_a?(Array)

        types = type.uniq
        return false if types == ["null"]
        return false if types.length == 1 && KNOWN_KINDS.include?(types.first)
        return false if types.length == 2 && types.include?("null") && KNOWN_KINDS.include?((types - ["null"]).first)

        true
      end

      def parse_properties(properties, location)
        return {} if properties.nil?

        unless properties.is_a?(Hash)
          warning("UNSUPPORTED_SCHEMA", "Schema properties must be an object", "#{location}/properties")
          return {}
        end

        properties.each_with_object({}) do |(name, child), result|
          result[name] = parse(child, location: "#{location}/properties/#{escape_pointer_token(name)}")
        end
      end

      def parse_items(items, location)
        return nil if items.nil?

        parse(items, location: "#{location}/items")
      end

      def parse_additional_properties(schema, location)
        return nil unless schema.key?("additionalProperties")

        value = schema["additionalProperties"]
        return value if value == true || value == false

        parse(value, location: "#{location}/additionalProperties")
      end

      def parse_constraints(schema)
        CONSTRAINTS.each_with_object({}) do |(source_key, target_key), result|
          result[target_key] = schema[source_key] if schema.key?(source_key)
        end
      end

      def array_or_empty(value)
        value.is_a?(Array) ? value : []
      end

      def warning(code, message, location)
        @warnings << IR::Warning.new(code:, message:, location:)
      end

      def escape_pointer_token(token)
        token.to_s.gsub("~", "~0").gsub("/", "~1")
      end
    end
  end
end
