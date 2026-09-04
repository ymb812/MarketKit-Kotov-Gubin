# frozen_string_literal: true

module IntegrationGenerator
  module OpenAPI
    class DocumentValidator
      OPENAPI_3_VERSION = /\A3\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/

      class << self
        def validate!(document)
          unless document.is_a?(Hash)
            raise Error.new("SPEC_INVALID", "OpenAPI document root must be an object", location: "#")
          end

          validate_version!(document["openapi"])
          require_mapping!(document, "info")
          require_mapping!(document, "paths")
          optional_mapping!(document, "components")

          document
        end

        private

        def validate_version!(version)
          if version.nil?
            raise Error.new("SPEC_INVALID", "Missing required 'openapi' version", location: "#/openapi")
          end

          return if version.is_a?(String) && OPENAPI_3_VERSION.match?(version)

          raise Error.new(
            "UNSUPPORTED_OPENAPI_VERSION",
            "Expected an OpenAPI 3.x version, got #{version.inspect}",
            location: "#/openapi"
          )
        end

        def require_mapping!(document, key)
          return if document[key].is_a?(Hash)

          raise Error.new("SPEC_INVALID", "'#{key}' must be an object", location: "#/#{key}")
        end

        def optional_mapping!(document, key)
          return unless document.key?(key)

          require_mapping!(document, key)
        end
      end
    end
  end
end
