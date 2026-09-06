# frozen_string_literal: true

require_relative "../test_helper"

module Provider
  class BaseService; end unless const_defined?(:BaseService, false)
end

class RuntimeReviewTest < Minitest::Test
  Client = Struct.new(:response, :requests) do
    def call(**request)
      requests << request
      response
    end
  end

  def setup
    @raw = YAML.safe_load(File.read(example_path("provider_api.yaml")), aliases: false)
    @overrides = IntegrationGenerator::Overrides::Loader.load_file(example_path("novapay_overrides.yaml"))
    @previous_env = ENV.to_h.select { |name, _| name.start_with?("RUNTIME_REVIEW_") }
    ENV["RUNTIME_REVIEW_API_KEY"] = "test-key"
  end

  def teardown
    ENV.keys.grep(/\ARUNTIME_REVIEW_/).each { |name| ENV.delete(name) }
    @previous_env.each { |name, value| ENV[name] = value }
    Provider.send(:remove_const, :RuntimeReviewService) if Provider.const_defined?(:RuntimeReviewService, false)
  end

  def test_http_error_selection_prefers_exact_then_range_then_default
    responses = @raw.dig("paths", "/payouts", "post", "responses")
    @raw["paths"]["/payouts"]["post"]["responses"] = {
      "default" => error_response("fallback"),
      "4XX" => error_response("client_error"),
      "402" => error_response("balance_error"),
      "201" => responses.fetch("201")
    }
    service, client = generated_service
    [[402, "balance_error"], [422, "client_error"], [500, "fallback"]].each do |http, field|
      client.response = { status: http, headers: { "retry-after" => "12" }, body: { field => { "code" => "provider-code", "message" => "detail" } } }
      result = service.send(:normalize_response, client.response, "create_payout")
      assert_equal false, result[:success]
      assert_equal http, result[:http_status]
      assert_equal "provider-code", result[:provider_code]
      assert_equal "detail", result[:message]
      assert_equal "12", result[:retry_after]
    end
  end

  def test_declared_http_errors_are_normalized_and_invalid_json_is_explicit
    service, client = generated_service
    expected_codes = {
      400 => :bad_request, 401 => :unauthorized, 402 => :unprocessable_entity,
      422 => :unprocessable_entity, 429 => :too_many_requests, 500 => :internal_server_error
    }
    expected_codes.each do |http, expected_code|
      client.response = { status: http, headers: {}, body: { "code" => "error", "message" => "detail" } }
      result = service.create_payout(operation)
      assert_equal false, result[:success]
      assert_equal expected_code, result[:code]
    end
    client.response = { status: 200, headers: {}, body: "{broken" }
    assert_raises(Provider::RuntimeReviewService::ProviderError) do
      service.fetch_status({ "id" => "op_1", "provider_operation_key" => "np_1" })
    end
  end

  def test_auth_uses_available_or_alternative
    @raw["components"]["securitySchemes"]["TokenAuth"] = { "type" => "http", "scheme" => "bearer" }
    @raw["paths"]["/payouts"]["post"]["security"] = [{ "ApiKeyAuth" => [] }, { "TokenAuth" => [] }]
    ENV.delete("RUNTIME_REVIEW_API_KEY")
    ENV["RUNTIME_REVIEW_BEARER_TOKEN"] = "token-only"
    service, = generated_service
    assert_equal "Bearer token-only", service.build_provider_request(operation)[:headers]["Authorization"]
  end

  def test_success_response_mapping_uses_actual_http_status_after_empty_response
    @raw["paths"]["/payouts"]["post"]["responses"] = {
      "204" => { "description" => "No body" },
      "201" => success_response("result", "id"),
      "202" => success_response("queued", "payout_id")
    }
    service, client = generated_service
    [[201, "result", "id"], [202, "queued", "payout_id"]].each do |http, parent, field|
      client.response = { status: http, headers: {}, body: { parent => { field => "id-#{http}", "status" => "completed" } } }
      result = service.create_payout(operation)
      assert_equal "id-#{http}", result.dig(:result, :id)
    end
    client.response = { status: 204, headers: {}, body: "" }
    result = service.create_payout(operation)
    assert_equal false, result[:success]
    assert_equal "operation.provider_response_invalid", result[:message]
  end

  def test_exact_success_schema_takes_precedence_over_range_even_when_empty
    @raw["paths"]["/payouts"]["post"]["responses"] = {
      "2XX" => success_response("fallback", "payout_id"),
      "204" => { "description" => "No body" },
      "201" => success_response("exact", "id")
    }
    service, client = generated_service
    client.response = { status: 201, headers: {}, body: { "exact" => { "id" => "correct" }, "fallback" => { "payout_id" => "wrong" } } }
    assert_equal "correct", service.create_payout(operation).dig(:result, :id)
    client.response = { status: 202, headers: {}, body: { "fallback" => { "payout_id" => "range" } } }
    assert_equal "range", service.create_payout(operation).dig(:result, :id)
    client.response = { status: 204, headers: {}, body: { "fallback" => { "payout_id" => "must-not-use" } } }
    assert_equal false, service.create_payout(operation)[:success]
  end

  def test_and_auth_uses_distinct_secrets_and_requires_both
    @raw["components"]["securitySchemes"]["PartnerKey"] = { "type" => "apiKey", "in" => "query", "name" => "partner_key" }
    @raw["paths"]["/payouts"]["post"]["security"] = [{ "ApiKeyAuth" => [], "PartnerKey" => [] }]
    service, = generated_service
    auth = Provider::RuntimeReviewService::ADAPTER_CONFIG.fetch("auth")
    schemes = auth["schemes"].to_h { |scheme| [scheme["name"], scheme] }
    first_env = schemes.fetch("ApiKeyAuth").fetch("config_env")
    second_env = schemes.fetch("PartnerKey").fetch("config_env")
    refute_equal first_env, second_env
    ENV[first_env] = "private-key"
    assert_raises(Provider::RuntimeReviewService::ConfigurationError) { service.build_provider_request(operation) }
    ENV[second_env] = "partner-key"
    request = service.build_provider_request(operation)
    assert_equal "private-key", request[:headers]["X-API-Key"]
    assert_equal "partner-key", request[:query]["partner_key"]
  end

  def test_amount_conversion_is_exact_and_reports_fractional_minor_units
    service, = generated_service
    assert_equal 101, service.build_provider_request(operation)[:body]["amount"]
    error = assert_raises(ArgumentError) { service.build_provider_request(operation.merge("amount" => "1.001")) }
    assert_includes error.message, "integral provider minor units"
    assert_raises(ArgumentError) { service.build_provider_request(operation.merge("amount" => "NaN")) }
  end

  def test_read_only_request_fields_are_not_required_or_sent
    recipient = @raw.dig("components", "schemas", "Recipient")
    recipient["properties"]["server_token"] = { "type" => "string", "readOnly" => true }
    recipient["required"] << "server_token"
    service, = generated_service
    input = operation
    input["payout_requisite"]["server_token"] = "host-internal"
    request = service.build_provider_request(input)
    refute request[:body]["recipient"].key?("server_token")
    media = @last_manifest.to_h["operations"].find { |entry| entry["key"] == "POST /payouts" }.dig("contract", "request_body", "content", "application/json")
    sample = IntegrationGenerator::Generator::Support.schema_fixture(media["schema"], direction: :request)
    refute sample.fetch("recipient").key?("server_token")
  end

  def test_scoped_status_path_requires_explicit_merchant_source
    old_path = @raw["paths"].fetch("/payouts/{payout_id}")
    status_operation = old_path.delete("get")
    status_operation["parameters"] << { "name" => "merchant_id", "in" => "path", "required" => true, "schema" => { "type" => "string" } }
    @raw["paths"]["/merchants/{merchant_id}/payouts/{payout_id}"] = { "get" => status_operation }
    service, = generated_service
    assert_raises(ArgumentError) { service.fetch_status({ "id" => "op_1", "provider_operation_key" => "np_1" }) }

    @overrides["field_mappings"]["fetch_status"] = { "request" => [
      { "target" => "merchant_id", "location" => "path", "source" => "operation.merchant_id", "confirm" => true }
    ] }
    service, client = generated_service
    client.response = { status: 200, headers: {}, body: { "id" => "np_1", "status" => "completed" } }
    service.fetch_status({ "id" => "op_1", "provider_operation_key" => "np_1", "merchant_id" => "m/2" })
    assert_equal "https://api.sandbox.novapay.example/v1/merchants/m%2F2/payouts/np_1", client.requests.last[:url]
  end

  private

  def generated_service
    Provider.send(:remove_const, :RuntimeReviewService) if Provider.const_defined?(:RuntimeReviewService, false)
    document = IntegrationGenerator::OpenAPI::Parser.new(@raw).parse
    inferred = IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: "runtime_review").build
    # Mutated response enums can omit canonical statuses; confirm only statuses actually discovered.
    overrides = Marshal.load(Marshal.dump(@overrides))
    known = inferred.to_h.dig("status_mapping", "mappings").keys
    overrides["status_mapping"].select! { |status, _| known.include?(status) }
    overrides.delete("resolve_warnings")
    manifest = IntegrationGenerator::Overrides::Applier.new(inferred, overrides).apply
    @last_manifest = manifest
    eval(IntegrationGenerator::Generator::ServiceGenerator.new(manifest).render, TOPLEVEL_BINDING, "generated/runtime_review_service.rb")
    client = Client.new({ status: 201, headers: {}, body: {} }, [])
    service = Provider::RuntimeReviewService.new
    service.provider_client = client
    [service, client]
  end

  def error_response(parent)
    { "description" => "Error", "content" => { "application/json" => { "schema" => {
      "type" => "object", "properties" => { parent => { "type" => "object", "properties" => {
        "code" => { "type" => "string" }, "message" => { "type" => "string" }
      } } }
    } } } }
  end

  def success_response(parent, id)
    { "description" => "Success", "content" => { "application/json" => { "schema" => {
      "type" => "object", "properties" => { parent => { "type" => "object", "properties" => {
        id => { "type" => "string" }, "status" => { "type" => "string", "enum" => ["completed"] }
      } } }
    } } } }
  end

  def operation
    { "id" => "op_1", "amount" => "1.01",
      "payout_requisite" => { "sbp" => { "phone" => "79001234567", "bank_code" => "044525225" } } }
  end
end
