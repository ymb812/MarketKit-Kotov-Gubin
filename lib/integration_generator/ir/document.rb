# frozen_string_literal: true

require_relative "serialization"

module IntegrationGenerator
  module IR
    class Document
      include Serialization

      attr_reader :openapi_version, :operations, :warnings

      def initialize(openapi_version:, info:, servers:, security:, security_schemes:, schemas:, operations:, warnings:, source: nil)
        @openapi_version = openapi_version
        @info = info
        @servers = servers
        @security = security
        @security_schemes = security_schemes
        @schemas = schemas
        @operations = operations
        @warnings = warnings
        @source = source
      end

      def to_h
        serialize(
          "openapi" => openapi_version,
          "source" => @source,
          "info" => @info,
          "servers" => @servers,
          "security" => @security,
          "security_schemes" => @security_schemes,
          "schemas" => @schemas,
          "operations" => operations,
          "warnings" => warnings
        )
      end
    end
  end
end
