# frozen_string_literal: true

module IntegrationGenerator
  module IR
    module Serialization
      private

      def serialize(value)
        case value
        when Array
          value.map { |item| serialize(item) }
        when Hash
          value.each_with_object({}) do |(key, item), result|
            result[key.to_s] = serialize(item)
          end
        when nil, String, Numeric, true, false
          value
        else
          value.respond_to?(:to_h) ? serialize(value.to_h) : value
        end
      end
    end
  end
end
