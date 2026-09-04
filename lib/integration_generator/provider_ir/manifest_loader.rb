# frozen_string_literal: true

require "json"
require "yaml"

module IntegrationGenerator
  module ProviderIR
    class ManifestLoader
      SUPPORTED_EXTENSIONS = %w[.json .yaml .yml].freeze

      class << self
        def load_file(path)
          raise Error.new("MANIFEST_NOT_FOUND", "Integration Manifest file does not exist", location: path) unless File.file?(path)

          extension = File.extname(path).downcase
          unless SUPPORTED_EXTENSIONS.include?(extension)
            raise Error.new(
              "UNSUPPORTED_MANIFEST_FORMAT",
              "Expected a .yaml, .yml, or .json Integration Manifest file",
              location: path
            )
          end

          source = File.read(path, encoding: "bom|utf-8")
          parsed = extension == ".json" ? JSON.parse(source) : parse_yaml(source, path)
          raise Error.new("MANIFEST_INVALID", "Integration Manifest root must be an object", location: path) unless parsed.is_a?(Hash)

          Manifest.new(deep_stringify_keys(parsed))
        rescue JSON::ParserError, Psych::Exception, EncodingError => e
          raise Error.new("MANIFEST_PARSE_ERROR", e.message, location: path)
        rescue ArgumentError, KeyError => e
          raise Error.new("MANIFEST_INVALID", e.message, location: path)
        rescue Errno::EACCES => e
          raise Error.new("MANIFEST_NOT_READABLE", e.message, location: path)
        end

        private

        def parse_yaml(source, path)
          YAML.safe_load(
            source,
            permitted_classes: [],
            permitted_symbols: [],
            aliases: false,
            filename: path
          )
        end

        def deep_stringify_keys(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, item), result|
              result[key.to_s] = deep_stringify_keys(item)
            end
          when Array
            value.map { |item| deep_stringify_keys(item) }
          else
            value
          end
        end
      end
    end
  end
end
