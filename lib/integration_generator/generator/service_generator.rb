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
                  "path" => operation["path"],
                  "response_statuses" => (operation.dig("contract", "responses") || {}).keys
                }
              }
            ]
          end,
          "auth" => compact_auth,
          "field_mappings" => compact_field_mappings,
          "request_schema" => create_request_schema,
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

      def create_request_schema
        operation = Support.operation_for(@manifest, "create_payout")
        _type, media = Support.json_media(operation&.dig("contract", "request_body", "content"))
        media && media["schema"]
      end

      def compact_field_mappings
        @manifest["field_mappings"].transform_values do |mapping|
          {
            "request" => mapping.fetch("request", []).map do |field|
              field.slice(
                "role", "target", "location", "source_candidate", "constant_value",
                "required", "requires_review", "schema"
              )
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

            STATUS_MAP = ADAPTER_CONFIG.fetch("status_mapping").each_with_object({}) do |(provider_status, mapping), result|
              next if mapping["requires_review"] || mapping["provenance"] == "default_rule"

              result[provider_status] = mapping.fetch("normalized").to_sym
            end.freeze

            attr_writer :provider_client

            def check_conditions(operation, request_method = nil)
              errors = condition_errors(operation, request_method)
              return success if errors.empty?

              failure(:bad_request, errors.map { |error| error.fetch(:message) }.join("; "))
            end

            def create_request(operation, request_method: nil, allow_unreviewed: false)
              ensure_detected!("create_payout")
              errors = condition_errors(operation, request_method)
              return failure(:bad_request, errors.map { |error| error.fetch(:message) }.join("; ")) unless errors.empty?

              response = dispatch(
                build_request(
                  "create_payout", operation, request_method: request_method,
                  allow_unreviewed: allow_unreviewed
                )
              )
              normalized = normalize_response(response, "create_payout")
              return provider_failure(normalized) unless normalized[:success]

              provider_id = normalized[:provider_operation_id]
              return failure(:internal_server_error, "operation.provider_response_invalid") unless present?(provider_id)

              success(result: { id: provider_id })
            end

            def create_payout(operation, request_method: nil, allow_unreviewed: false)
              create_request(operation, request_method: request_method, allow_unreviewed: allow_unreviewed)
            end

            # Review/debug boundary: returns the provider request without sending it.
            def build_provider_request(operation, request_method: nil, allow_unreviewed: false)
              ensure_detected!("create_payout")
              errors = condition_errors(operation, request_method)
              raise ArgumentError, errors.map { |error| error.fetch(:message) }.join("; ") unless errors.empty?

              build_request(
                "create_payout", operation, request_method: request_method,
                allow_unreviewed: allow_unreviewed
              )
            end

            def fetch_status(operation, allow_unreviewed: false)
              ensure_detected!("fetch_status")
              response = dispatch(
                build_request("fetch_status", operation, request_method: nil, allow_unreviewed: allow_unreviewed)
              )
              normalized = normalize_response(response, "fetch_status")
              return provider_failure(normalized) unless normalized[:success]

              apply_operation_status(
                read_operation_path(operation, "operation.id"), normalized[:status], normalized[:provider_code]
              )
            end

            def cancel_payout(operation, allow_unreviewed: false)
              ensure_detected!("cancel_payout")
              response = dispatch(
                build_request("cancel_payout", operation, request_method: nil, allow_unreviewed: allow_unreviewed)
              )
              normalized = normalize_response(response, "cancel_payout")
              normalized[:success] ? success : provider_failure(normalized)
            end

            def fetch_balance
              ensure_detected!("balance")
              response = dispatch(build_request("balance", nil, request_method: nil, allow_unreviewed: false))
              normalized = normalize_response(response, "balance")
              normalized[:success] ? success(result: normalized[:raw]) : provider_failure(normalized)
            end

            # The host passes parsed JSON after enforcing its inbound authentication policy.
            # Mapping a payload alone does not authenticate it; the result makes that explicit.
            def process_callback(payload, headers: nil, raw_body: nil, allow_unverified: false)
              ensure_detected!("webhook")
              webhook = ADAPTER_CONFIG.fetch("webhook")
              if raw_body.nil? && headers.nil?
                raise ArgumentError, "Callback payload must be a parsed JSON object" unless payload.is_a?(Hash)

                body = payload
                verification = :host_required
              else
                verification = verify_webhook_signature(webhook, headers || {}, raw_body)
                body = parse_body(verification == :verified ? raw_body : payload)
              end
              if verification == :manual_required && !allow_unverified
                raise ConfigurationError,
                      "Webhook verification is not fully configured; review the manifest or pass allow_unverified: true only for inspection"
              end
              paths = webhook.fetch("payload")
              if !allow_unverified && (!paths["status_path"] || !paths["provider_operation_id_path"])
                raise ConfigurationError, "Webhook status/id mapping is missing or ambiguous; review the manifest"
              end
              provider_status = read_payload_path(body, paths["status_path"])

              result = {
                event: read_payload_path(body, paths["event_path"]),
                provider_operation_id: read_payload_path(body, paths["provider_operation_id_path"]),
                external_id: read_payload_path(body, paths["external_id_path"]),
                provider_status: provider_status,
                status: normalize_status(provider_status),
                error: read_payload_path(body, paths["error_path"]),
                signature_verification: verification,
                raw: body
              }
              apply_operation_status(result[:provider_operation_id], result[:status], result[:error])
            end

            # Use at the HTTP boundary where the original signed bytes are available.
            def process_verified_callback(raw_body, headers:)
              process_callback(nil, raw_body: raw_body, headers: headers)
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

            def build_request(intent, operation, request_method:, allow_unreviewed:)
              definition = capability_operation(intent)
              request = {
                method: definition.fetch("method").downcase.to_sym,
                url: build_url(interpolate_path(definition.fetch("path"), intent, operation)),
                headers: {},
                query: {},
                body: nil
              }

              body = {}
              mappings = mappings_for(intent)
              mappings.sort_by { |mapping| mapping["target"].to_s.count(".") }.each do |mapping|
                if mapping["target"].to_s.include?("[]")
                  next if covered_by_reviewed_array_mapping?(mapping, mappings)

                  raise ConfigurationError, "Array element mappings require a reviewed whole-array source"
                end
                location = mapping["location"] || "body"
                next if location == "path"

                source = mapping["source_candidate"]
                unless source || mapping.key?("constant_value")
                  if mapping["required"]
                    raise ConfigurationError, "Manual mapping required for #{location} parameter #{mapping['target']}"
                  end
                  next
                end
                value = mapping_value(operation, request_method, mapping)
                explicit_nullable = value.nil? && nullable_body_value?(operation, mapping, value)
                if value.nil?
                  if mapping["required"] && !explicit_nullable
                    raise ArgumentError, "Required provider field #{mapping['target']} is missing"
                  end
                  next unless explicit_nullable
                end
                if mapping["requires_review"] && !allow_unreviewed
                  raise ConfigurationError,
                        "Mapping #{mapping['target']} requires manifest review; use an override before production"
                end
                value = transform_value(mapping, value) unless value.nil?
                value = project_to_provider_schema(value, mapping["schema"]) if location == "body"

                case location
                when "body"
                  assign_payload_path(body, mapping.fetch("target"), value)
                when "header"
                  request[:headers][mapping.fetch("target")] = value.to_s
                when "query"
                  request[:query][mapping.fetch("target")] = value
                end
              end
              validate_required_body!(body, ADAPTER_CONFIG["request_schema"]) if intent == "create_payout"
              request[:body] = body unless body.empty?
              apply_auth(request, definition.fetch("key"))
              request
            end

            def covered_by_reviewed_array_mapping?(mapping, mappings)
              target = mapping["target"].to_s
              array_index = target.index("[]")
              return false unless array_index

              parent = target[0...array_index]
              mappings.any? do |candidate|
                candidate["target"] == parent && candidate["location"] == "body" &&
                  candidate.dig("schema", "kind") == "array" && !candidate["requires_review"] &&
                  (present?(candidate["source_candidate"]) || candidate.key?("constant_value"))
              end
            end

            def interpolate_path(path, intent, operation)
              mappings = mappings_for(intent).select { |mapping| mapping["location"] == "path" }
              mappings.reduce(path.dup) do |result, mapping|
                value = mapping_value(operation, nil, mapping)
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
              numeric = begin
                Rational(value.to_s)
              rescue ArgumentError, ZeroDivisionError
                raise ArgumentError, "Amount #{value.inspect} is not an exact numeric value"
              end
              converted = numeric * factor
              unless converted.denominator == 1
                raise ArgumentError, "Amount #{value.inspect} cannot be converted to integral provider minor units"
              end
              converted.to_i
            end

            def apply_auth(request, operation_key)
              auth = ADAPTER_CONFIG.fetch("auth")
              operation_auth = auth.fetch("operations").fetch(operation_key, {})
              requirements = operation_auth["requirements"] || []
              supported = requirements.select { |candidate| candidate["supported"] }
              requirement = supported.find do |candidate|
                candidate.fetch("schemes").all? do |name|
                  scheme = auth.fetch("schemes").find { |entry| entry["name"] == name }
                  scheme && present?(ENV[scheme.fetch("config_env")])
                end
              end || supported.first
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
              response_mappings = response_mappings_for(intent)
              declared = capability_operation(intent)["response_statuses"] || response_mappings.map { |mapping| mapping["http_status"] }.compact
              response_key = declared.find { |code| code.to_s == http_status.to_s } ||
                             declared.find { |code| code.to_s.upcase == "#{http_status.to_s[0]}XX" }
              response_mappings.each do |mapping|
                next if mapping["http_status"] && mapping["http_status"].to_s.upcase != response_key.to_s.upcase
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
              definition = ADAPTER_CONFIG.fetch("errors").select do |candidate|
                candidate["operation_key"] == operation_key && status_matches?(candidate["http_status"], http_status)
              end.min_by do |candidate|
                declared = candidate["http_status"].to_s.upcase
                declared == http_status.to_s ? 0 : (declared == "DEFAULT" ? 2 : 1)
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

            def provider_failure(result)
              code = result[:provider_code].to_s
              if code == "amount_limit_exceeded"
                return failure(:unprocessable_entity, "operation.amount_limit_exceeded")
              end

              failure(platform_failure_code(result[:http_status]), platform_failure_message(result[:http_status]))
            end

            def platform_failure_code(http_status)
              case http_status.to_i
              when 400 then :bad_request
              when 401 then :unauthorized
              when 403 then :forbidden
              when 422 then :unprocessable_entity
              when 429 then :too_many_requests
              when 400..499 then :unprocessable_entity
              else :internal_server_error
              end
            end

            def platform_failure_message(http_status)
              case http_status.to_i
              when 401 then "provider.invalid_credentials"
              when 429 then "provider.rate_limit"
              else "operation.provider_error"
              end
            end

            def apply_operation_status(operation_id, status, rejection_reason = nil)
              case status
              when :approved
                approve_operation(operation_id)
              when :rejected
                reject_operation(operation_id, rejection_reason || "operation.provider_error")
              else
                success
              end
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

            def condition_errors(operation, request_method)
              required_mapping_errors = mappings_for("create_payout").filter_map do |mapping|
                next unless mapping["required"]

                value = mapping_value(operation, request_method, mapping)
                next if present?(value) || nullable_body_value?(operation, mapping, value)

                {
                  code: "required_field_missing",
                  field: mapping["source_candidate"] || mapping["target"],
                  message: "Required provider field #{mapping['target']} has no mapped operation value"
                }
              end
              required_mapping_errors + conditional_requirement_errors(operation, request_method)
            end

            def conditional_requirement_errors(operation, request_method)
              conditional_requirements.filter_map do |requirement|
                # Text-derived rules remain review-only until an override confirms them.
                next if requirement["requires_review"]

                field = requirement["field"]
                condition = requirement["required_if"] || {}
                condition_field = condition["field"]
                expected = condition["equals"]
                condition_mapping = confirmed_mapping_for_provider_field(condition_field)
                required_mapping = confirmed_mapping_for_provider_field(field)

                unless condition_mapping && required_mapping
                  raise ConfigurationError,
                        "Conditional requirement for #{field} needs confirmed field mappings"
                end

                actual = provider_field_value(operation, request_method, condition_field, condition_mapping)
                next unless values_equal?(actual, expected)
                next if present?(provider_field_value(operation, request_method, field, required_mapping))

                {
                  code: "conditional_required_field_missing",
                  field: required_mapping["source_candidate"] || field,
                  message: "Provider field #{field} is required when #{condition_field} equals #{expected.inspect}"
                }
              end
            end

            def conditional_requirements
              ADAPTER_CONFIG.dig("transformations", "conditional_requirements") || []
            end

            def confirmed_mapping_for_provider_field(provider_field)
              mappings = mappings_for("create_payout")
              direct = mappings.find { |mapping| mapping["target"] == provider_field }
              return direct if mapping_confirmed?(direct)

              parent = mappings.select do |mapping|
                target = mapping["target"].to_s
                provider_field.to_s.start_with?("#{target}.")
              end.max_by { |mapping| mapping["target"].to_s.length }
              mapping_confirmed?(parent) ? parent : nil
            end

            def mapping_confirmed?(mapping)
              mapping && !mapping["requires_review"] &&
                (present?(mapping["source_candidate"]) || mapping.key?("constant_value"))
            end

            def provider_field_value(operation, request_method, provider_field, mapping)
              value = mapping_value(operation, request_method, mapping)
              suffix = provider_field.to_s.delete_prefix(mapping["target"].to_s).delete_prefix(".")
              suffix.empty? ? value : read_value_path(value, suffix)
            end

            def mapping_value(operation, request_method, mapping)
              return mapping["constant_value"] if mapping.key?("constant_value")

              source = mapping["source_candidate"]
              return (request_method || inferred_request_method(operation))&.to_s if source == "request_method"

              read_operation_path(operation, source)
            end

            def inferred_request_method(operation)
              requisites = read_operation_path(operation, "operation.payout_requisite")
              return :sbp if requisites.is_a?(Hash) && (requisites.key?("sbp") || requisites.key?(:sbp))
              return :card if requisites.is_a?(Hash) && (requisites.key?("card_number") || requisites.key?(:card_number))

              nil
            end

            def values_equal?(actual, expected)
              !actual.nil? && actual.to_s == expected.to_s
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

            def nullable_body_value?(operation, mapping, value)
              return false unless value.nil? && (mapping["location"] || "body") == "body" && mapping.dig("schema", "nullable")
              return true if mapping.key?("constant_value")

              source = mapping["source_candidate"]
              return false if source.nil? || source == "request_method"

              current = operation
              source.to_s.sub(/\Aoperation\./, "").split(".").each do |segment|
                if current.is_a?(Hash)
                  return false unless current.key?(segment) || current.key?(segment.to_sym)
                  current = current.key?(segment) ? current[segment] : current[segment.to_sym]
                elsif current.respond_to?(segment)
                  current = current.public_send(segment)
                else
                  return false
                end
              end
              current.nil?
            end

            def read_payload_path(payload, path)
              return nil if path.nil?

              read_value_path(payload, path)
            end

            def read_value_path(value, path)
              path.to_s.split(".").reduce(value) do |current, segment|
                break nil if current.nil?

                if current.is_a?(Hash)
                  if current.key?(segment)
                    current[segment]
                  elsif current.key?(segment.to_sym)
                    current[segment.to_sym]
                  end
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
              when nil
                nil
              when Hash
                value.each_with_object({}) { |(key, child), result| result[key.to_s] = normalize_value(child) }
              when Array
                value.map { |child| normalize_value(child) }
              else
                value.respond_to?(:to_h) ? normalize_value(value.to_h) : value
              end
            end

            def project_to_provider_schema(value, schema)
              normalized = normalize_value(value)
              return nil if normalized.nil? && schema.is_a?(Hash) && schema["nullable"]
              unless schema.is_a?(Hash)
                return normalized unless normalized.is_a?(Hash) || normalized.is_a?(Array)

                raise ConfigurationError, "Composite request mapping has no provider schema boundary"
              end

              case schema["kind"]
              when "object"
                unless normalized.is_a?(Hash)
                  raise ConfigurationError, "Provider object field received #{normalized.class}"
                end

                properties = schema.fetch("properties", {})
                additional = schema["additional_properties"]
                if properties.empty? && additional.nil?
                  raise ConfigurationError, "Provider object schema does not declare a safe projection boundary"
                end

                result = properties.each_with_object({}) do |(name, child_schema), projected|
                  next if child_schema["read_only"]
                  next unless normalized.key?(name)

                  projected[name] = project_to_provider_schema(normalized[name], child_schema)
                end
                normalized.each do |name, child|
                  next if properties.key?(name) || additional == false || additional.nil?

                  result[name] = additional == true ? child : project_to_provider_schema(child, additional)
                end
                result
              when "array"
                unless normalized.is_a?(Array)
                  raise ConfigurationError, "Provider array field received #{normalized.class}"
                end
                unless schema["items"].is_a?(Hash)
                  raise ConfigurationError, "Provider array schema does not declare item boundaries"
                end

                normalized.map { |item| project_to_provider_schema(item, schema["items"]) }
              when "unknown"
                if normalized.is_a?(Hash) || normalized.is_a?(Array)
                  raise ConfigurationError, "Composite request mapping has an unknown provider schema boundary"
                end
                normalized
              else
                if normalized.is_a?(Hash) || normalized.is_a?(Array)
                  raise ConfigurationError, "Provider scalar field received a composite value"
                end
                normalized
              end
            end

            def validate_required_body!(value, schema, path = "body")
              return unless schema.is_a?(Hash)

              if schema["kind"] == "object" && value.is_a?(Hash)
                schema.fetch("required", []).each do |name|
                  next if schema.dig("properties", name, "read_only")
                  unless value.key?(name)
                    raise ArgumentError, "Required provider field #{path}.#{name} is missing"
                  end
                end
                schema.fetch("properties", {}).each do |name, child|
                  next if child["read_only"]
                  validate_required_body!(value[name], child, "#{path}.#{name}") if value.key?(name)
                end
              elsif schema["kind"] == "array" && value.is_a?(Array)
                value.each_with_index do |item, index|
                  validate_required_body!(item, schema["items"], "#{path}[#{index}]")
                end
              elsif value.nil? && !schema["nullable"]
                raise ArgumentError, "Provider field #{path} cannot be null"
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
              value == "DEFAULT" || value == actual.to_s || (value.match?(/\A[1-5]XX\z/) && value[0] == actual.to_s[0])
            end

            def fetch_value(hash, key)
              return hash[key] if hash.key?(key)
              return hash[key.to_s] if hash.key?(key.to_s)

              nil
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
