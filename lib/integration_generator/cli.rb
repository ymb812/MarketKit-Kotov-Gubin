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

      Run 'integrate inspect --help' for command options.
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
      1
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
  end
end

