# frozen_string_literal: true

require "json"
require "yaml"

module IntegrationGenerator
  module Generator
    class ArtifactBundle
      attr_reader :manifest

      def initialize(manifest)
        @manifest = ProviderIR::Manifest.new(Support.manifest_hash(manifest))
      end

      def render
        service = ServiceGenerator.new(manifest)
        artifacts = {
          service.filename => service.render,
          "INTEGRATION.md" => DocumentationGenerator.new(manifest).render,
          "fixtures.json" => "#{JSON.pretty_generate(FixturesGenerator.new(manifest).to_h)}\n",
          "integration_manifest.yml" => YAML.dump(manifest.to_h)
        }
        validate!(artifacts)
        artifacts
      end

      private

      def validate!(artifacts)
        service_name = artifacts.keys.find { |name| name.end_with?("_service.rb") }
        validate_ruby!(artifacts.fetch(service_name), service_name)
        JSON.parse(artifacts.fetch("fixtures.json"))
        loaded_manifest = YAML.safe_load(
          artifacts.fetch("integration_manifest.yml"),
          permitted_classes: [],
          permitted_symbols: [],
          aliases: false
        )
        ProviderIR::Manifest.new(loaded_manifest)
        raise Error.new("GENERATION_INVALID", "Generated INTEGRATION.md is empty") if artifacts.fetch("INTEGRATION.md").strip.empty?
      rescue JSON::ParserError, Psych::Exception, ArgumentError, KeyError, NoMethodError, TypeError, SyntaxError => e
        raise Error.new("GENERATION_INVALID", e.message)
      end

      def validate_ruby!(source, filename)
        if defined?(RubyVM::InstructionSequence)
          RubyVM::InstructionSequence.compile(source, filename)
        else
          require "ripper"
          raise SyntaxError, "Generated Ruby syntax is invalid" unless Ripper.sexp(source)
        end
      end
    end
  end
end
