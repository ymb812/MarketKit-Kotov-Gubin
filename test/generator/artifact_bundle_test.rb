# frozen_string_literal: true

require_relative "../test_helper"

class ArtifactBundleTest < Minitest::Test
  def test_renders_required_canonical_artifacts
    artifacts = bundle_for("provider_api.yaml", provider: "novapay").render

    assert_equal %w[INTEGRATION.md compatibility_report.md fixtures.json integration_manifest.yml novapay_service.rb], artifacts.keys.sort
    assert_includes artifacts["novapay_service.rb"], "class NovapayService < BaseService"
    assert_includes artifacts["novapay_service.rb"], '"path": "/payouts"'
    assert_includes artifacts["novapay_service.rb"], '"parameter_name": "X-API-Key"'
    assert_includes artifacts["INTEGRATION.md"], "## Status mapping"
    assert_includes artifacts["INTEGRATION.md"], "WEBHOOK_SIGNATURE_ENCODING_UNKNOWN"
    assert_includes artifacts["compatibility_report.md"], "# NovaPay Payout API compatibility report"

    fixtures = JSON.parse(artifacts["fixtures.json"])
    assert_equal "sbp_payout", fixtures.dig("fixtures", "create_payout", "request", "example_name")
    assert_equal "00000000-0000-4000-8000-000000000000", fixtures.dig("fixtures", "create_payout", "request", "parameters", "Idempotency-Key")
    assert_equal "schema_generated", fixtures.dig("fixtures", "create_payout", "request", "parameter_provenance", "Idempotency-Key")
    assert_equal "422", fixtures.dig("fixtures", "create_payout", "error_response", "http_status")
    assert_nil fixtures.dig("fixtures", "create_payout", "success_response", "expected", "normalized_status")
    assert_equal 2, fixtures.dig("fixtures", "webhook", "callbacks").length
    assert_equal "np_7f3a9b2c", fixtures.dig("fixtures", "fetch_status", "request", "parameters", "payout_id")
    assert_equal "openapi_example", fixtures.dig("fixtures", "fetch_status", "request", "parameter_provenance", "payout_id")
    assert_equal "schema_shape_only", fixtures.dig("fixtures", "cancel_payout", "success_response", "scenario")
    refute fixtures.dig("fixtures", "cancel_payout", "success_response", "expected").key?("normalized_status")
    assert_equal "manual_required", fixtures.dig("fixtures", "webhook", "signature", "verification")

    loaded = YAML.safe_load(artifacts["integration_manifest.yml"])
    assert_equal "1.0", loaded["manifest_version"]
    assert_equal "novapay", loaded.dig("provider", "slug")
  end

  def test_alternative_artifacts_do_not_fabricate_missing_capabilities
    artifacts = bundle_for("alt_transfer_provider.json", provider: "alt_transfer").render
    fixtures = JSON.parse(artifacts["fixtures.json"])
    unavailable = fixtures["unavailable_fixtures"].to_h { |item| [item["capability"], item["reason"]] }

    assert_includes artifacts["alt_transfer_service.rb"], '"scheme": "bearer"'
    assert_equal "MISSING_CAPABILITY", unavailable["cancel_payout"]
    assert_equal "MISSING_CAPABILITY", unavailable["webhook"]
    assert_equal "MISSING_CAPABILITY", unavailable["balance"]
    refute fixtures["fixtures"].key?("webhook")
    assert_includes artifacts["INTEGRATION.md"], "Webhook status: `missing`"
  end

  def test_artifacts_are_deterministic
    first = bundle_for("provider_api.yaml", provider: "novapay").render
    second = bundle_for("provider_api.yaml", provider: "novapay").render

    assert_equal first, second
  end

  def test_third_provider_json_override_generates_basic_base64_nested_bundle
    inferred = manifest_for("alt_withdrawal_provider.yaml", provider: "alt_withdrawal")
    overrides = IntegrationGenerator::Overrides::Loader.load_file(example_path("alt_withdrawal_overrides.json"))
    final = IntegrationGenerator::Overrides::Applier.new(inferred, overrides).apply
    artifacts = IntegrationGenerator::Generator::ArtifactBundle.new(final).render
    manifest = YAML.safe_load(artifacts.fetch("integration_manifest.yml"))
    fixtures = JSON.parse(artifacts.fetch("fixtures.json"))

    assert_equal %w[INTEGRATION.md alt_withdrawal_service.rb compatibility_report.md fixtures.json integration_manifest.yml], artifacts.keys.sort
    assert_includes artifacts["alt_withdrawal_service.rb"], '"scheme": "basic"'
    assert_includes artifacts["alt_withdrawal_service.rb"], '"encoding": "base64"'
    assert_includes artifacts["compatibility_report.md"], "`BasicAuth`"
    assert_includes artifacts["compatibility_report.md"], "`X-Callback-Signature` / `hmac_sha256` / `base64`"
    assert_equal "detected", manifest.dig("capabilities", "fetch_status", "status")
    assert manifest.fetch("capabilities").values.all? { |capability| capability["status"] == "detected" }
    assert_equal "major", manifest.dig("transformations", "amount", "provider_unit")
    assert_equal ["CALLBACK_SECRET_NOT_DECLARED"], manifest.fetch("warnings").map { |warning| warning["code"] }
    assert_equal "wd_123", fixtures.dig("fixtures", "fetch_status", "success_response", "expected", "provider_operation_id", "value")
    assert_equal "in_progress", fixtures.dig("fixtures", "fetch_status", "success_response", "expected", "normalized_status", "value")
    refute_match(/NovaPay|X-NovaPay/i, artifacts.values.join("\n"))
  end

  def test_bundle_can_be_built_from_serialized_manifest_without_openapi
    inferred = manifest_for("provider_api.yaml", provider: "novapay")
    overrides = IntegrationGenerator::Overrides::Loader.load_file(example_path("novapay_overrides.yaml"))
    manifest = IntegrationGenerator::Overrides::Applier.new(inferred, overrides).apply

    Tempfile.create(["manifest", ".yml"]) do |file|
      file.write(YAML.dump(manifest.to_h))
      file.flush

      loaded = IntegrationGenerator::ProviderIR::ManifestLoader.load_file(file.path)
      artifacts = IntegrationGenerator::OpenAPI::Parser.stub(:parse_file, ->(*) { raise "generator read OpenAPI" }) do
        IntegrationGenerator::Generator::ArtifactBundle.new(loaded).render
      end

      assert_includes artifacts.keys, "novapay_service.rb"
      assert_includes artifacts.keys, "compatibility_report.md"
      assert_equal manifest.to_h, loaded.to_h
      assert_equal "hex", loaded.to_h.dig("webhook", "signature", "encoding")
    end
  end

  private

  def manifest_for(file, provider:)
    document = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path(file))
    IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: provider).build
  end

  def bundle_for(file, provider:)
    IntegrationGenerator::Generator::ArtifactBundle.new(manifest_for(file, provider: provider))
  end
end
