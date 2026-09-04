# frozen_string_literal: true

require "digest"

module IntegrationGenerator
  module OpenAPI
    class Parser
      HTTP_METHODS = %w[get put post delete options head patch trace].freeze
      PATH_ITEM_FIELDS = %w[$ref summary description servers parameters].freeze
      VALID_PARAMETER_LOCATIONS = %w[path query header cookie].freeze
      SUPPORTED_PARAMETER_LOCATIONS = %w[path query header].freeze

      class << self
        def parse_file(path)
          document = Loader.load_file(path)
          source = {
            "path" => path.to_s.tr("\\", "/"),
            "sha256" => Digest::SHA256.file(path).hexdigest
          }
          new(document, source: source).parse
        end
      end

      def initialize(document, source: nil)
        @document = document
        @source = source
        @warnings = []
      end

      def parse
        DocumentValidator.validate!(@document)
        resolved = RefResolver.new(@document).resolve
        @schema_parser = SchemaParser.new(@warnings)
        warn_unsupported_document_fields(resolved)
        raw_security_schemes = resolved.dig("components", "securitySchemes")
        @security_scheme_names = raw_security_schemes.is_a?(Hash) ? raw_security_schemes.keys : []
        security_schemes = parse_security_schemes(raw_security_schemes)

        IR::Document.new(
          openapi_version: resolved.fetch("openapi"),
          info: parse_info(resolved.fetch("info")),
          servers: parse_servers(resolved["servers"], "#/servers"),
          security: parse_security_requirements(resolved["security"], "#/security", missing: !resolved.key?("security")),
          security_schemes: security_schemes,
          schemas: parse_component_schemas(resolved.dig("components", "schemas")),
          operations: parse_operations(resolved.fetch("paths")),
          warnings: @warnings,
          source: @source
        )
      end

      private

      def parse_info(info)
        {
          "title" => info["title"],
          "version" => info["version"],
          "description" => info["description"]
        }
      end

      def parse_servers(servers, location)
        return [] if servers.nil?
        expect_array!(servers, "Servers must be an array", location)

        servers.each_with_index.map do |server, index|
          server_location = "#{location}/#{index}"
          expect_hash!(server, "Server must be an object", server_location)
          variables = server["variables"] || {}
          expect_hash!(variables, "Server variables must be an object", "#{server_location}/variables")

          {
            "url" => server["url"],
            "description" => server["description"],
            "variables" => variables.each_with_object({}) do |(name, variable), result|
              variable_location = "#{server_location}/variables/#{escape_pointer_token(name)}"
              expect_hash!(variable, "Server variable must be an object", variable_location)
              result[name] = {
                "default" => variable["default"],
                "enum" => variable["enum"].is_a?(Array) ? variable["enum"] : [],
                "description" => variable["description"]
              }
            end
          }
        end
      end

      def parse_security_schemes(schemes)
        return {} if schemes.nil?
        expect_hash!(schemes, "Security schemes must be an object", "#/components/securitySchemes")

        schemes.each_with_object({}) do |(name, scheme), result|
          location = "#/components/securitySchemes/#{escape_pointer_token(name)}"
          expect_hash!(scheme, "Security scheme must be an object", location)
          raw_type = scheme["type"]
          normalized_type, supported = normalize_security_type(raw_type, scheme, location)

          result[name] = {
            "type" => normalized_type,
            "raw_type" => raw_type,
            "supported" => supported,
            "scheme" => scheme["scheme"]&.downcase,
            "bearer_format" => scheme["bearerFormat"],
            "in" => scheme["in"],
            "name" => scheme["name"],
            "description" => scheme["description"]
          }
        end
      end

      def normalize_security_type(raw_type, scheme, location)
        case raw_type
        when "apiKey"
          supported = %w[header query].include?(scheme["in"])
          unsupported_auth_warning(raw_type, location) unless supported
          ["api_key", supported]
        when "http"
          supported = %w[bearer basic].include?(scheme["scheme"]&.downcase)
          unsupported_auth_warning("http/#{scheme['scheme']}", location) unless supported
          ["http", supported]
        when "oauth2"
          unsupported_auth_warning(raw_type, location)
          ["oauth2", false]
        when "openIdConnect"
          unsupported_auth_warning(raw_type, location)
          ["open_id_connect", false]
        when "mutualTLS"
          unsupported_auth_warning(raw_type, location)
          ["mutual_tls", false]
        else
          unsupported_auth_warning(raw_type || "missing type", location)
          ["unsupported", false]
        end
      end

      def unsupported_auth_warning(auth_type, location)
        @warnings << IR::Warning.new(
          code: "UNSUPPORTED_AUTH",
          message: "Authentication scheme #{auth_type.inspect} was discovered but is not supported in V0",
          location: location
        )
      end

      def parse_component_schemas(schemas)
        return {} if schemas.nil?
        expect_hash!(schemas, "Component schemas must be an object", "#/components/schemas")

        schemas.each_with_object({}) do |(name, schema), result|
          location = "#/components/schemas/#{escape_pointer_token(name)}"
          result[name] = @schema_parser.parse(schema, location: location)
        end
      end

      def parse_operations(paths)
        paths.each_with_object([]) do |(path, path_item), operations|
          location = "#/paths/#{escape_pointer_token(path)}"
          unless path_item.is_a?(Hash)
            warning("UNSUPPORTED_PATH_ITEM", "Path item must be an object and was skipped", location)
            next
          end

          path_parameters = parse_parameters(path_item["parameters"], "#{location}/parameters")
          path_servers = path_item.key?("servers") ? parse_servers(path_item["servers"], "#{location}/servers") : nil
          warn_unknown_path_item_fields(path_item, location)

          HTTP_METHODS.each do |method|
            next unless path_item.key?(method)

            operation = path_item[method]
            operation_location = "#{location}/#{method}"
            expect_hash!(operation, "Operation must be an object", operation_location)
            operations << parse_operation(path, method, operation, path_parameters, path_servers, operation_location)
          end
        end
      end

      def warn_unknown_path_item_fields(path_item, location)
        known = HTTP_METHODS + PATH_ITEM_FIELDS
        path_item.each_key do |key|
          next if known.include?(key) || key.start_with?("x-")

          warning(
            "UNSUPPORTED_PATH_ITEM_FIELD",
            "Path item field '#{key}' was not interpreted as an operation",
            "#{location}/#{escape_pointer_token(key)}"
          )
        end
      end

      def parse_operation(path, method, operation, path_parameters, path_servers, location)
        own_parameters = parse_parameters(operation["parameters"], "#{location}/parameters")
        merged_parameters = merge_parameters(path_parameters, own_parameters)
        if operation.key?("callbacks")
          warning(
            "UNSUPPORTED_CALLBACKS",
            "OpenAPI callbacks were discovered but are not normalized in V0",
            "#{location}/callbacks"
          )
        end

        IR::Operation.new(
          "method" => method.upcase,
          "path" => path,
          "operation_id" => operation["operationId"],
          "tags" => operation["tags"].is_a?(Array) ? operation["tags"].map(&:to_s) : [],
          "summary" => operation["summary"],
          "description" => operation["description"],
          "deprecated" => operation["deprecated"] == true,
          "servers" => operation.key?("servers") ? parse_servers(operation["servers"], "#{location}/servers") : path_servers,
          "security" => parse_security_requirements(
            operation["security"],
            "#{location}/security",
            missing: !operation.key?("security")
          ),
          "parameters" => merged_parameters,
          "request_body" => parse_request_body(operation["requestBody"], "#{location}/requestBody"),
          "responses" => parse_responses(operation["responses"], "#{location}/responses")
        )
      end

      def parse_parameters(parameters, location)
        return [] if parameters.nil?
        expect_array!(parameters, "Parameters must be an array", location)

        seen = {}
        parameters.each_with_index.map do |parameter, index|
          item_location = "#{location}/#{index}"
          expect_hash!(parameter, "Parameter must be an object", item_location)
          name = parameter["name"]
          placement = parameter["in"]
          unless name.is_a?(String) && placement.is_a?(String)
            raise Error.new("SPEC_INVALID", "Parameter requires string 'name' and 'in'", location: item_location)
          end
          unless VALID_PARAMETER_LOCATIONS.include?(placement)
            raise Error.new(
              "SPEC_INVALID",
              "Parameter location must be one of: #{VALID_PARAMETER_LOCATIONS.join(', ')}",
              location: "#{item_location}/in"
            )
          end
          unless SUPPORTED_PARAMETER_LOCATIONS.include?(placement)
            warning(
              "UNSUPPORTED_PARAMETER_LOCATION",
              "Parameter location '#{placement}' is preserved but is not supported in V0",
              "#{item_location}/in"
            )
          end

          identity = [placement, name]
          if seen.key?(identity)
            raise Error.new("SPEC_INVALID", "Duplicate parameter #{placement}:#{name}", location: item_location)
          end
          seen[identity] = true

          if parameter.key?("content")
            warning(
              "UNSUPPORTED_PARAMETER_CONTENT",
              "Parameter content is not normalized in V0; use a schema parameter",
              "#{item_location}/content"
            )
          end

          {
            "name" => name,
            "in" => placement,
            "required" => placement == "path" || parameter["required"] == true,
            "description" => parameter["description"],
            "deprecated" => parameter["deprecated"] == true,
            "style" => parameter["style"],
            "explode" => parameter["explode"],
            "schema" => parameter["schema"] ? @schema_parser.parse(parameter["schema"], location: "#{item_location}/schema") : nil,
            "example" => parameter["example"],
            "examples" => parameter["examples"] || {}
          }
        end
      end

      def merge_parameters(path_parameters, operation_parameters)
        merged = {}
        path_parameters.each { |parameter| merged[[parameter["in"], parameter["name"]]] = parameter }
        operation_parameters.each { |parameter| merged[[parameter["in"], parameter["name"]]] = parameter }
        merged.values
      end

      def parse_request_body(request_body, location)
        return nil if request_body.nil?
        expect_hash!(request_body, "Request body must be an object", location)

        {
          "required" => request_body["required"] == true,
          "description" => request_body["description"],
          "content" => parse_content(request_body["content"], "#{location}/content")
        }
      end

      def parse_responses(responses, location)
        unless responses.is_a?(Hash) && !responses.empty?
          raise Error.new("SPEC_INVALID", "Operation responses must be a non-empty object", location: location)
        end

        responses.each_with_object({}) do |(status, response), result|
          item_location = "#{location}/#{escape_pointer_token(status)}"
          expect_hash!(response, "Response must be an object", item_location)
          result[status.to_s] = {
            "description" => response["description"],
            "headers" => parse_headers(response["headers"], "#{item_location}/headers"),
            "content" => parse_content(response["content"], "#{item_location}/content")
          }
        end
      end

      def parse_headers(headers, location)
        return {} if headers.nil?
        expect_hash!(headers, "Response headers must be an object", location)

        headers.each_with_object({}) do |(name, header), result|
          item_location = "#{location}/#{escape_pointer_token(name)}"
          expect_hash!(header, "Response header must be an object", item_location)
          result[name] = {
            "description" => header["description"],
            "required" => header["required"] == true,
            "deprecated" => header["deprecated"] == true,
            "schema" => header["schema"] ? @schema_parser.parse(header["schema"], location: "#{item_location}/schema") : nil,
            "example" => header["example"],
            "examples" => header["examples"] || {}
          }
        end
      end

      def parse_content(content, location)
        return {} if content.nil?
        expect_hash!(content, "Content must be an object", location)

        content.each_with_object({}) do |(media_type, media), result|
          item_location = "#{location}/#{escape_pointer_token(media_type)}"
          expect_hash!(media, "Media type entry must be an object", item_location)
          unless json_media_type?(media_type)
            warning(
              "UNSUPPORTED_MEDIA_TYPE",
              "Media type '#{media_type}' is preserved but is not a JSON media type",
              item_location
            )
          end

          result[media_type] = {
            "schema" => media["schema"] ? @schema_parser.parse(media["schema"], location: "#{item_location}/schema") : nil,
            "example" => media["example"],
            "examples" => media["examples"] || {}
          }
        end
      end

      def json_media_type?(media_type)
        media_type.to_s.match?(%r{\Aapplication/(?:json|[^;]+\+json)(?:;.*)?\z}i)
      end

      def parse_security_requirements(requirements, location, missing:)
        return nil if missing
        expect_array!(requirements, "Security requirements must be an array", location)

        requirements.each_with_index.map do |requirement, index|
          item_location = "#{location}/#{index}"
          expect_hash!(requirement, "Security requirement must be an object", item_location)
          requirement.each_with_object({}) do |(scheme_name, scopes), result|
            unless scopes.is_a?(Array)
              raise Error.new("SPEC_INVALID", "Security scopes must be an array", location: item_location)
            end
            unless @security_scheme_names.include?(scheme_name)
              warning(
                "UNKNOWN_SECURITY_SCHEME",
                "Security requirement references undefined scheme '#{scheme_name}'",
                "#{item_location}/#{escape_pointer_token(scheme_name)}"
              )
            end
            result[scheme_name] = scopes.map(&:to_s)
          end
        end
      end

      def warn_unsupported_document_fields(document)
        return unless document.key?("webhooks")

        warning(
          "UNSUPPORTED_WEBHOOKS_KEYWORD",
          "The OpenAPI 3.1 top-level webhooks keyword was discovered but is not normalized in V0",
          "#/webhooks"
        )
      end

      def expect_hash!(value, message, location)
        return value if value.is_a?(Hash)

        raise Error.new("SPEC_INVALID", message, location: location)
      end

      def expect_array!(value, message, location)
        return value if value.is_a?(Array)

        raise Error.new("SPEC_INVALID", message, location: location)
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
