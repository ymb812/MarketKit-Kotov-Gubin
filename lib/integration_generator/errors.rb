# frozen_string_literal: true

module IntegrationGenerator
  class Error < StandardError
    attr_reader :code, :location

    def initialize(code, message, location: nil)
      @code = code.to_s
      @location = location
      super(message)
    end

    def formatted
      suffix = location ? " at #{location}" : ""
      "[#{code}] #{message}#{suffix}"
    end
  end
end

