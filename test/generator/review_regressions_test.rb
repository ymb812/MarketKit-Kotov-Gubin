# frozen_string_literal: true

require_relative "../test_helper"

module Provider
  class BaseService; end unless const_defined?(:BaseService, false)
end

class ReviewRegressionsTest < Minitest::Test
  def setup
    @raw = YAML.safe_load(File.read(example_path("provider_api.yaml")), aliases: false)
    @overrides = IntegrationGenerator::Overrides::Loader.load_file(example_path("novapay_overrides.yaml"))
    @previous_key = ENV["REVIEW_PROBE_API_KEY"]
    ENV["REVIEW_PROBE_API_KEY"] = "test-key"
  end

  def teardown
    ENV["REVIEW_PROBE_API_KEY"] = @previous_key
    Provider.send(:remove_const, :ReviewProbeService) if Provider.const_defined?(:ReviewProbeService, false)
  end

  def test_unknown_required_field_is_visible_overridable_and_preserves_false
    schema = @raw.dig("components", "schemas", "CreatePayoutRequest")
    schema["required"] << "confirmed"
    schema["properties"]["confirmed"] = { "type" => "boolean" }
    mapping = inferred.to_h.dig("field_mappings", "create_payout", "request").find { |item| item["target"] == "confirmed" }
    assert mapping["requires_review"]
    assert_nil mapping["source_candidate"]
    assert inferred.to_h["warnings"].any? { |item| item["code"] == "REQUIRED_REQUEST_BODY_MAPPING_NOT_FOUND" }
    add_override("confirmed", "operation.confirmed")
    service = generated_service

    assert_raises(ArgumentError) { service.create_request(operation) }
    request = service.create_request(operation.merge("confirmed" => false))
    assert_equal false, request.dig(:body, "confirmed")
    assert_equal false, IntegrationGenerator::Generator::Support.dig_path({ "confirmed" => false }, "confirmed")
  end

  def test_nested_required_field_is_checked_after_composite_projection
    service = generated_service
    value = operation
    value["payout_requisite"].delete("type")

    error = assert_raises(ArgumentError) { service.create_request(value) }
    assert_includes error.message, "body.recipient.type"
  end

  def test_required_nullable_field_preserves_explicit_null_but_rejects_absence
    schema = @raw.dig("components", "schemas", "CreatePayoutRequest")
    schema["properties"]["memo"] = { "type" => "string", "nullable" => true }
    schema["required"] << "memo"
    add_override("memo", "operation.memo")
    service = generated_service

    assert_raises(ArgumentError) { service.create_request(operation) }
    body = service.create_request(operation.merge("memo" => nil))[:body]
    assert body.key?("memo")
    assert_nil body["memo"]
    schema["required"].delete("memo")
    service = generated_service
    refute service.create_request(operation)[:body].key?("memo")
    assert service.create_request(operation.merge("memo" => nil))[:body].key?("memo")
  end

  def test_schema_declared_child_can_be_added_by_override
    @raw.dig("components", "schemas", "Recipient", "properties")["routing"] = { "type" => "string" }
    add_override("recipient.routing", "operation.routing")
    request = generated_service.create_request(operation.merge("routing" => "route-1"))

    assert_equal "route-1", request.dig(:body, "recipient", "routing")
  end

  def test_projection_respects_explicit_open_map_and_schema_valued_additional_properties
    recipient = @raw.dig("components", "schemas", "Recipient")
    recipient["properties"]["metadata"] = { "type" => "object", "additionalProperties" => true }
    recipient["properties"]["routes"] = {
      "type" => "object", "additionalProperties" => {
        "type" => "object", "additionalProperties" => false,
        "properties" => { "enabled" => { "type" => "boolean" } }
      }
    }
    value = operation
    value["payout_requisite"].merge!(
      "metadata" => { "dynamic" => { "kept" => false } },
      "routes" => { "first" => { "enabled" => false, "host_only" => "drop" } },
      "host_only" => "drop"
    )
    result = generated_service.create_request(value).dig(:body, "recipient")

    assert_equal({ "dynamic" => { "kept" => false } }, result["metadata"])
    assert_equal({ "first" => { "enabled" => false } }, result["routes"])
    refute result.key?("host_only")
  end

  def test_whole_array_mapping_projects_each_item_and_rejects_unknown_item_schema
    schema = @raw.dig("components", "schemas", "CreatePayoutRequest")
    schema["properties"]["items"] = {
      "type" => "array", "items" => {
        "type" => "object", "properties" => { "code" => { "type" => "string" } }, "required" => ["code"]
      }
    }
    add_override("items", "operation.items")
    value = operation.merge("items" => [{ "code" => "one", "host_only" => "drop" }])
    assert_equal [{ "code" => "one" }], generated_service.create_request(value).dig(:body, "items")
    schema["properties"]["items"].delete("items")
    service = generated_service
    assert_raises(Provider::ReviewProbeService::ConfigurationError) { service.create_request(value) }
  end

  def test_ambiguous_webhook_header_and_id_remain_unset_until_explicit_override
    webhook = @raw.dig("paths", "/webhooks/payout", "post")
    webhook["parameters"] << { "name" => "Other-Signature", "in" => "header", "schema" => { "type" => "string" } }
    # The resolver expands references first; put competing same-role paths in the canonical body schema.
    reference = webhook.dig("requestBody", "content", "application/json", "schema", "$ref")
    schema = @raw.dig("components", "schemas", reference.split("/").last)
    schema["properties"]["duplicate"] = {
      "type" => "object", "properties" => { "payout_id" => { "type" => "string" } }
    }
    manifest = inferred.to_h
    assert_nil manifest.dig("webhook", "signature", "header")
    assert_nil manifest.dig("webhook", "payload", "provider_operation_id_path")

    @overrides["webhook"]["signature"]["header"] = "X-NovaPay-Signature"
    @overrides["webhook"]["payload"] = { "provider_operation_id_path" => "payout_id" }
    manifest = final_manifest.to_h
    assert_equal "X-NovaPay-Signature", manifest.dig("webhook", "signature", "header")
    assert_equal "payout_id", manifest.dig("webhook", "payload", "provider_operation_id_path")
  end

  def test_no_security_requirements_generate_a_bundle_without_crashing
    @raw.delete("security")
    @raw["paths"].each_value do |path|
      path.each_value { |value| value.delete("security") if value.is_a?(Hash) }
    end
    artifacts = IntegrationGenerator::Generator::ArtifactBundle.new(inferred).render
    assert_equal 5, artifacts.length
    assert_includes artifacts["compatibility_report.md"], "NEEDS REVIEW"
  end

  def test_verified_callback_uses_the_signed_body
    service = generated_service
    previous = ENV["REVIEW_PROBE_WEBHOOK_SECRET"]
    ENV["REVIEW_PROBE_WEBHOOK_SECRET"] = "test-secret"
    raw = JSON.generate("payout_id" => "signed-id", "status" => "failed")
    signature = OpenSSL::HMAC.hexdigest("SHA256", "test-secret", raw)
    result = service.process_callback(
      { "payout_id" => "unsigned-id", "status" => "completed" },
      raw_body: raw, headers: { "X-NovaPay-Signature" => signature }
    )
    assert_equal "signed-id", result[:provider_operation_id]
    assert_equal :rejected, result[:status]
  ensure
    ENV["REVIEW_PROBE_WEBHOOK_SECRET"] = previous
  end

  def test_missing_or_ambiguous_webhook_mapping_blocks_runtime_even_with_valid_signature
    @overrides["webhook"]["signature"]["header"] = "X-NovaPay-Signature"
    manifest = final_manifest.to_h
    manifest["webhook"]["payload"]["provider_operation_id_path"] = nil
    source = IntegrationGenerator::Generator::ServiceGenerator.new(manifest).render
    eval(source, TOPLEVEL_BINDING, "generated/review_probe_service.rb")
    previous = ENV["REVIEW_PROBE_WEBHOOK_SECRET"]
    ENV["REVIEW_PROBE_WEBHOOK_SECRET"] = "test-secret"
    raw = JSON.generate("payout_id" => "np_1", "status" => "completed")
    signature = OpenSSL::HMAC.hexdigest("SHA256", "test-secret", raw)
    assert_raises(Provider::ReviewProbeService::ConfigurationError) do
      Provider::ReviewProbeService.new.process_callback(raw, raw_body: raw, headers: { "X-NovaPay-Signature" => signature })
    end
  ensure
    ENV["REVIEW_PROBE_WEBHOOK_SECRET"] = previous
  end

  private

  def inferred
    document = IntegrationGenerator::OpenAPI::Parser.new(@raw).parse
    IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: "review_probe").build
  end

  def final_manifest
    IntegrationGenerator::Overrides::Applier.new(inferred, @overrides).apply
  end

  def generated_service
    Provider.send(:remove_const, :ReviewProbeService) if Provider.const_defined?(:ReviewProbeService, false)
    source = IntegrationGenerator::Generator::ServiceGenerator.new(final_manifest).render
    eval(source, TOPLEVEL_BINDING, "generated/review_probe_service.rb") # rubocop:disable Security/Eval
    Provider::ReviewProbeService.new
  end

  def add_override(target, source)
    @overrides.dig("field_mappings", "create_payout", "request") << {
      "target" => target, "location" => "body", "source" => source, "confirm" => true
    }
  end

  def operation
    {
      "id" => "op-1", "idempotency_key" => "idem-1", "amount" => "15.25", "currency" => "RUB",
      "payout_requisite" => { "type" => "sbp", "phone" => "79001234567", "bank_code" => "044525225" }
    }
  end
end
