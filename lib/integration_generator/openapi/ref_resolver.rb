# frozen_string_literal: true

require "uri"

module IntegrationGenerator
  module OpenAPI
    class RefResolver
      SOURCE_LOCATION_EXTENSION = "x-integration-generator-source-location"

      def initialize(document)
        @document = document
      end

      def resolve(value = @document, location: "#", stack: [])
        case value
        when Hash
          resolve_hash(value, location:, stack:)
        when Array
          value.each_with_index.map do |item, index|
            resolve(item, location: "#{location}/#{index}", stack: stack)
          end
        else
          value
        end
      end

      private

      def resolve_hash(value, location:, stack:)
        return resolve_regular_hash(value, location:, stack:) unless value.key?("$ref")

        reference = value["$ref"]
        unless reference.is_a?(String) && reference.start_with?("#")
          raise Error.new(
            "UNSUPPORTED_REFERENCE",
            "Only local references beginning with '#' are supported",
            location: location
          )
        end

        if stack.include?(reference)
          chain = (stack + [reference]).join(" -> ")
          raise Error.new("REF_CYCLE", "Circular reference detected: #{chain}", location: location)
        end

        target = lookup(reference)
        resolved_target = resolve(target, location: reference, stack: stack + [reference])
        siblings = value.reject { |key, _| key == "$ref" }
        if siblings.empty?
          return resolved_target unless resolved_target.is_a?(Hash)

          return resolved_target.merge(
            SOURCE_LOCATION_EXTENSION => resolved_target[SOURCE_LOCATION_EXTENSION] || reference
          )
        end

        unless resolved_target.is_a?(Hash)
          raise Error.new("SPEC_INVALID", "A reference with sibling fields must resolve to an object", location: location)
        end

        resolved_target
          .reject { |key, _| key == SOURCE_LOCATION_EXTENSION }
          .merge(resolve_regular_hash(siblings, location:, stack: stack))
      end

      def resolve_regular_hash(value, location:, stack:)
        value.each_with_object({}) do |(key, item), result|
          child_location = "#{location}/#{escape_pointer_token(key)}"
          result[key] = resolve(item, location: child_location, stack: stack)
        end
      end

      def lookup(reference)
        return @document if reference == "#"

        unless reference.start_with?("#/")
          raise Error.new("REF_NOT_FOUND", "Malformed local reference #{reference.inspect}", location: reference)
        end

        tokens = reference.delete_prefix("#/").split("/", -1).map { |token| decode_pointer_token(token) }
        tokens.reduce(@document) do |current, token|
          case current
          when Hash
            unless current.key?(token)
              raise Error.new("REF_NOT_FOUND", "Reference target does not exist", location: reference)
            end
            current[token]
          when Array
            index = Integer(token, exception: false)
            if index.nil? || index.negative? || index >= current.length
              raise Error.new("REF_NOT_FOUND", "Reference array index does not exist", location: reference)
            end
            current[index]
          else
            raise Error.new("REF_NOT_FOUND", "Reference traverses a non-container value", location: reference)
          end
        end
      end

      def decode_pointer_token(token)
        URI::RFC2396_PARSER.unescape(token).gsub("~1", "/").gsub("~0", "~")
      end

      def escape_pointer_token(token)
        token.to_s.gsub("~", "~0").gsub("/", "~1")
      end
    end
  end
end
