# frozen_string_literal: true

module IntegrationGenerator
  module Analyzer
    class WebhookAnalyzer
      SIGNATURE_WORDS = %w[signature hmac digest signed].freeze
      EVENT_FIELDS = %w[event event_type type].freeze
      STATUS_FIELDS = %w[status state payout_status transfer_status].freeze
      PROVIDER_ID_FIELDS = %w[payout_id transfer_id transaction_id operation_id id].freeze
      EXTERNAL_ID_FIELDS = %w[external_id merchant_reference client_reference reference].freeze
      ERROR_FIELDS = %w[error error_code code].freeze

      def analyze(document, operations, capabilities)
        capability = capabilities.fetch("webhook")
        return { "webhook" => { "status" => "missing" }, "warnings" => [] } if capability["status"] == "missing"

        operation = operations.find { |candidate| Support.operation_key(candidate) == capability["operation_key"] }
        return { "webhook" => { "status" => "requires_review" }, "warnings" => [] } unless operation

        warnings = []
        signature = extract_signature(operation, warnings)
        payload = extract_payload(operation, warnings)
        events = extract_events(operation, payload["event_path"])
        effective_security = operation["security"].nil? ? document["security"] : operation["security"]

        {
          "webhook" => {
            "status" => capability["status"],
            "operation_key" => Support.operation_key(operation),
            "confidence" => capability["confidence"],
            "security" => effective_security,
            "security_source" => operation["security"].nil? ? "inherited" : "operation",
            "signature" => signature,
            "payload" => payload,
            "events" => events
          },
          "warnings" => warnings
        }
      end

      private

      def extract_signature(operation, warnings)
        candidates = operation.fetch("parameters", []).select do |parameter|
          next false unless parameter["in"] == "header"

          tokens = Support.tokenize([parameter["name"], parameter["description"]].compact.join(" "))
          Support.intersection?(tokens, SIGNATURE_WORDS)
        end
        parameter = candidates.first
        text = [Support.text_blob(operation), parameter&.fetch("description", nil)].compact.join(" ")
        algorithm = detect_algorithm(text)
        encoding = detect_encoding(text)

        if candidates.length > 1
          warnings << Support.warning(
            "AMBIGUOUS_WEBHOOK_SIGNATURE_HEADER",
            "Multiple signature-like webhook headers were found; select a declared header with an override",
            location: "#/webhook/signature/header"
          )
        end
        if parameter.nil?
          warnings << Support.warning(
            "WEBHOOK_SIGNATURE_NOT_FOUND",
            "No signature header was found for the webhook operation",
            location: "#/webhook/signature"
          )
        else
          if algorithm.nil?
            warnings << Support.warning(
              "WEBHOOK_SIGNATURE_ALGORITHM_UNKNOWN",
              "Webhook signature algorithm is not structurally declared and requires review/override",
              location: "#/webhook/signature/algorithm"
            )
          end
          if encoding.nil?
            warnings << Support.warning(
              "WEBHOOK_SIGNATURE_ENCODING_UNKNOWN",
              "Webhook signature encoding is not structurally declared and requires review/override",
              location: "#/webhook/signature/encoding"
            )
          end
        end
        warnings << Support.warning(
          "CALLBACK_SECRET_NOT_DECLARED",
          "Callback verification secret is not declared in OpenAPI and must be configured manually",
          location: "#/webhook/signature/secret"
        )

        {
          "header" => candidates.length == 1 ? parameter.fetch("name") : nil,
          "algorithm" => algorithm,
          "encoding" => encoding,
          "confidence" => parameter && algorithm ? 0.9 : (parameter ? 0.6 : 0.0),
          "provenance" => "inferred"
        }
      end

      def detect_algorithm(text)
        return "hmac_sha256" if text.match?(/hmac[\s_-]*sha[\s_-]*256/i)
        return "sha256" if text.match?(/sha[\s_-]*256/i)

        nil
      end

      def detect_encoding(text)
        return "base64" if text.match?(/base[\s_-]*64/i)
        return "hex" if text.match?(/\bhex(?:adecimal)?\b/i)

        nil
      end

      def extract_payload(operation, warnings)
        _media_type, media = Support.json_content(operation.dig("request_body", "content"))
        entries = Support.schema_entries(media&.fetch("schema", nil), direction: :request)
        {
          "event_path" => choose_path(entries, EVENT_FIELDS, "event", warnings),
          "provider_operation_id_path" => choose_path(entries, PROVIDER_ID_FIELDS, "provider operation id", warnings),
          "external_id_path" => choose_path(entries, EXTERNAL_ID_FIELDS, "external id", warnings),
          "status_path" => choose_path(entries, STATUS_FIELDS, "status", warnings),
          "error_path" => choose_path(entries, ERROR_FIELDS, "error", warnings)
        }
      end

      def extract_events(operation, event_path)
        return {} unless event_path

        _media_type, media = Support.json_content(operation.dig("request_body", "content"))
        entry = Support.schema_entries(media&.fetch("schema", nil), direction: :request).find do |path, _schema|
          path == event_path
        end
        return {} unless entry

        entry.last.fetch("enum", []).each_with_object({}) do |event, result|
          semantic_status = event.to_s.split(/[.:]/).last
          normalized = StatusAnalyzer.normalize(semantic_status)
          result[event.to_s] = {
            "normalized_status" => normalized || "unknown",
            "requires_review" => normalized.nil?,
            "provenance" => "inferred"
          }
        end
      end

      def choose_path(entries, names, role, warnings)
        names.each do |name|
          matches = entries.select { |path, _schema| path.split(".").last.to_s.delete_suffix("[]") == name }
          next if matches.empty?

          if matches.length > 1
            warnings << Support.warning(
              "AMBIGUOUS_WEBHOOK_PAYLOAD_PATH",
              "Multiple webhook payload paths match role '#{role}'; select a declared path with an override",
              location: "#/webhook/payload/#{role.tr(' ', '_')}_path"
            )
            return nil
          end
          return matches.first.first
        end
        nil
      end
    end
  end
end
