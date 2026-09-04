# frozen_string_literal: true

require "json"
require "yaml"

module IntegrationGenerator
  module OpenAPI
    class Loader
      SUPPORTED_EXTENSIONS = %w[.json .yaml .yml].freeze

      class << self
        def load_file(path)
          raise Error.new("FILE_NOT_FOUND", "OpenAPI file does not exist", location: path) unless File.file?(path)

          extension = File.extname(path).downcase
          unless SUPPORTED_EXTENSIONS.include?(extension)
            raise Error.new(
              "UNSUPPORTED_FORMAT",
              "Expected a .yaml, .yml, or .json OpenAPI file",
              location: path
            )
          end

          source = File.read(path, encoding: "bom|utf-8")
          parsed = extension == ".json" ? JSON.parse(source) : parse_yaml(source, path)
          deep_stringify_keys(parsed)
        rescue JSON::ParserError, Psych::Exception, EncodingError => e
          raise Error.new("PARSE_ERROR", e.message, location: path)
        rescue Errno::EACCES => e
          raise Error.new("FILE_NOT_READABLE", e.message, location: path)
        end

        private

        def parse_yaml(source, path)
          YAML.safe_load(
            source,
            permitted_classes: [],
            permitted_symbols: [],
            aliases: true,
            filename: path
          )
        end

        def deep_stringify_keys(value, ancestors = {})
          case value
          when Hash
            with_cycle_guard(value, ancestors) do
              value.each_with_object({}) do |(key, item), result|
                result[key.to_s] = deep_stringify_keys(item, ancestors)
              end
            end
          when Array
            with_cycle_guard(value, ancestors) do
              value.map { |item| deep_stringify_keys(item, ancestors) }
            end
          else
            value
          end
        end

        def with_cycle_guard(value, ancestors)
          if ancestors.key?(value.object_id)
            raise Error.new("PARSE_ERROR", "Cyclic YAML aliases are not supported")
          end

          ancestors[value.object_id] = true
          yield
        ensure
          ancestors.delete(value.object_id)
        end
      end
    end
  end
end
