# frozen_string_literal: true

module IntegrationGenerator
  module Analyzer
    class CapabilityResolver
      CAPABILITIES = %w[create_payout fetch_status cancel_payout webhook balance].freeze

      def resolve(operations)
        warnings = operation_warnings(operations)
        capabilities = CAPABILITIES.each_with_object({}) do |intent, result|
          result[intent] = resolve_capability(intent, operations, warnings)
        end

        {
          "capabilities" => capabilities,
          "unsupported_operations" => operations.select { |operation| operation.intent == "unknown" }.map(&:key),
          "warnings" => warnings
        }
      end

      private

      def resolve_capability(intent, operations, warnings)
        accepted = operations.select { |operation| operation.intent == intent && operation.decision == "accepted" }
        review = operations.select { |operation| operation.intent == intent && operation.decision == "review_recommended" }

        if accepted.length == 1
          operation = accepted.first
          return {
            "status" => "detected",
            "operation_key" => operation.key,
            "confidence" => operation.confidence,
            "candidates" => [candidate(operation)]
          }
        end

        candidates = accepted.empty? ? review : accepted + review
        if candidates.empty?
          warnings << Support.warning(
            "MISSING_CAPABILITY",
            "No operation was confidently identified for capability '#{intent}'",
            location: "#/capabilities/#{intent}"
          )
          return { "status" => "missing", "operation_key" => nil, "confidence" => 0.0, "candidates" => [] }
        end

        warnings << Support.warning(
          "AMBIGUOUS_CAPABILITY",
          "Capability '#{intent}' requires review because #{candidates.length} candidate operation(s) remain",
          location: "#/capabilities/#{intent}"
        )
        {
          "status" => "requires_review",
          "operation_key" => candidates.length == 1 ? candidates.first.key : nil,
          "confidence" => candidates.map(&:confidence).max,
          "candidates" => candidates.map { |operation| candidate(operation) }
        }
      end

      def operation_warnings(operations)
        operations.filter_map do |operation|
          case operation.decision
          when "ambiguous"
            Support.warning(
              "AMBIGUOUS_OPERATION_INTENT",
              "Operation '#{operation.key}' has competing semantic intents",
              location: "#/operations/#{operation.key}"
            )
          when "unsupported"
            Support.warning(
              "UNSUPPORTED_OPERATION",
              "Operation '#{operation.key}' does not match a supported payout capability",
              location: "#/operations/#{operation.key}"
            )
          end
        end
      end

      def candidate(operation)
        {
          "operation_key" => operation.key,
          "confidence" => operation.confidence,
          "decision" => operation.decision
        }
      end
    end
  end
end
