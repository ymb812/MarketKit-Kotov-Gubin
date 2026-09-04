# frozen_string_literal: true

require_relative "../test_helper"

class ManifestBuilderTest < Minitest::Test
  CANONICAL_SHA256 = "415f50ee36fb331dfab49ceed0e8ed3b0ebe16053d7e00dbabd32282f4396551"

  def test_builds_complete_canonical_manifest
    manifest = build_manifest("provider_api.yaml", provider: "novapay")

    assert_equal "1.0", manifest["manifest_version"]
    assert_equal "novapay", manifest.dig("provider", "slug")
    assert_equal "3.0.3", manifest.dig("source", "openapi_version")
    assert_equal CANONICAL_SHA256, manifest.dig("source", "sha256")
    assert_equal 5, manifest["operations"].length
    assert_equal %w[detected detected detected detected detected], manifest["capabilities"].values.map { |capability| capability["status"] }

    assert_equal "api_key", manifest.dig("auth", "schemes", 0, "type")
    assert_equal "header", manifest.dig("auth", "schemes", 0, "location")
    assert_equal "X-API-Key", manifest.dig("auth", "schemes", 0, "parameter_name")
    assert_equal "NOVAPAY_API_KEY", manifest.dig("auth", "schemes", 0, "config_env")
    assert_equal "operation_consensus", manifest.dig("auth", "default", "source")
    assert_equal true, manifest.dig("auth", "default", "suggested")

    expected_statuses = {
      "pending" => "in_progress",
      "processing" => "in_progress",
      "completed" => "approved",
      "failed" => "rejected",
      "cancelled" => "rejected"
    }
    assert_equal expected_statuses, manifest.dig("status_mapping", "mappings").transform_values { |mapping| mapping["normalized"] }
    assert_equal "fetch_status", manifest.dig("status_mapping", "selected", "intent")
    assert_equal "default_rule", manifest.dig("status_mapping", "mappings", "completed", "provenance")

    assert_equal 10, manifest["errors"].length
    rate_limit = manifest["errors"].find do |error|
      error["operation_id"] == "createPayout" && error["http_status"] == "429"
    end
    assert_includes rate_limit["headers"], "Retry-After"
    assert_includes rate_limit["schema_provider_codes"], "rate_limit_exceeded"
    assert_includes rate_limit["example_provider_codes"], "rate_limit_exceeded"
    assert_includes rate_limit["possible_provider_codes"], "rate_limit_exceeded"

    assert_equal "POST /webhooks/payout", manifest.dig("webhook", "operation_key")
    assert_equal "X-NovaPay-Signature", manifest.dig("webhook", "signature", "header")
    assert_equal "hmac_sha256", manifest.dig("webhook", "signature", "algorithm")
    assert_nil manifest.dig("webhook", "signature", "encoding")
    assert_equal "payout_id", manifest.dig("webhook", "payload", "provider_operation_id_path")
    assert_equal "approved", manifest.dig("webhook", "events", "payout.completed", "normalized_status")

    assert_equal "major_to_minor", manifest.dig("transformations", "amount", "direction")
    assert_equal 100, manifest.dig("transformations", "amount", "factor")
    idempotency = manifest.dig("field_mappings", "create_payout", "request").find do |mapping|
      mapping["role"] == "idempotency_key"
    end
    assert_equal "Idempotency-Key", idempotency["target"]
    assert_equal "header", idempotency["location"]
    assert_equal "operation.idempotency_key", idempotency["source_candidate"]
    assert_equal true, idempotency["requires_review"]
    assert_includes warning_codes(manifest), "IDEMPOTENCY_SOURCE_REQUIRES_REVIEW"
    assert_equal "payout_id", manifest.dig("field_mappings", "fetch_status", "request", 0, "target")
    assert_equal "path", manifest.dig("field_mappings", "fetch_status", "request", 0, "location")
    assert_equal "payout_id", manifest.dig("field_mappings", "cancel_payout", "request", 0, "target")
    assert_equal 2, manifest.dig("transformations", "conditional_requirements").length
    assert_includes warning_codes(manifest), "WEBHOOK_SIGNATURE_ENCODING_UNKNOWN"
    assert_includes warning_codes(manifest), "STATUS_MAPPING_DEFAULT_RULES_APPLIED"
    refute_includes warning_codes(manifest), "MISSING_CAPABILITY"
    assert_empty manifest["unsupported_operations"]
  end

  def test_builds_alternative_manifest_without_fabricated_capabilities
    manifest = build_manifest("alt_transfer_provider.json", provider: "alt_transfer")

    assert_equal "detected", manifest.dig("capabilities", "create_payout", "status")
    assert_equal "POST /transfers", manifest.dig("capabilities", "create_payout", "operation_key")
    assert_equal "detected", manifest.dig("capabilities", "fetch_status", "status")
    assert_equal "missing", manifest.dig("capabilities", "cancel_payout", "status")
    assert_equal "missing", manifest.dig("capabilities", "webhook", "status")
    assert_equal "missing", manifest.dig("capabilities", "balance", "status")

    assert_equal "bearer", manifest.dig("auth", "schemes", 0, "scheme")
    assert_equal "root", manifest.dig("auth", "default", "source")
    assert_equal "in_progress", manifest.dig("status_mapping", "mappings", "NEW", "normalized")
    assert_equal "approved", manifest.dig("status_mapping", "mappings", "SETTLED", "normalized")
    assert_equal "rejected", manifest.dig("status_mapping", "mappings", "ERROR", "normalized")

    assert_equal "4XX", manifest["errors"].first["http_status"]
    assert_empty manifest["errors"].first["possible_provider_codes"]
    assert_equal "value", manifest.dig("transformations", "amount", "provider_field")
    assert_equal true, manifest.dig("transformations", "amount", "requires_review")
    assert_includes warning_codes(manifest), "AMOUNT_UNIT_AMBIGUOUS"
    assert_equal 3, warning_codes(manifest).count("MISSING_CAPABILITY")
  end

  def test_manifest_output_is_deterministic
    first = build_manifest("provider_api.yaml", provider: "novapay")
    second = build_manifest("provider_api.yaml", provider: "novapay")

    assert_equal first, second
  end

  private

  def build_manifest(file, provider:)
    document = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path(file))
    IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: provider).build.to_h
  end

  def warning_codes(manifest)
    manifest["warnings"].map { |warning| warning["code"] }
  end
end
