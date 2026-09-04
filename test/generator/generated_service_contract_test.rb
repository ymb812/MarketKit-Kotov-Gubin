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
    remove_generated_service(:NovapayService)
  end

  def test_builds_and_dispatches_create_request_through_explicit_client_boundary
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
      "idempotency_key" => "op_1",
      "amount" => 1500,
      "currency" => "RUB",
      "payout_requisite" => {
        "type" => "sbp",
        "phone" => "79001234567",
        "bank_code" => "044525225"
      }
    }

    result = service.create_payout(operation, request_method: :sbp, allow_unreviewed: true)
    request = client.requests.fetch(0)

    assert_equal :post, request[:method]
    assert_equal "https://api.sandbox.novapay.example/v1/payouts", request[:url]
    assert_equal "test-api-key", request.dig(:headers, "X-API-Key")
    assert_equal "op_1", request.dig(:headers, "Idempotency-Key")
    assert_equal 150_000, request.dig(:body, "amount")
    assert_equal "79001234567", request.dig(:body, "recipient", "phone")
    assert_equal true, result[:success]
    assert_equal "np_1", result[:provider_operation_id]
    assert_equal :in_progress, result[:status]
  end

  def test_fetch_status_interpolates_provider_operation_id
    client = FakeClient.new(
      { status: 200, headers: {}, body: { "id" => "np_1", "status" => "completed" } },
      []
    )
    service = Provider::NovapayService.new
    service.provider_client = client

    result = service.fetch_status({ "provider_operation_id" => "np/1 ?" })

    assert_equal :get, client.requests.first[:method]
    assert_equal "https://api.sandbox.novapay.example/v1/payouts/np%2F1%20%3F", client.requests.first[:url]
    assert_equal :approved, result[:status]
  end

  def test_callback_is_mapped_but_does_not_claim_unknown_signature_encoding
    service = Provider::NovapayService.new
    payload = {
      "event" => "payout.completed",
      "payout_id" => "np_1",
      "external_id" => "op_1",
      "status" => "completed"
    }
    assert_raises(Provider::NovapayService::ConfigurationError) { service.process_callback(payload) }

    result = service.process_callback(payload, allow_unverified: true)

    assert_equal "np_1", result[:provider_operation_id]
    assert_equal :approved, result[:status]
    assert_equal :manual_required, result[:signature_verification]
  end

  private

  def canonical_artifacts
    document = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path("provider_api.yaml"))
    manifest = IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: "novapay").build
    IntegrationGenerator::Generator::ArtifactBundle.new(manifest).render
  end

  def remove_generated_service(name)
    Provider.send(:remove_const, name) if Provider.const_defined?(name, false)
  end
end
