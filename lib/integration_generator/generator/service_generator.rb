# frozen_string_literal: true

require "json"

module IntegrationGenerator
  module Generator
    class ServiceGenerator
      CAPABILITIES = %w[create_payout fetch_status cancel_payout webhook balance].freeze

      def initialize(manifest)
        @manifest = Support.manifest_hash(manifest)
      end

      def filename
        "#{@manifest.dig('provider', 'slug')}_service.rb"
      end

      def render
        source = TEMPLATE.sub("__SERVICE_CLASS__", service_class_name)
        source.sub("__ADAPTER_CONFIG__", indent(JSON.pretty_generate(adapter_config), 6))
      end

      private

      def service_class_name
        @manifest.dig("provider", "slug").split("_").map(&:capitalize).join + "Service"
      end

      def adapter_config
        {
          "provider" => @manifest["provider"],
          "base_urls" => expanded_base_urls,
          "base_url_env" => "#{@manifest.dig('provider', 'slug').upcase}_BASE_URL",
          "capabilities" => CAPABILITIES.to_h do |intent|
            capability, operation = Support.capability_row(@manifest, intent)
            [
              intent,
              {
                "status" => capability["status"],
                "confidence" => capability["confidence"],
                "operation" => operation && {
                  "key" => operation["key"],
                  "method" => operation["method"],
                  "path" => operation["path"]
                }
              }
            ]
          end,
          "auth" => compact_auth,
          "field_mappings" => compact_field_mappings,
          "transformations" => @manifest["transformations"],
          "status_mapping" => @manifest.dig("status_mapping", "mappings"),
          "errors" => @manifest["errors"].map do |error|
            error.slice(
              "operation_key",
              "http_status",
              "provider_code_paths",
              "message_paths",
              "headers"
            )
          end,
          "webhook" => @manifest["webhook"].merge(
            "secret_env" => "#{@manifest.dig('provider', 'slug').upcase}_WEBHOOK_SECRET"
          ),
          "warnings" => @manifest["warnings"].map { |warning| warning.slice("code", "message", "location") }
        }
      end

      def compact_auth
        {
          "schemes" => @manifest.dig("auth", "schemes").map do |scheme|
            scheme.slice("name", "type", "scheme", "location", "parameter_name", "supported", "config_env")
          end,
          "operations" => @manifest.dig("auth", "operations")
        }
      end

      def compact_field_mappings
        @manifest["field_mappings"].transform_values do |mapping|
          {
            "request" => mapping.fetch("request", []).map do |field|
              field.slice("role", "target", "location", "source_candidate", "required", "requires_review")
            end,
            "response" => mapping.fetch("response", []).map do |field|
              field.slice("role", "source", "http_status")
            end
          }
        end
      end

      def expanded_base_urls
        @manifest["servers"].map do |server|
          server["url"].to_s.gsub(/\{([^}]+)\}/) do |placeholder|
            server.dig("variables", Regexp.last_match(1), "default") || placeholder
          end
        end
      end

      def indent(value, spaces)
        prefix = " " * spaces
        value.lines.map { |line| "#{prefix}#{line}" }.join.rstrip
      end

      TEMPLATE = <<~'RUBY'
        # frozen_string_literal: true

        require "json"
        require "openssl"
        require "uri"

        module Provider
          # Generated adapter boundary:
          # - the host defines Provider::BaseService and its operation model;
          # - provider_client.call receives method:, url:, headers:, query:, body:;
          # - credentials come only from the ENV placeholders below.
          class __SERVICE_CLASS__ < BaseService
            class ConfigurationError < StandardError; end
            class ProviderError < StandardError; end

            ADAPTER_CONFIG = JSON.parse(<<~'JSON').freeze
        __ADAPTER_CONFIG__
            JSON

            STATUS_MAP = ADAPTER_CONFIG.fetch("status_mapping").transform_values do |mapping|
              mapping.fetch("normalized").to_sym
            end.freeze

            attr_writer :provider_client

            def check_conditions(operation, request_method)
              _logical_gateway_method = request_method
              mappings_for("create_payout").filter_map do |mapping|
                next unless mapping["required"]
                next if present?(read_operation_path(operation, mapping["source_candidate"]))

                {
                  code: "required_field_missing",
                  field: mapping["source_candidate"] || mapping["target"],
                  message: "Required provider field #{mapping['target']} has no mapped operation value"
                }
              end
            end

            def create_request(operation, request_method: nil, allow_unreviewed: false)
              ensure_detected!("create_payout")
              errors = check_conditions(operation, request_method)
              unless errors.empty?
                raise ArgumentError, errors.map { |error| error.fetch(:message) }.join("; ")
              end

              build_request("create_payout", operation, allow_unreviewed: allow_unreviewed)
            end

            def create_payout(operation, request_method: nil, allow_unreviewed: false)
              response = dispatch(
                create_request(operation, request_method: request_method, allow_unreviewed: allow_unreviewed)
              )
              normalize_response(response, "create_payout")
            end

            def fetch_status(operation, allow_unreviewed: false)
              ensure_detected!("fetch_status")
              response = dispatch(build_request("fetch_status", operation, allow_unreviewed: allow_unreviewed))
              normalize_response(response, "fetch_status")
            end

            def cancel_payout(operation, allow_unreviewed: false)
              ensure_detected!("cancel_payout")
              response = dispatch(build_request("cancel_payout", operation, allow_unreviewed: allow_unreviewed))
              normalize_response(response, "cancel_payout")
            end

            def fetch_balance
              ensure_detected!("balance")
              response = dispatch(build_request("balance", nil, allow_unreviewed: false))
              normalize_response(response, "balance")
            end

            def process_callback(payload, headers: {}, raw_body: nil, allow_unverified: false)
              ensure_detected!("webhook")
              body = parse_body(payload)
              webhook = ADAPTER_CONFIG.fetch("webhook")
              verification = verify_webhook_signature(webhook, headers, raw_body)
              if verification == :manual_required && !allow_unverified
                raise ConfigurationError,
                      "Webhook verification is not fully configured; review the manifest or pass allow_unverified: true only for inspection"
              end
              paths = webhook.fetch("payload")
              provider_status = read_payload_path(body, paths["status_path"])

              {
                event: read_payload_path(body, paths["event_path"]),
                provider_operation_id: read_payload_path(body, paths["provider_operation_id_path"]),
                external_id: read_payload_path(body, paths["external_id_path"]),
                provider_status: provider_status,
                status: normalize_status(provider_status),
                error: read_payload_path(body, paths["error_path"]),
                signature_verification: verification,
                raw: body
              }
            end

            private

            def provider_client
              @provider_client || raise(
                ConfigurationError,
                "Host must assign #provider_client= with an object responding to #call(method:, url:, headers:, query:, body:)"
              )
            end

            def dispatch(request)
              provider_client.call(**request)
            end

            def build_request(intent, operation, allow_unreviewed:)
              definition = capability_operation(intent)
              request = {
                method: definition.fetch("method").downcase.to_sym,
                url: build_url(interpolate_path(definition.fetch("path"), intent, operation)),
                headers: {},
                query: {},
                body: nil
              }

              body = {}
              mappings_for(intent).sort_by { |mapping| mapping["target"].to_s.count(".") }.each do |mapping|
                location = mapping["location"] || "body"
                if mapping["requires_review"] && !allow_unreviewed
                  raise ConfigurationError,
                        "Mapping #{mapping['target']} requires manifest review; use an override before production"
                end
                next if location == "path"

                source = mapping["source_candidate"]
                if source.nil?
                  if mapping["required"]
                    raise ConfigurationError, "Manual mapping required for #{location} parameter #{mapping['target']}"
                  end
                  next
                end

                value = read_operation_path(operation, source)
                next if value.nil?
                value = transform_value(mapping, value)

                case location
                when "body"
                  assign_payload_path(body, mapping.fetch("target"), value)
                when "header"
                  request[:headers][mapping.fetch("target")] = value.to_s
                when "query"
                  request[:query][mapping.fetch("target")] = value
                end
              end
              request[:body] = body unless body.empty?
              apply_auth(request, definition.fetch("key"))
              request
            end

            def interpolate_path(path, intent, operation)
              mappings = mappings_for(intent).select { |mapping| mapping["location"] == "path" }
              mappings.reduce(path.dup) do |result, mapping|
                value = read_operation_path(operation, mapping["source_candidate"])
                raise ArgumentError, "Missing value for path parameter #{mapping['target']}" unless present?(value)

                encoded = URI.encode_www_form_component(value.to_s).gsub("+", "%20")
                result.gsub("{#{mapping['target']}}", encoded)
              end.tap do |result|
                if result.match?(/\{[^}]+\}/)
                  raise ConfigurationError, "Unmapped provider path parameter in #{result}"
                end
              end
            end

            def transform_value(mapping, value)
              return normalize_value(value) unless mapping["role"] == "amount"

              transformation = ADAPTER_CONFIG.dig("transformations", "amount") || {}
              if transformation["requires_review"]
                raise ConfigurationError, "Amount unit/conversion requires a reviewed manifest override"
              end
              return normalize_value(value) unless transformation["direction"] == "major_to_minor"

              factor = transformation["factor"]
              if factor.nil?
                raise ConfigurationError, "Amount conversion factor requires a reviewed manifest override"
              end
              numeric = Rational(value.to_s)
              converted = numeric * factor
              unless converted.denominator == 1
                raise ArgumentError, "Amount #{value.inspect} cannot be converted to integral provider minor units"
              end
              converted.to_i
            rescue ArgumentError, ZeroDivisionError
              raise ArgumentError, "Amount #{value.inspect} is not an exact numeric value"
            end

            def apply_auth(request, operation_key)
              auth = ADAPTER_CONFIG.fetch("auth")
              operation_auth = auth.fetch("operations").fetch(operation_key, {})
              requirements = operation_auth["requirements"] || []
              requirement = requirements.find { |candidate| candidate["supported"] }
              if requirement.nil? && !requirements.empty?
                raise ConfigurationError, "No supported authentication alternative for #{operation_key}"
              end
              return request unless requirement

              requirement.fetch("schemes").each do |scheme_name|
                apply_auth_scheme(request, auth, scheme_name)
              end
              request
            end

            def apply_auth_scheme(request, auth, scheme_name)
              scheme = auth.fetch("schemes").find { |candidate| candidate["name"] == scheme_name }
              raise ConfigurationError, "Unsupported auth scheme #{scheme_name}" unless scheme && scheme["supported"]

              credential = ENV[scheme.fetch("config_env")]
              unless present?(credential)
                raise ConfigurationError, "Missing credential ENV[#{scheme['config_env']}]"
              end

              case [scheme["type"], scheme["scheme"], scheme["location"]]
              when ["api_key", nil, "header"]
                request[:headers][scheme.fetch("parameter_name")] = credential
              when ["api_key", nil, "query"]
                request[:query][scheme.fetch("parameter_name")] = credential
              when ["http", "bearer", nil]
                request[:headers]["Authorization"] = "Bearer #{credential}"
              when ["http", "basic", nil]
                request[:headers]["Authorization"] = "Basic #{[credential].pack('m0')}"
              else
                raise ConfigurationError, "Unsupported generated auth placement for #{scheme_name}"
              end
            end

            def normalize_response(response, intent)
              http_status = fetch_value(response, :status).to_i
              headers = fetch_value(response, :headers) || {}
              body = parse_body(fetch_value(response, :body))
              if http_status.between?(200, 299)
                normalized_success(intent, http_status, headers, body)
              else
                normalized_error(intent, http_status, headers, body)
              end
            end

            def normalized_success(intent, http_status, headers, body)
              result = { success: true, http_status: http_status, headers: headers, raw: body }
              response_mappings_for(intent).each do |mapping|
                value = read_payload_path(body, mapping["source"])
                next if value.nil?

                if mapping["role"] == "status"
                  result[:provider_status] = value
                  result[:status] = normalize_status(value)
                else
                  result[mapping.fetch("role").to_sym] = value
                end
              end
              result
            end

            def normalized_error(intent, http_status, headers, body)
              operation_key = capability_operation(intent).fetch("key")
              definition = ADAPTER_CONFIG.fetch("errors").find do |candidate|
                candidate["operation_key"] == operation_key && status_matches?(candidate["http_status"], http_status)
              end || {}

              {
                success: false,
                http_status: http_status,
                provider_code: first_path_value(body, definition.fetch("provider_code_paths", [])),
                message: first_path_value(body, definition.fetch("message_paths", [])),
                retry_after: header_value(headers, "Retry-After"),
                raw: body
              }
            end

            def normalize_status(value)
              return :unknown if value.nil?

              STATUS_MAP.fetch(value.to_s, :unknown)
            end

            def verify_webhook_signature(webhook, headers, raw_body)
              signature = webhook.fetch("signature")
              header = signature["header"]
              algorithm = signature["algorithm"]
              encoding = signature["encoding"]
              return :manual_required unless header && algorithm && encoding

              raise ArgumentError, "raw_body is required for webhook signature verification" if raw_body.nil?

              supplied = header_value(headers, header)
              raise ProviderError, "Webhook signature header #{header} is missing" unless present?(supplied)

              secret = ENV[webhook.fetch("secret_env")]
              raise ConfigurationError, "Missing credential ENV[#{webhook['secret_env']}]" unless present?(secret)
              raise ConfigurationError, "Unsupported webhook algorithm #{algorithm}" unless algorithm == "hmac_sha256"

              digest = OpenSSL::HMAC.digest("SHA256", secret, raw_body)
              expected = encoding == "hex" ? digest.unpack1("H*") : [digest].pack("m0")
              raise ConfigurationError, "Unsupported webhook signature encoding #{encoding}" unless %w[hex base64].include?(encoding)
              raise ProviderError, "Webhook signature mismatch" unless secure_compare(expected, supplied.to_s)

              :verified
            end

            def secure_compare(expected, actual)
              return false unless expected.bytesize == actual.bytesize

              expected.bytes.zip(actual.bytes).reduce(0) { |result, (left, right)| result | (left ^ right) }.zero?
            end

            def capability_operation(intent)
              ADAPTER_CONFIG.dig("capabilities", intent, "operation") || raise(
                NotImplementedError,
                "Capability #{intent} is missing or requires manifest review"
              )
            end

            def ensure_detected!(intent)
              status = ADAPTER_CONFIG.dig("capabilities", intent, "status")
              return if status == "detected"

              raise NotImplementedError, "Capability #{intent} is #{status || 'missing'}"
            end

            def mappings_for(intent)
              ADAPTER_CONFIG.dig("field_mappings", intent, "request") || []
            end

            def response_mappings_for(intent)
              ADAPTER_CONFIG.dig("field_mappings", intent, "response") || []
            end

            def build_url(path)
              base_url = ENV.fetch(ADAPTER_CONFIG.fetch("base_url_env"), ADAPTER_CONFIG.fetch("base_urls").first)
              raise ConfigurationError, "Provider base URL is not declared" unless present?(base_url)
              raise ConfigurationError, "Provider base URL contains unresolved variables" if base_url.match?(/\{[^}]+\}/)

              "#{base_url.sub(%r{/+\z}, '')}/#{path.sub(%r{\A/+}, '')}"
            end

            def read_operation_path(operation, source)
              return nil if source.nil?

              path = source.to_s.sub(/\Aoperation\./, "")
              read_value_path(operation, path)
            end

            def read_payload_path(payload, path)
              return nil if path.nil?

              read_value_path(payload, path)
            end

            def read_value_path(value, path)
              path.to_s.split(".").reduce(value) do |current, segment|
                break nil if current.nil?

                if current.is_a?(Hash)
                  current[segment] || current[segment.to_sym]
                elsif current.respond_to?(segment)
                  current.public_send(segment)
                end
              end
            end

            def assign_payload_path(payload, path, value)
              segments = path.split(".")
              leaf = segments.pop
              target = segments.reduce(payload) do |current, segment|
                current[segment] = {} unless current[segment].is_a?(Hash)
                current[segment]
              end
              target[leaf] = normalize_value(value)
            end

            def normalize_value(value)
              case value
              when Hash
                value.each_with_object({}) { |(key, child), result| result[key.to_s] = normalize_value(child) }
              when Array
                value.map { |child| normalize_value(child) }
              else
                value.respond_to?(:to_h) ? normalize_value(value.to_h) : value
              end
            end

            def parse_body(value)
              return value if value.is_a?(Hash)
              return {} if value.nil? || value == ""

              JSON.parse(value.to_s)
            rescue JSON::ParserError => error
              raise ProviderError, "Provider returned invalid JSON: #{error.message}"
            end

            def first_path_value(body, paths)
              paths.each do |path|
                value = read_payload_path(body, path)
                return value unless value.nil?
              end
              nil
            end

            def status_matches?(declared, actual)
              value = declared.to_s.upcase
              value == "DEFAULT" || value == actual.to_s || (value.match?(/\A[45]XX\z/) && value[0] == actual.to_s[0])
            end

            def fetch_value(hash, key)
              hash[key] || hash[key.to_s]
            end

            def header_value(headers, name)
              pair = headers.find { |key, _value| key.to_s.casecmp(name).zero? }
              pair&.last
            end

            def present?(value)
              !(value.nil? || (value.respond_to?(:empty?) && value.empty?))
            end
          end
        end
      RUBY
    end
  end
end
