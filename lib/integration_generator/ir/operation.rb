# frozen_string_literal: true

require_relative "serialization"

module IntegrationGenerator
  module IR
    class Operation
      include Serialization

      def initialize(attributes)
        @attributes = attributes
      end

      def to_h
        serialize(@attributes)
      end
    end
  end
end

