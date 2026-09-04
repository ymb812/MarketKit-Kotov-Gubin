# frozen_string_literal: true

require_relative "test_helper"

class CLITest < Minitest::Test
  def test_root_help
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(["--help"], out:, err:)

    assert_equal 0, status
    assert_includes out.string, "Usage: integrate"
    assert_empty err.string
  end

  def test_inspect_emits_parseable_json_to_stdout
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(
      ["inspect", "--spec", example_path("provider_api.yaml")],
      out:,
      err:
    )

    assert_equal 0, status
    assert_equal "3.0.3", JSON.parse(out.string)["openapi"]
    assert_empty err.string
  end

  def test_inspect_emits_yaml
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(
      ["inspect", "--spec", example_path("alt_transfer_provider.json"), "--format", "yaml"],
      out:,
      err:
    )

    assert_equal 0, status
    assert_equal "3.1.0", YAML.safe_load(out.string)["openapi"]
    assert_empty err.string
  end

  def test_missing_spec_is_a_usage_error
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(["inspect"], out:, err:)

    assert_equal 2, status
    assert_includes err.string, "[CLI_USAGE]"
    assert_empty out.string
  end

  def test_parser_error_is_written_only_to_stderr
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(
      ["inspect", "--spec", "missing.yaml"],
      out:,
      err:
    )

    assert_equal 1, status
    assert_includes err.string, "[FILE_NOT_FOUND]"
    assert_empty out.string
  end

  def test_analyze_emits_parseable_yaml_manifest
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(
      ["analyze", "--spec", example_path("provider_api.yaml"), "--provider", "novapay"],
      out:,
      err:
    )
    manifest = YAML.safe_load(out.string)

    assert_equal 0, status
    assert_equal "1.0", manifest["manifest_version"]
    assert_equal "novapay", manifest.dig("provider", "slug")
    assert_equal "detected", manifest.dig("capabilities", "webhook", "status")
    assert_empty err.string
  end

  def test_analyze_emits_json_and_derives_provider_slug
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(
      ["analyze", "--spec", example_path("alt_transfer_provider.json"), "--format", "json"],
      out:,
      err:
    )
    manifest = JSON.parse(out.string)

    assert_equal 0, status
    assert_equal "example_transfer_api", manifest.dig("provider", "slug")
    assert_equal "detected", manifest.dig("capabilities", "create_payout", "status")
    assert_equal "missing", manifest.dig("capabilities", "webhook", "status")
    assert_equal false, manifest.dig("overrides", "applied")
    assert_empty err.string
  end

  def test_analyze_applies_canonical_overrides_and_emits_final_manifest
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(
      [
        "analyze", "--spec", example_path("provider_api.yaml"), "--provider", "novapay",
        "--overrides", example_path("novapay_overrides.yaml")
      ],
      out:,
      err:
    )
    manifest = YAML.safe_load(out.string)

    assert_equal 0, status
    assert_equal true, manifest.dig("overrides", "applied")
    assert_equal "hex", manifest.dig("webhook", "signature", "encoding")
    assert_equal ["CALLBACK_SECRET_NOT_DECLARED"], manifest.fetch("warnings").map { |warning| warning["code"] }
    assert_empty err.string
  end

  def test_analyze_reports_subject_specific_override_error
    Tempfile.create(["invalid-overrides", ".yaml"]) do |file|
      file.write(YAML.dump(
        "override_version" => "1.0",
        "source" => "test",
        "reason" => "exercise strict validation",
        "operations" => { "POST /does-not-exist" => { "intent" => "create_payout" } }
      ))
      file.flush
      out = StringIO.new
      err = StringIO.new

      status = IntegrationGenerator::CLI.start(
        ["analyze", "--spec", example_path("provider_api.yaml"), "--overrides", file.path],
        out:,
        err:
      )

      assert_equal 1, status
      assert_includes err.string, "[OVERRIDE_UNKNOWN_OPERATION]"
      assert_includes err.string, "POST /does-not-exist"
      assert_empty out.string
    end
  end

  def test_generate_writes_validated_artifacts_and_refuses_overwrite
    Dir.mktmpdir("integration-generator-cli") do |directory|
      target = File.join(directory, "novapay")
      out = StringIO.new
      err = StringIO.new

      status = IntegrationGenerator::CLI.start(
        ["generate", "--spec", example_path("provider_api.yaml"), "--provider", "novapay", "--output", target],
        out:,
        err:
      )

      assert_equal 0, status
      assert_equal %w[INTEGRATION.md compatibility_report.md fixtures.json integration_manifest.yml novapay_service.rb], Dir.children(target).sort
      assert_includes out.string, "Generated 5 artifacts"
      assert_empty err.string
      before = Dir.children(target).to_h { |name| [name, File.binread(File.join(target, name))] }

      second_out = StringIO.new
      second_err = StringIO.new
      second_status = IntegrationGenerator::CLI.start(
        ["generate", "--spec", example_path("provider_api.yaml"), "--provider", "novapay", "--output", target],
        out: second_out,
        err: second_err
      )

      assert_equal 3, second_status
      assert_empty second_out.string
      assert_includes second_err.string, "[OUTPUT_EXISTS]"
      assert_equal before, Dir.children(target).to_h { |name| [name, File.binread(File.join(target, name))] }
    end
  end

  def test_generate_accepts_prebuilt_manifest
    Dir.mktmpdir("integration-generator-manifest-cli") do |directory|
      document = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path("alt_transfer_provider.json"))
      manifest = IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: "alt_transfer").build
      manifest_path = File.join(directory, "manifest.yml")
      File.write(manifest_path, YAML.dump(manifest.to_h))
      target = File.join(directory, "generated")
      out = StringIO.new
      err = StringIO.new

      status = IntegrationGenerator::CLI.start(
        ["generate", "--manifest", manifest_path, "--output", target],
        out:,
        err:
      )

      assert_equal 0, status
      assert File.file?(File.join(target, "alt_transfer_service.rb"))
      assert_equal "alt_transfer", YAML.safe_load(File.read(File.join(target, "integration_manifest.yml"))).dig("provider", "slug")
      assert_empty err.string
    end
  end

  def test_generate_with_overrides_persists_exact_final_manifest
    Dir.mktmpdir("integration-generator-overrides-cli") do |directory|
      target = File.join(directory, "novapay")
      out = StringIO.new
      err = StringIO.new

      status = IntegrationGenerator::CLI.start(
        [
          "generate", "--spec", example_path("provider_api.yaml"), "--provider", "novapay",
          "--overrides", example_path("novapay_overrides.yaml"), "--output", target
        ],
        out:,
        err:
      )
      final_manifest = YAML.safe_load(File.read(File.join(target, "integration_manifest.yml")))

      assert_equal 0, status
      assert_equal true, final_manifest.dig("overrides", "applied")
      assert_equal "hex", final_manifest.dig("webhook", "signature", "encoding")
      assert File.file?(File.join(target, "novapay_service.rb"))
      assert File.file?(File.join(target, "compatibility_report.md"))
      assert_empty err.string
    end
  end

  def test_generate_requires_exactly_one_input
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(
      ["generate", "--spec", "one.yaml", "--manifest", "two.yml", "--output", "result"],
      out:,
      err:
    )

    assert_equal 2, status
    assert_includes err.string, "mutually exclusive"
    assert_empty out.string
  end
end
