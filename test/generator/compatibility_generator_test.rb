# frozen_string_literal: true

require_relative "../test_helper"

class CompatibilityGeneratorTest < Minitest::Test
  def test_reports_reviewed_canonical_areas_and_remaining_secret_configuration
    inferred = manifest_for("provider_api.yaml", "novapay")
    overrides = IntegrationGenerator::Overrides::Loader.load_file(example_path("novapay_overrides.yaml"))
    final = IntegrationGenerator::Overrides::Applier.new(inferred, overrides).apply

    report = IntegrationGenerator::Generator::CompatibilityGenerator.new(final).render

    assert_includes report, "## Overall\n\n**NEEDS REVIEW**"
    assert_match(/`create_payout` \| detected \| \*\*READY\*\*/, report)
    assert_match(/## Authentication\n\n\*\*READY\*\*/, report)
    assert_match(/`create_payout` \| \*\*READY\*\* \|/, report)
    assert_match(/## Amount transformation\n\n\*\*READY\*\*/, report)
    assert_match(/## Status normalization\n\n\*\*READY\*\*/, report)
    assert_match(/## Webhook readiness\n\n\*\*NEEDS REVIEW\*\*/, report)
    assert_match(/`webhook` \| detected \| \*\*NEEDS REVIEW\*\*/, report)
    assert_includes report, "`X-NovaPay-Signature` / `hmac_sha256` / `hex`"
    assert_includes report, "CALLBACK_SECRET_NOT_DECLARED"
  end

  def test_reports_alternative_gaps_without_provider_specific_leakage
    report = IntegrationGenerator::Generator::CompatibilityGenerator.new(
      manifest_for("alt_transfer_provider.json", "alt_transfer")
    ).render

    assert_match(/`create_payout` \| detected \| \*\*READY\*\*/, report)
    assert_match(/`cancel_payout` \| missing \| \*\*UNSUPPORTED\*\*/, report)
    assert_match(/`webhook` \| missing \| \*\*UNSUPPORTED\*\*/, report)
    assert_includes report, "`BearerAuth`"
    assert_match(/## Amount transformation\n\n\*\*NEEDS REVIEW\*\*/, report)
    assert_match(/## Status normalization\n\n\*\*NEEDS REVIEW\*\*/, report)
    refute_match(/NovaPay|X-NovaPay|hmac_sha256.*hex/i, report)
  end

  def test_cancel_review_is_in_overall_and_missing_optional_capabilities_are_not_fatal
    overrides = IntegrationGenerator::Overrides::Loader.load_file(example_path("novapay_overrides.yaml"))
    manifest = IntegrationGenerator::Overrides::Applier.new(manifest_for("provider_api.yaml", "novapay"), overrides).apply.to_h
    manifest["warnings"] = []
    manifest["webhook"] = { "status" => "missing" }
    %w[webhook balance].each do |intent|
      manifest["capabilities"][intent] = { "status" => "missing", "operation_key" => nil, "confidence" => 0.0, "candidates" => [] }
    end
    assert_equal "ready", IntegrationGenerator::Generator::CompatibilityGenerator.new(manifest).overall_status
    manifest.dig("field_mappings", "cancel_payout", "request", 0)["requires_review"] = true
    generator = IntegrationGenerator::Generator::CompatibilityGenerator.new(manifest)
    assert_equal "needs_review", generator.overall_status
    assert_includes generator.render, "cancel payout mappings is needs_review"
  end

  private

  def manifest_for(file, provider)
    document = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path(file))
    IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: provider).build
  end
end
