# frozen_string_literal: true

require_relative "test_helper"

class DiagnosticRemediationTest < Minitest::Test
  def test_reviewable_warning_opens_overrides
    diagnostic = decorate("AMOUNT_UNIT_AMBIGUOUS", "#/transformations/amount")

    assert_equal "reviewable", diagnostic["kind"]
    assert_equal true, diagnostic["override_supported"]
    assert_equal "overrides", diagnostic.dig("target", "focus")
    assert_nil diagnostic["source_location"]
  end

  def test_callback_secret_is_connection_configuration
    diagnostic = decorate("CALLBACK_SECRET_NOT_DECLARED", "#/webhook/signature/secret")

    assert_equal "manual_configuration", diagnostic["kind"]
    assert_equal false, diagnostic["override_supported"]
    assert_equal "webhook", diagnostic.dig("target", "view")
  end

  def test_unsupported_one_of_points_to_source_without_offering_override
    diagnostic = decorate("UNSUPPORTED_SCHEMA_KEYWORD", "#/components/schemas/Recipient/oneOf")

    assert_equal "unsupported", diagnostic["kind"]
    assert_equal false, diagnostic["override_supported"]
    assert_equal "#/components/schemas/Recipient/oneOf", diagnostic["source_location"]
    assert_match(/override не добавит поддержку/, diagnostic["guidance"])
  end

  def test_invalid_spec_and_unknown_diagnostic_fail_safe
    invalid = IntegrationGenerator::DiagnosticRemediation.for_error("REF_NOT_FOUND", "Missing", "#/paths/x")
    unknown = decorate("FUTURE_WARNING", "#/manifest/path")

    assert_equal "invalid_spec", invalid["kind"]
    assert_equal "specification", invalid.dig("target", "focus")
    assert_equal "unsupported", unknown["kind"]
    assert_nil unknown["target"]
    assert_nil unknown["source_location"]
  end

  def test_summary_keeps_categories_separate
    diagnostics = [
      { "code" => "AMOUNT_UNIT_AMBIGUOUS" },
      { "code" => "CALLBACK_SECRET_NOT_DECLARED" },
      { "code" => "UNSUPPORTED_SCHEMA_KEYWORD" },
      { "code" => "SPEC_INVALID" }
    ]

    assert_equal(
      {
        "reviewable" => 1, "manual_configuration" => 1,
        "unsupported" => 1, "invalid_spec" => 1, "total" => 4
      },
      IntegrationGenerator::DiagnosticRemediation.summary(diagnostics)
    )
  end

  private

  def decorate(code, location)
    IntegrationGenerator::DiagnosticRemediation.decorate_one(
      "code" => code, "message" => "detail", "location" => location
    )
  end
end
