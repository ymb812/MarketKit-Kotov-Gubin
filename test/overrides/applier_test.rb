# frozen_string_literal: true

require_relative "../test_helper"

class OverridesApplierTest < Minitest::Test
  def test_loader_accepts_json_override_documents
    Tempfile.create(["overrides", ".json"]) do |file|
      file.write(JSON.generate(override_document.merge("status_mapping" => { "pending" => "in_progress" })))
      file.flush

      assert_equal "1.0", IntegrationGenerator::Overrides::Loader.load_file(file.path)["override_version"]
    end
  end

  def test_applies_canonical_override_with_provenance_and_explicit_warning_resolution
    final = apply_canonical_overrides.to_h

    assert_equal true, final.dig("overrides", "applied")
    assert_equal "1.0", final.dig("overrides", "override_version")
    assert_equal "hex", final.dig("webhook", "signature", "encoding")
    assert_equal "overridden", final.dig("webhook", "signature", "provenance")
    assert_equal "overridden", final.dig("status_mapping", "mappings", "completed", "provenance")
    assert_equal false, mapping(final, "Idempotency-Key", "header")["requires_review"]
    assert_equal "operation.id", mapping(final, "Idempotency-Key", "header")["source_candidate"]
    assert_equal "request_method", mapping(final, "recipient.type", "body")["source_candidate"]
    assert_equal "RUB", mapping(final, "currency", "body")["constant_value"]
    assert final.dig("transformations", "conditional_requirements").all? { |rule| rule["provenance"] == "overridden" }

    unresolved_codes = final.fetch("warnings").map { |warning| warning["code"] }
    resolved_codes = final.dig("overrides", "resolved_warnings").map { |entry| entry.dig("warning", "code") }
    assert_equal ["CALLBACK_SECRET_NOT_DECLARED"], unresolved_codes
    assert_includes resolved_codes, "WEBHOOK_SIGNATURE_ENCODING_UNKNOWN"
    assert_includes resolved_codes, "IDEMPOTENCY_SOURCE_REQUIRES_REVIEW"
    assert_operator final.dig("overrides", "applied_changes").length, :>=, 10
  end

  def test_strict_validation_rejects_unknown_targets_keys_and_values
    cases = [
      [{ "surprise" => true }, "OVERRIDE_UNKNOWN_KEY"],
      [{ "operations" => { "POST /missing" => { "intent" => "create_payout" } } }, "OVERRIDE_UNKNOWN_OPERATION"],
      [{ "operations" => { "POST /payouts" => { "intent" => "refund" } } }, "OVERRIDE_UNKNOWN_CAPABILITY"],
      [{ "status_mapping" => { "invented" => "approved" } }, "OVERRIDE_UNKNOWN_STATUS"],
      [
        { "field_mappings" => { "create_payout" => { "request" => [{ "target" => "missing", "location" => "body", "confirm" => true }] } } },
        "OVERRIDE_UNKNOWN_FIELD"
      ],
      [{ "webhook" => { "signature" => { "encoding" => "rot13" } } }, "OVERRIDE_INVALID_VALUE"],
      [
        { "field_mappings" => { "create_payout" => { "request" => [
          { "target" => "currency", "location" => "body", "source" => "operation.currency", "value" => "RUB", "confirm" => true }
        ] } } },
        "OVERRIDE_INVALID_VALUE"
      ],
      [{ "operations" => {} }, "OVERRIDE_INVALID_VALUE"],
      [
        {
          "status_mapping" => { "pending" => "in_progress" },
          "resolve_warnings" => [
            { "code" => "STATUS_MAPPING_DEFAULT_RULES_APPLIED", "location" => "#/status_mapping/mappings" }
          ]
        },
        "OVERRIDE_INVALID_VALUE"
      ]
    ]

    cases.each do |body, expected_code|
      error = assert_raises(IntegrationGenerator::Error) do
        IntegrationGenerator::Overrides::Applier.new(canonical_manifest, override_document.merge(body)).apply
      end
      assert_equal expected_code, error.code
    end
  end

  def test_operation_intent_override_recalculates_capabilities_generically
    document = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path("alt_transfer_provider.json"))
    inferred = IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: "alt_transfer").build
    overrides = override_document.merge(
      "operations" => { "GET /transfers/{transferId}" => { "intent" => "balance" } }
    )

    final = IntegrationGenerator::Overrides::Applier.new(inferred, overrides).apply.to_h

    assert_equal "missing", final.dig("capabilities", "fetch_status", "status")
    assert_equal "detected", final.dig("capabilities", "balance", "status")
    assert_equal "GET /transfers/{transferId}", final.dig("capabilities", "balance", "operation_key")
    assert_equal "overridden", final.dig("capabilities", "balance", "provenance")
  end

  private

  def apply_canonical_overrides
    data = IntegrationGenerator::Overrides::Loader.load_file(example_path("novapay_overrides.yaml"))
    IntegrationGenerator::Overrides::Applier.new(canonical_manifest, data, path: example_path("novapay_overrides.yaml")).apply
  end

  def canonical_manifest
    document = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path("provider_api.yaml"))
    IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: "novapay").build
  end

  def override_document
    {
      "override_version" => "1.0",
      "source" => "test",
      "reason" => "test override"
    }
  end

  def mapping(manifest, target, location)
    manifest.dig("field_mappings", "create_payout", "request").find do |candidate|
      candidate["target"] == target && candidate["location"] == location
    end
  end
end
