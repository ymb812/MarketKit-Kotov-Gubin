# frozen_string_literal: true

require "rubygems/package"
require "stringio"
require "tmpdir"
require "zlib"
require_relative "../test_helper"
require "integration_generator/web/application"

class WebApplicationTest < Minitest::Test
  def test_examples_expose_full_catalogued_sources
    app = app_for

    examples = app.examples

    assert_equal %w[canonical-payout transfer-provider withdrawal-provider], examples.map { |entry| entry.fetch("id") }
    canonical = examples.first
    assert_includes canonical.fetch("specification"), "openapi: 3.0.3"
    assert_includes canonical.fetch("overrides"), "override_version: \"1.0\""
    assert_nil examples[1].fetch("overrides")
  end

  def test_analyze_returns_inferred_and_final_manifest_for_canonical_spec
    result = app_for.analyze(input_for("provider_api.yaml", "novapay_overrides.yaml", provider: "novapay"))

    assert_equal "novapay", result.dig("manifest", "provider", "slug")
    assert_equal false, result.dig("inferred_manifest", "overrides", "applied")
    assert_equal true, result.dig("manifest", "overrides", "applied")
    assert_equal "needs_review", result.fetch("overall_status")
    assert_equal 1, result.dig("diagnostic_summary", "manual_configuration")
    assert_equal "manual_configuration", result.fetch("diagnostics").first.fetch("kind")
    assert_includes result.fetch("compatibility_report"), "# NovaPay Payout API compatibility report"
  end

  def test_generate_publishes_five_artifacts_and_matching_safe_archive
    Dir.mktmpdir("web-output") do |directory|
      app = app_for(output_root: directory)
      result = app.generate(input_for("alt_withdrawal_provider.yaml", "alt_withdrawal_overrides.json", provider: "alt_withdrawal"))

      assert_equal 5, result.fetch("artifacts").length
      assert_equal result.fetch("artifacts"), archive_entries(result.dig("archive", "base64"))
      assert_match(%r{\Aweb-[0-9a-f]{16}\z}, File.basename(result.fetch("output_directory")))
      assert File.directory?(File.join(directory, File.basename(result.fetch("output_directory"))))
      assert_includes result.fetch("artifacts").keys, "alt_withdrawal_service.rb"
      token = File.basename(result.fetch("output_directory"))
      result.fetch("artifacts").each do |name, content|
        assert_equal content, app.download(token, name)
        assert_equal "/api/download/#{token}/#{name}", result.dig("downloads", name)
      end
      assert_equal result.dig("archive", "base64").unpack1("m0"), app.download(token, result.dig("archive", "filename"))
      ["../../Gemfile", "Gemfile", "missing.rb"].each do |name|
        assert_raises(IntegrationGenerator::Error) { app.download(token, name) }
      end
      assert_raises(IntegrationGenerator::Error) { app.download("web-0000000000000000", "INTEGRATION.md") }
    end
  end

  def test_rejects_unsafe_filename_and_invalid_override_before_generation
    error = assert_raises(IntegrationGenerator::Error) do
      app_for.analyze(input_for("provider_api.yaml", nil).merge("filename" => "../provider_api.yaml"))
    end
    assert_equal "WEB_INVALID_REQUEST", error.code

    error = assert_raises(IntegrationGenerator::Error) do
      app_for.analyze(input_for("provider_api.yaml", "novapay_overrides.yaml").merge("overrides" => "[]"))
    end
    assert_equal "OVERRIDES_INVALID", error.code
  end

  def test_upload_accepts_original_organizer_and_unicode_filenames
    ["provider_api (1).yaml", "Провайдер выплат.yaml"].each do |filename|
      result = app_for.analyze(input_for("provider_api.yaml", nil).merge("filename" => filename))
      assert_equal filename, result.dig("manifest", "source", "display_path")
    end
    ["C:\\provider.yaml", "provider.txt"].each do |filename|
      error = assert_raises(IntegrationGenerator::Error) do
        app_for.analyze(input_for("provider_api.yaml", nil).merge("filename" => filename))
      end
      assert_equal "WEB_INVALID_REQUEST", error.code
    end
  end

  def test_one_of_warning_exposes_source_remediation_without_override_claim
    source = YAML.safe_load(File.read(example_path("provider_api.yaml")), aliases: false)
    source.dig("components", "schemas", "CreatePayoutRequest", "properties", "amount")["oneOf"] = [
      { "type" => "integer" }, { "type" => "string" }
    ]
    input = input_for("provider_api.yaml", nil).merge("specification" => YAML.dump(source))

    result = app_for.analyze(input)
    schema_diagnostics = result.fetch("diagnostics").select { |item| item["code"] == "UNSUPPORTED_SCHEMA_KEYWORD" }
    diagnostic = schema_diagnostics.first

    assert_equal 1, schema_diagnostics.length
    assert_equal "unsupported", diagnostic["kind"]
    assert_equal false, diagnostic["override_supported"]
    assert_equal "specification", diagnostic.dig("target", "focus")
    assert_match(%r{/oneOf\z}, diagnostic["source_location"])
  end

  private

  def app_for(output_root: File.join(Dir.tmpdir, "integration-generator-web-test-output"))
    IntegrationGenerator::Web::Application.new(root: TestPaths::ROOT, output_root: output_root)
  end

  def input_for(specification_name, override_name, provider: nil)
    {
      "specification" => File.read(example_path(specification_name), encoding: "utf-8"),
      "filename" => specification_name,
      "provider" => provider,
      "overrides" => override_name && File.read(example_path(override_name), encoding: "utf-8"),
      "override_filename" => override_name
    }
  end

  def archive_entries(encoded)
    gzip = Zlib::GzipReader.new(StringIO.new(encoded.unpack1("m0")))
    Gem::Package::TarReader.new(gzip).to_h { |entry| [entry.full_name, entry.read.force_encoding("UTF-8")] }
  ensure
    gzip&.close
  end
end
