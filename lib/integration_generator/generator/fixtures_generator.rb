# frozen_string_literal: true

module IntegrationGenerator
  module Generator
    class FixturesGenerator
      CAPABILITIES = %w[create_payout fetch_status cancel_payout webhook balance].freeze

      def initialize(manifest)
        @manifest = Support.manifest_hash(manifest)
      end

      def to_h
        fixtures = {}
        unavailable = []

        CAPABILITIES.each do |intent|
          capability, operation = Support.capability_row(@manifest, intent)
          unless capability["status"] == "detected" && operation
            unavailable << {
              "capability" => intent,
              "reason" => capability["status"] == "missing" ? "MISSING_CAPABILITY" : "CAPABILITY_REQUIRES_REVIEW"
            }
            next
          end

          fixtures[intent] = intent == "webhook" ? webhook_fixture(operation) : operation_fixture(intent, operation)
        end

        {
          "format_version" => "1.0",
          "provider" => Support.deep_copy(@manifest["provider"]),
          "source" => Support.deep_copy(@manifest["source"]),
          "fixtures" => fixtures,
          "unavailable_fixtures" => unavailable,
          "warnings" => @manifest["warnings"].map { |warning| warning.slice("code", "message", "location") }
        }
      end

      private

      def operation_fixture(intent, operation)
        result = { "operation" => operation_identity(operation) }
        request = request_fixture(intent, operation)
        result["request"] = request if request

        success = response_fixture(intent, operation, success: true)
        error = response_fixture(intent, operation, success: false)
        result["success_response"] = success if success
        result["error_response"] = error if error
        result
      end

      def request_fixture(intent, operation)
        request_body = operation.dig("contract", "request_body")
        _media_type, media = Support.json_media(request_body&.fetch("content", nil))
        example = media ? Support.example_or_schema(media, path: "request", direction: :request) : nil
        parameters, parameter_provenance = parameter_fixture(
          intent,
          operation,
          example&.fetch("value", nil),
          example&.fetch("provenance", nil)
        )
        return nil if example.nil? && parameters.empty?

        fixture = {}
        if example
          fixture["body"] = example["value"]
          fixture["provenance"] = example["provenance"]
          fixture["example_name"] = example["name"] if example["name"]
        end
        fixture["parameters"] = parameters unless parameters.empty?
        fixture["parameter_provenance"] = parameter_provenance unless parameter_provenance.empty?
        fixture
      end

      def parameter_fixture(intent, operation, request_body, request_provenance)
        mappings = @manifest.dig("field_mappings", intent, "request") || []
        values = {}
        provenance = {}
        mappings.each do |mapping|
          next if mapping["location"] == "body"

          parameter = operation.dig("contract", "parameters")&.find do |candidate|
            candidate["name"] == mapping["target"] && candidate["in"] == mapping["location"]
          end
          sibling = mappings.find do |candidate|
            candidate["location"] == "body" && candidate["source_candidate"] == mapping["source_candidate"]
          end
          value = sibling && Support.dig_path(request_body, sibling["target"])
          source = value.nil? ? nil : (request_provenance || "schema_generated")
          if value.nil? && parameter && !parameter["example"].nil?
            value = parameter["example"]
            source = "openapi_example"
          end
          if value.nil? && parameter
            named_example = parameter.fetch("examples", {}).values.first
            value = named_example.is_a?(Hash) && named_example.key?("value") ? named_example["value"] : named_example
            source = "openapi_example" unless value.nil?
          end
          if value.nil? && parameter
            value = Support.schema_fixture(parameter["schema"], path: mapping["target"])
            source = "schema_generated" unless value.nil?
          end
          normalized_name = mapping["target"].to_s
                                             .gsub(/([[:lower:]\d])([[:upper:]])/, "\\1_\\2")
                                             .downcase
                                             .gsub(/[^a-z0-9]+/, "_")
                                             .gsub(/\A_+|_+\z/, "")
          if value.nil?
            value = "#{normalized_name}_example"
            source = "schema_generated"
          end
          values[mapping["target"]] = value
          provenance[mapping["target"]] = source
        end
        [values, provenance]
      end

      def response_fixture(intent, operation, success:)
        responses = operation.dig("contract", "responses") || {}
        status, response = select_response(responses, success: success)
        return nil unless response

        _media_type, media = Support.json_media(response["content"])
        example = Support.example_or_schema(media, path: "response", direction: :response)
        body = example["value"]
        body = body.reject { |key, _value| key == "error" } if success && example["provenance"] == "schema_generated" && body.is_a?(Hash)
        fixture = {
          "http_status" => status,
          "body" => body,
          "provenance" => example["provenance"]
        }
        fixture["example_name"] = example["name"] if example["name"]
        if success && intent == "cancel_payout" && example["provenance"] == "schema_generated"
          fixture["scenario"] = "schema_shape_only"
        end

        expected = success ? expected_response(intent, body, http_status: status) : {}
        expected.delete("normalized_status") if fixture["scenario"] == "schema_shape_only"
        fixture["expected"] = expected unless expected.empty?
        fixture
      end

      def select_response(responses, success:)
        candidates = responses.select do |status, _response|
          success ? status.to_s.match?(/\A2(?:\d\d|XX)\z/i) : error_status?(status)
        end
        return [nil, nil] if candidates.empty?

        unless success
          preferred = %w[422 400].filter_map { |status| candidates.find { |candidate, _response| candidate == status } }.first
          return preferred if preferred

          with_example = candidates.find do |_status, response|
            _type, media = Support.json_media(response["content"])
            !Support.media_examples(media).empty?
          end
          return with_example if with_example
        end
        candidates.first
      end

      def error_status?(status)
        value = status.to_s
        value.casecmp("default").zero? || value.match?(/\A[45](?:\d\d|XX)\z/i)
      end

      def expected_response(intent, body, http_status: nil)
        return {} unless body.is_a?(Hash)

        mappings = @manifest.dig("field_mappings", intent, "response") || []
        mappings.each_with_object({}) do |mapping, result|
          next if http_status && mapping["http_status"] && mapping["http_status"] != http_status
          value = Support.dig_path(body, mapping["source"])
          next if value.nil?

          if mapping["role"] == "status"
            status = @manifest.dig("status_mapping", "mappings", value.to_s)
            next if status.nil? || status["normalized"] == "unknown" || status["requires_review"] || status["provenance"] == "default_rule"

            result["normalized_status"] = {
              "path" => mapping["source"],
              "provider_value" => value,
              "value" => status["normalized"]
            }
          else
            result[mapping["role"]] = { "path" => mapping["source"], "value" => value }
          end
        end
      end

      def webhook_fixture(operation)
        request_body = operation.dig("contract", "request_body")
        _media_type, media = Support.json_media(request_body&.fetch("content", nil))
        examples = Support.media_examples(media)
        examples = [Support.example_or_schema(media, path: "callback", direction: :request)] if examples.empty?

        callbacks = examples.map do |example|
          body = example["value"]
          item = {
            "body" => body,
            "provenance" => example["provenance"],
            "expected" => expected_callback(body)
          }
          item["name"] = example["name"] if example["name"]
          item["summary"] = example["summary"] if example["summary"]
          item
        end

        {
          "operation" => operation_identity(operation),
          "callbacks" => callbacks,
          "processing" => {
            "method" => "process_callback",
            "input" => "parsed_json_object",
            "authentication" => "host_required",
            "terminal_status_effect" => "approve_operation / reject_operation",
            "verified_method" => "process_verified_callback"
          },
          "signature" => {
            "header" => @manifest.dig("webhook", "signature", "header"),
            "algorithm" => @manifest.dig("webhook", "signature", "algorithm"),
            "encoding" => @manifest.dig("webhook", "signature", "encoding"),
            "verification" => webhook_verification_configured? ? "configured" : "manual_required"
          }
        }
      end

      def expected_callback(body)
        payload = @manifest.dig("webhook", "payload") || {}
        provider_status = Support.dig_path(body, payload["status_path"])
        status = @manifest.dig("status_mapping", "mappings", provider_status.to_s)
        normalized = status["normalized"] if status && !status["requires_review"] && status["provenance"] != "default_rule"
        action = case normalized
                 when "approved" then "approve_operation"
                 when "rejected" then "reject_operation"
                 else "no_status_change"
                 end
        {
          "provider_operation_id" => Support.dig_path(body, payload["provider_operation_id_path"]),
          "provider_status" => provider_status,
          "platform_action" => action,
          "error" => Support.dig_path(body, payload["error_path"])
        }.reject { |_key, value| value.nil? }
      end

      def operation_identity(operation)
        operation.slice("key", "operation_id", "method", "path")
      end

      def webhook_verification_configured?
        signature = @manifest.dig("webhook", "signature") || {}
        signature["header"] && signature["algorithm"] == "hmac_sha256" && %w[hex base64].include?(signature["encoding"])
      end
    end
  end
end
