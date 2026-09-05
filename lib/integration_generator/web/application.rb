# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "stringio"
require "tempfile"
require "zlib"
require "rubygems/package"

module IntegrationGenerator
  module Web
    class Application
      MAX_BODY_BYTES = 2 * 1024 * 1024
      ARTIFACT_NAMES = %w[INTEGRATION.md compatibility_report.md fixtures.json integration_manifest.yml].freeze

      def initialize(root: File.expand_path("../../..", __dir__), output_root: nil)
        @root = root
        @output_root = output_root || File.join(root, "output")
        @downloads = {}
      end

      def examples
        catalog.fetch("examples").map do |entry|
          spec_path = example_path(entry.fetch("filename"))
          override_filename = entry["override_filename"]
          entry.merge(
            "specification" => File.read(spec_path, encoding: "bom|utf-8"),
            "overrides" => override_filename ? File.read(example_path(override_filename), encoding: "bom|utf-8") : nil
          )
        end
      end

      def analyze(input)
        inferred, final = manifests(input)
        response_for(inferred, final)
      end

      def generate(input)
        inferred, final = manifests(input)
        artifacts = IntegrationGenerator::Generator::ArtifactBundle.new(final).render
        target = IntegrationGenerator::Generator::OutputWriter.new.write(artifacts, unique_output_path)
        token = File.basename(target)
        archive_name = "#{final.to_h.dig('provider', 'slug') || 'provider'}_integration.tar.gz"
        archive_bytes = archive(artifacts)
        @downloads[token] = artifacts.merge(archive_name => archive_bytes)
        download_prefix = "/api/download/#{token}/"
        response_for(inferred, final).merge(
          "artifacts" => artifacts,
          "downloads" => artifacts.keys.to_h { |name| [name, download_prefix + name] },
          "output_directory" => relative_output_path(target),
          "archive" => {
            "filename" => archive_name,
            "download_url" => download_prefix + archive_name,
            "base64" => [archive_bytes].pack("m0")
          }
        )
      end

      # Exact bytes produced by this server's generator; never a filesystem path.
      def download(token, filename)
        contents = @downloads.dig(token, filename)
        raise Error.new("WEB_NOT_FOUND", "Generated download was not found; generate the package again") unless contents

        contents
      end

      private

      def manifests(input)
        specification = require_string!(input, "specification")
        filename = safe_filename(input["filename"], default: "provider.yaml")
        loaded = load_openapi(specification, filename)
        source = { "path" => filename, "sha256" => Digest::SHA256.hexdigest(specification) }
        document = OpenAPI::Parser.new(loaded, source: source).parse
        inferred = IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: optional_string(input["provider"])).build
        overrides = optional_string(input["overrides"])
        final = overrides ? IntegrationGenerator::Overrides::Applier.new(inferred, load_overrides(overrides, safe_filename(input["override_filename"], default: "overrides.yaml"))).apply : inferred
        [inferred, final]
      end

      def response_for(inferred, final)
        final_hash = final.to_h
        compatibility = IntegrationGenerator::Generator::CompatibilityGenerator.new(final)
        {
          "manifest" => final_hash,
          "inferred_manifest" => inferred.to_h,
          "overall_status" => compatibility.overall_status,
          "compatibility_report" => compatibility.render
        }
      end

      def load_openapi(contents, filename)
        with_uploaded_file(contents, filename) { |path| IntegrationGenerator::OpenAPI::Loader.load_file(path) }
      end

      def load_overrides(contents, filename)
        with_uploaded_file(contents, filename) { |path| IntegrationGenerator::Overrides::Loader.load_file(path) }
      end

      def with_uploaded_file(contents, filename)
        extension = File.extname(filename).downcase
        Tempfile.create(["integration-generator-web-", extension]) do |file|
          file.write(contents)
          file.flush
          yield file.path
        end
      end

      def catalog
        @catalog ||= JSON.parse(File.read(File.join(@root, "examples", "web_demos.json"), encoding: "utf-8"))
      rescue JSON::ParserError => e
        raise Error.new("WEB_CATALOG_INVALID", e.message)
      end

      def example_path(filename)
        path = File.expand_path(filename, File.join(@root, "examples"))
        examples_root = File.expand_path(File.join(@root, "examples")) + File::SEPARATOR
        raise Error.new("WEB_CATALOG_INVALID", "Example filename is outside examples directory") unless path.start_with?(examples_root) && File.file?(path)

        path
      end

      def unique_output_path
        FileUtils.mkdir_p(@output_root)
        loop do
          candidate = File.join(@output_root, "web-#{SecureRandom.hex(8)}")
          return candidate unless File.exist?(candidate)
        end
      end

      def relative_output_path(path)
        path.delete_prefix(@root.tr("\\", "/")).delete_prefix(@root).sub(%r{\A[\\/]}, "").tr("\\", "/")
      end

      def archive(artifacts)
        io = StringIO.new("".b)
        Zlib::GzipWriter.wrap(io) do |gzip|
          Gem::Package::TarWriter.new(gzip) do |tar|
            artifacts.each do |name, content|
              raise Error.new("GENERATION_INVALID", "Unsafe archive filename #{name.inspect}") unless safe_artifact_name?(name)

              bytes = content.encode("UTF-8")
              tar.add_file_simple(name, 0o644, bytes.bytesize) { |entry| entry.write(bytes) }
            end
          end
        end
        io.string
      end

      def safe_artifact_name?(name)
        name.is_a?(String) && name.match?(%r{\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z}) &&
          (ARTIFACT_NAMES.include?(name) || name.end_with?("_service.rb"))
      end

      def require_string!(input, key)
        value = input[key]
        raise Error.new("WEB_INVALID_REQUEST", "#{key} must be a non-empty string", location: "#/#{key}") unless value.is_a?(String) && !value.empty?
        raise Error.new("WEB_REQUEST_TOO_LARGE", "#{key} exceeds #{MAX_BODY_BYTES} bytes", location: "#/#{key}") if value.bytesize > MAX_BODY_BYTES

        value
      end

      def optional_string(value)
        return nil if value.nil? || value == ""
        raise Error.new("WEB_INVALID_REQUEST", "Expected a string") unless value.is_a?(String)

        value
      end

      def safe_filename(value, default:)
        return default unless value.is_a?(String) && !value.empty?

        basename = File.basename(value)
        unless basename == value && basename.match?(/\A[\p{L}\p{N}][\p{L}\p{N}_. ()-]*\z/u)
          raise Error.new("WEB_INVALID_REQUEST", "Filename must be a plain name without path separators or special characters")
        end
        unless %w[.yaml .yml .json].include?(File.extname(basename).downcase)
          raise Error.new("WEB_INVALID_REQUEST", "Filename must end in .yaml, .yml or .json")
        end

        basename
      end
    end
  end
end
