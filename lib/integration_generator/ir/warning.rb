# frozen_string_literal: true

module IntegrationGenerator
  module IR
    class Warning
      attr_reader :code, :message, :location

      def initialize(code:, message:, location: nil)
        @code = code.to_s
        @message = message
        @location = location
      end

      def to_h
        {
          "code" => code,
          "message" => message,
          "location" => location
        }
      end
    end
  end
end

