# frozen_string_literal: true

require_relative "../test_helper"

module Provider
  class BaseService; end unless const_defined?(:BaseService, false)
end

class GeneratedServiceContractTest < Minitest::Test
  FakeClient = Struct.new(:response, :requests) do
    def call(**request)
      requests << request
      response
    end
  end

  def setup
    remove_generated_service(:NovapayService)
    ENV["NOVAPAY_API_KEY"] = "test-api-key"
    source = canonical_artifacts.fetch("novapay_service.rb")
    eval(source, TOPLEVEL_BINDING, "generated/novapay_service.rb") # rubocop:disable Security/Eval
  end

  def teardown
    ENV.delete("NOVAPAY_API_KEY")
    ENV.delete("NOVAPAY_WEBHOOK_SECRET")
    remove_generated_service(:NovapayService)
  end

  def test_builds_and_dispatches_create_request_through_explicit_client_boundary
    remove_generated_service(:NovapayService)
    eval(canonical_artifacts(overridden: true).fetch("novapay_service.rb"), TOPLEVEL_BINDING, "generated/novapay_service.rb")
    response = {
      status: 201,
      headers: {},
      body: JSON.generate("id" => "np_1", "status" => "pending", "external_id" => "op_1")
    }
    client = FakeClient.new(response, [])
    service = Provider::NovapayService.new
    service.provider_client = client
    operation = {
      "id" => "op_1",
      "amount" => 1500,
      "payout_requisite" => {
        "sbp" => { "phone" => "79001234567", "bank_code" => "044525225" }
      }
    }

    result = service.create_payout(operation, request_method: :sbp, allow_unreviewed: true)
    request = client.requests.fetch(0)

    assert_equal :post, request[:method]
    assert_equal "https://api.sandbox.novapay.example/v1/payouts", request[:url]
    assert_equal "test-api-key", request.dig(:headers, "X-API-Key")
    assert_equal "op_1", request.dig(:headers, "Idempotency-Key")
    assert_equal 150_000, request.dig(:body, "amount")
    assert_equal "RUB", request.dig(:body, "currency")
    assert_equal "sbp", request.dig(:body, "recipient", "type")
    assert_equal "79001234567", request.dig(:body, "recipient", "phone")
    assert_equal true, result[:success]
    assert_equal "np_1", result.dig(:result, :id)
  end

  def test_fetch_status_interpolates_provider_operation_id
    client = FakeClient.new(
      { status: 200, headers: {}, body: { "id" => "np_1", "status" => "completed" } },
      []
    )
    service = Provider::NovapayService.new
    service.provider_client = client

    result = service.fetch_status({ "id" => "op_1", "provider_operation_key" => "np/1 ?" })

    assert_equal :get, client.requests.first[:method]
    assert_equal "https://api.sandbox.novapay.example/v1/payouts/np%2F1%20%3F", client.requests.first[:url]
    assert_equal true, result[:success]
    assert_empty service.platform_actions, "Unreviewed status must not change the platform operation"
  end

  def test_callback_is_mapped_but_does_not_claim_unknown_signature_encoding
    service = Provider::NovapayService.new
    payload = {
      "event" => "payout.completed",
      "payout_id" => "np_1",
      "external_id" => "op_1",
      "status" => "completed"
    }
    result = service.process_callback(payload)

    assert_equal true, result[:success]
    assert_empty service.platform_actions, "Inspection does not confirm status semantics"
    assert_raises(Provider::NovapayService::ConfigurationError) do
      service.process_verified_callback(JSON.generate(payload), headers: {})
    end
  end

  def test_confirmed_canonical_conditional_rule_requires_bank_code_for_sbp
    artifacts = canonical_artifacts(overridden: true)
    source = artifacts.fetch("novapay_service.rb")
    remove_generated_service(:NovapayService)
    eval(source, TOPLEVEL_BINDING, "generated/novapay_service.rb") # rubocop:disable Security/Eval

    service = Provider::NovapayService.new
    operation = {
      "amount" => 1500,
      "id" => "op_1",
      "payout_requisite" => { "sbp" => { "phone" => "79001234567" } }
    }

    result = service.check_conditions(operation, :sbp)

    assert_equal false, result[:success]
    assert_equal :bad_request, result[:code]
    assert_includes result[:message], "recipient.bank_code"
  end

  def test_parsed_callback_contract_does_not_claim_transport_authentication
    artifacts = canonical_artifacts(overridden: true)
    remove_generated_service(:NovapayService)
    eval(artifacts.fetch("novapay_service.rb"), TOPLEVEL_BINDING, "generated/novapay_service.rb")
    service = Provider::NovapayService.new
    payload = { "payout_id" => "np_1", "status" => "completed", "event" => "payout.failed" }

    result = service.process_callback(payload)

    assert_equal true, result[:success]
    assert_equal [{ action: :approve, operation_id: "np_1" }], service.platform_actions,
                 "The configured payload status path controls the mapping, not event"
    assert_raises(ArgumentError) { service.process_callback(JSON.generate(payload)) }
    assert_includes artifacts.fetch("INTEGRATION.md"), "process_verified_callback(raw_body, headers:)"
    fixtures = JSON.parse(artifacts.fetch("fixtures.json"))
    assert_equal "approve_operation", fixtures.dig("fixtures", "webhook", "callbacks", 0, "expected", "platform_action")
    assert_equal "parsed_json_object", fixtures.dig("fixtures", "webhook", "processing", "input")
    assert_equal "host_required", fixtures.dig("fixtures", "webhook", "processing", "authentication")
  end

  def test_overridden_service_needs_no_mapping_escape_hatch_and_verifies_hex_webhook
    source = canonical_artifacts(overridden: true).fetch("novapay_service.rb")
    remove_generated_service(:NovapayService)
    eval(source, TOPLEVEL_BINDING, "generated/novapay_service.rb") # rubocop:disable Security/Eval
    service = Provider::NovapayService.new
    operation = {
      "amount" => 1500,
      "id" => "op_1",
      "payout_requisite" => {
        "sbp" => { "phone" => "79001234567", "bank_code" => "044525225" }
      }
    }

    request = service.build_provider_request(operation, request_method: :sbp)

    assert_equal "op_1", request.dig(:headers, "Idempotency-Key")
    assert_equal 150_000, request.dig(:body, "amount")

    raw_body = JSON.generate(
      "event" => "payout.completed",
      "payout_id" => "np_1",
      "external_id" => "op_1",
      "status" => "completed"
    )
    ENV["NOVAPAY_WEBHOOK_SECRET"] = "callback-secret"
    signature = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("NOVAPAY_WEBHOOK_SECRET"), raw_body)
    result = service.process_verified_callback(
      raw_body,
      headers: { "X-NovaPay-Signature" => signature }
    )

    assert_equal true, result[:success]
    assert_equal [{ action: :approve, operation_id: "np_1" }], service.platform_actions
    assert_raises(Provider::NovapayService::ProviderError) do
      service.process_verified_callback(raw_body + " ", headers: { "X-NovaPay-Signature" => signature })
    end
    assert_raises(ArgumentError) do
      service.process_callback(raw_body, headers: { "X-NovaPay-Signature" => signature })
    end
    assert_raises(Provider::NovapayService::ProviderError) do
      service.process_callback(raw_body, headers: {}, raw_body: raw_body)
    end
    ENV.delete("NOVAPAY_WEBHOOK_SECRET")
    assert_raises(Provider::NovapayService::ConfigurationError) do
      service.process_callback(
        raw_body,
        headers: { "X-NovaPay-Signature" => signature },
        raw_body: raw_body
      )
    end
  end

  def test_card_number_uses_flat_payout_requisite_key
    remove_generated_service(:NovapayService)
    eval(canonical_artifacts(overridden: true).fetch("novapay_service.rb"), TOPLEVEL_BINDING, "generated/novapay_service.rb")
    service = Provider::NovapayService.new
    operation = {
      "id" => "op_card", "amount" => 20,
      "payout_requisite" => {
        "card_number" => "4111111111111111",
        "sbp" => { "phone" => "79001234567" }
      }
    }

    request = service.build_provider_request(operation, request_method: :card)

    assert_equal "card", request.dig(:body, "recipient", "type")
    assert_equal "4111111111111111", request.dig(:body, "recipient", "card_number")
  end

  def test_amount_limit_exceeded_is_a_platform_validation_failure
    remove_generated_service(:NovapayService)
    eval(canonical_artifacts(overridden: true).fetch("novapay_service.rb"), TOPLEVEL_BINDING, "generated/novapay_service.rb")
    service = Provider::NovapayService.new
    service.provider_client = FakeClient.new(
      { status: 422, headers: {}, body: { "error" => { "code" => "amount_limit_exceeded", "message" => "too large" } } },
      []
    )
    operation = {
      "id" => "op_limit", "amount" => 200_000,
      "payout_requisite" => { "sbp" => { "phone" => "79001234567", "bank_code" => "044525225" } }
    }

    result = service.create_request(operation, request_method: :sbp)

    assert_equal false, result[:success]
    assert_equal :unprocessable_entity, result[:code]
    assert_equal "operation.amount_limit_exceeded", result[:message]
  end

  private

  def canonical_artifacts(overridden: false)
    document = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path("provider_api.yaml"))
    manifest = IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: "novapay").build
    if overridden
      data = IntegrationGenerator::Overrides::Loader.load_file(example_path("novapay_overrides.yaml"))
      manifest = IntegrationGenerator::Overrides::Applier.new(manifest, data).apply
    end
    IntegrationGenerator::Generator::ArtifactBundle.new(manifest).render
  end

  def remove_generated_service(name)
    Provider.send(:remove_const, name) if Provider.const_defined?(name, false)
  end
end
