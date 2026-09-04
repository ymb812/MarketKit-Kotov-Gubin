# frozen_string_literal: true

require "json"
require "optparse"
require "yaml"

module IntegrationGenerator
  class CLI
    ROOT_HELP = <<~HELP.freeze
      Usage: integrate COMMAND [options]

      Commands:
        inspect    Parse OpenAPI 3.x and print normalized Generic IR
        analyze    Build a reviewable payout Integration Manifest
        generate   Generate Ruby service, docs, fixtures and exact manifest

      Run 'integrate COMMAND --help' for command options.
    HELP

    class << self
      def start(argv, out: $stdout, err: $stderr)
        new(out:, err:).run(argv.dup)
      end
    end

    def initialize(out:, err:)
      @out = out
      @err = err
    end

    def run(argv)
      command = argv.shift
      case command
      when "inspect"
        inspect(argv)
      when "analyze"
        analyze(argv)
      when "generate"
        generate(argv)
      when "-h", "--help"
        @out.write(ROOT_HELP)
        0
      when nil
        @err.write(ROOT_HELP)
        2
      else
        @err.puts("[CLI_USAGE] Unknown command #{command.inspect}")
        @err.write(ROOT_HELP)
        2
      end
    rescue IntegrationGenerator::Error => e
      @err.puts(e.formatted)
      e.code == "OUTPUT_EXISTS" ? 3 : 1
    rescue OptionParser::ParseError => e
      @err.puts("[CLI_USAGE] #{e.message}")
      2
    end

    private

    def inspect(argv)
      options = { format: "json" }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: integrate inspect --spec PATH [--format json|yaml]"
        opts.on("--spec PATH", "OpenAPI .yaml, .yml, or .json file") { |value| options[:spec] = value }
        opts.on("--format FORMAT", %w[json yaml], "Output format: json (default) or yaml") do |value|
          options[:format] = value
        end
        opts.on("-h", "--help", "Show this help") do
          @out.puts(opts)
          return 0
        end
      end
      parser.parse!(argv)
      raise OptionParser::InvalidOption, argv.join(" ") unless argv.empty?
      raise OptionParser::MissingArgument, "--spec" unless options[:spec]

      document = OpenAPI::Parser.parse_file(options[:spec])
      serialized = options[:format] == "yaml" ? YAML.dump(document.to_h) : JSON.pretty_generate(document.to_h)
      @out.puts(serialized)
      0
    end

    def analyze(argv)
      options = { format: "yaml" }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: integrate analyze --spec PATH [--provider SLUG] [--overrides PATH] [--format yaml|json]"
        opts.on("--spec PATH", "OpenAPI .yaml, .yml, or .json file") { |value| options[:spec] = value }
        opts.on("--provider SLUG", "Provider identifier for generated configuration") { |value| options[:provider] = value }
        opts.on("--overrides PATH", "Validated generic overrides YAML/JSON") { |value| options[:overrides] = value }
        opts.on("--format FORMAT", %w[yaml json], "Output format: yaml (default) or json") do |value|
          options[:format] = value
        end
        opts.on("-h", "--help", "Show this help") do
          @out.puts(opts)
          return 0
        end
      end
      parser.parse!(argv)
      raise OptionParser::InvalidOption, argv.join(" ") unless argv.empty?
      raise OptionParser::MissingArgument, "--spec" unless options[:spec]

      document = OpenAPI::Parser.parse_file(options[:spec])
      manifest = Analyzer::ManifestBuilder.new(document, provider_slug: options[:provider]).build
      manifest = apply_overrides(manifest, options[:overrides]) if options[:overrides]
      serialized = options[:format] == "json" ? JSON.pretty_generate(manifest.to_h) : YAML.dump(manifest.to_h)
      @out.puts(serialized)
      0
    end

    def generate(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: integrate generate (--spec PATH | --manifest PATH) --output DIR [--provider SLUG] [--overrides PATH]"
        opts.on("--spec PATH", "OpenAPI input; the CLI builds a manifest first") { |value| options[:spec] = value }
        opts.on("--manifest PATH", "Prebuilt Integration Manifest YAML/JSON") { |value| options[:manifest] = value }
        opts.on("--provider SLUG", "Provider identifier; valid only with --spec") { |value| options[:provider] = value }
        opts.on("--overrides PATH", "Validated generic overrides; valid only with --spec") { |value| options[:overrides] = value }
        opts.on("--output DIR", "New output directory; existing paths are never overwritten") { |value| options[:output] = value }
        opts.on("-h", "--help", "Show this help") do
          @out.puts(opts)
          return 0
        end
      end
      parser.parse!(argv)
      raise OptionParser::InvalidOption, argv.join(" ") unless argv.empty?
      unless options[:spec] || options[:manifest]
        raise OptionParser::MissingArgument, "--spec or --manifest"
      end
      if options[:spec] && options[:manifest]
        raise OptionParser::InvalidArgument, "--spec and --manifest are mutually exclusive"
      end
      raise OptionParser::MissingArgument, "--output" unless options[:output]
      if options[:manifest] && options[:provider]
        raise OptionParser::InvalidArgument, "--provider cannot override a prebuilt manifest"
      end
      if options[:manifest] && options[:overrides]
        raise OptionParser::InvalidArgument, "--overrides applies to inferred manifests and cannot be used with --manifest"
      end

      manifest = if options[:manifest]
                   ProviderIR::ManifestLoader.load_file(options[:manifest])
                 else
                   document = OpenAPI::Parser.parse_file(options[:spec])
                   inferred = Analyzer::ManifestBuilder.new(document, provider_slug: options[:provider]).build
                   options[:overrides] ? apply_overrides(inferred, options[:overrides]) : inferred
                 end
      artifacts = Generator::ArtifactBundle.new(manifest).render
      target = Generator::OutputWriter.new.write(artifacts, options[:output])

      @out.puts("Generated #{artifacts.length} artifacts in #{target}")
      artifacts.each_key { |name| @out.puts("- #{name}") }
      0
    end

    def apply_overrides(manifest, path)
      override_data = Overrides::Loader.load_file(path)
      Overrides::Applier.new(manifest, override_data, path: path).apply
    end
  end
end
