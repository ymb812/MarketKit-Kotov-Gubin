# frozen_string_literal: true

module IntegrationGenerator
  module ProviderIR
    class Operation
      INTENTS = %w[create_payout fetch_status cancel_payout webhook balance unknown].freeze
      DECISIONS = %w[accepted review_recommended ambiguous unsupported].freeze

      attr_reader :key, :intent, :confidence, :decision

      def initialize(attributes)
        @attributes = attributes
        @key = attributes.fetch("key")
        @intent = attributes.fetch("intent")
        @confidence = attributes.fetch("confidence")
        @decision = attributes.fetch("decision")
        validate!
      end

      def to_h
        deep_copy(@attributes)
      end

      private

      def validate!
        raise ArgumentError, "Operation key must use 'METHOD /path' format" unless key.is_a?(String) && key.match?(/\A[A-Z]+ \/\S*/)
        raise ArgumentError, "Unknown operation intent #{intent.inspect}" unless INTENTS.include?(intent)
        raise ArgumentError, "Unknown operation decision #{decision.inspect}" unless DECISIONS.include?(decision)
        return if confidence.is_a?(Numeric) && confidence.between?(0.0, 1.0)

        raise ArgumentError, "Operation confidence must be between 0.0 and 1.0"
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
