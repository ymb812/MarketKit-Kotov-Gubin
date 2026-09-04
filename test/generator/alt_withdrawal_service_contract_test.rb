# frozen_string_literal: true

require_relative "../test_helper"

module Provider
  class BaseService; end unless const_defined?(:BaseService, false)
end

class AltWithdrawalServiceContractTest < Minitest::Test
  FakeClient = Struct.new(:response, :requests) do
    def call(**request)
      requests << request
      response
    end
  end

  def setup
    remove_generated_service
    ENV["ALT_WITHDRAWAL_BASIC_AUTH"] = "api-user:api-password"
    eval(artifacts.fetch("alt_withdrawal_service.rb"), TOPLEVEL_BINDING, "generated/alt_withdrawal_service.rb") # rubocop:disable Security/Eval
  end

  def teardown
    ENV.delete("ALT_WITHDRAWAL_BASIC_AUTH")
    ENV.delete("ALT_WITHDRAWAL_WEBHOOK_SECRET")
    remove_generated_service
  end

  def test_overridden_mapping_projects_host_object_to_provider_schema_and_normalizes_nested_response
    client = FakeClient.new(
      {
        status: 202,
        headers: {},
        body: {
          "data" => {
            "transaction" => { "id" => "wd_123", "state" => "NEW" },
            "reference" => "merchant_42"
          }
        }
      },
      []
    )
    service = Provider::AltWithdrawalService.new
    service.provider_client = client

    result = service.create_payout(
      {
        "amount" => "42.50",
        "currency" => "EUR",
        "idempotency_key" => "idem_1",
        "payout_requisite" => {
          "type" => "iban",
          "account" => "DE89370400440532013000",
          "internal_only" => "must-not-leak"
        }
      }
    )
    request = client.requests.fetch(0)

    assert_equal "Basic #{["api-user:api-password"].pack("m0")}", request.dig(:headers, "Authorization")
    assert_equal "idem_1", request.dig(:headers, "Idempotency-Token")
    assert_equal "42.50", request.dig(:body, "amount")
    assert_equal "EUR", request.dig(:body, "asset")
    assert_equal(
      { "type" => "iban", "iban" => "DE89370400440532013000" },
      request.dig(:body, "beneficiary")
    )
    assert_equal "wd_123", result[:provider_operation_id]
    assert_equal :in_progress, result[:status]
  end

  def test_overridden_webhook_verifies_base64_signature_and_maps_nested_payload
    service = Provider::AltWithdrawalService.new
    raw_body = JSON.generate(
      "event_type" => "withdrawal.SUCCESS",
      "data" => {
        "transaction" => { "id" => "wd_123", "state" => "SUCCESS" },
        "reference" => "merchant_42"
      }
    )
    ENV["ALT_WITHDRAWAL_WEBHOOK_SECRET"] = "callback-secret"
    digest = OpenSSL::HMAC.digest("SHA256", ENV.fetch("ALT_WITHDRAWAL_WEBHOOK_SECRET"), raw_body)
    signature = [digest].pack("m0")

    result = service.process_callback(
      raw_body,
      headers: { "X-Callback-Signature" => signature },
      raw_body: raw_body
    )

    assert_equal :verified, result[:signature_verification]
    assert_equal "withdrawal.SUCCESS", result[:event]
    assert_equal "wd_123", result[:provider_operation_id]
    assert_equal "merchant_42", result[:external_id]
    assert_equal :approved, result[:status]
  end

  def test_fetch_cancel_and_balance_dispatch_basic_authenticated_requests
    client = FakeClient.new(
      { status: 200, body: { "data" => { "transaction" => { "id" => "wd_1", "state" => "SUCCESS" } } } }, []
    )
    service = Provider::AltWithdrawalService.new
    service.provider_client = client
    assert_equal :approved, service.fetch_status({ "provider_operation_id" => "wd/1 ?" })[:status]
    assert_equal :approved, service.cancel_payout({ "provider_operation_id" => "wd/1 ?" })[:status]
    client.response = { status: 200, body: { "available_funds" => 901.25, "asset" => "EUR" } }
    assert_equal 901.25, service.fetch_balance.dig(:raw, "available_funds")

    assert_equal %i[get delete get], client.requests.map { |request| request[:method] }
    assert_equal [
      "https://api.withdrawals.example/v1/withdrawals/wd%2F1%20%3F",
      "https://api.withdrawals.example/v1/withdrawals/wd%2F1%20%3F",
      "https://api.withdrawals.example/v1/wallet/balance"
    ], client.requests.map { |request| request[:url] }
    expected = "Basic #{['api-user:api-password'].pack('m0')}"
    assert(client.requests.all? { |request| request.dig(:headers, "Authorization") == expected })
  end

  private

  def artifacts
    document = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path("alt_withdrawal_provider.yaml"))
    inferred = IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: "alt_withdrawal").build
    override = IntegrationGenerator::Overrides::Loader.load_file(example_path("alt_withdrawal_overrides.json"))
    final = IntegrationGenerator::Overrides::Applier.new(inferred, override).apply
    IntegrationGenerator::Generator::ArtifactBundle.new(final).render
  end

  def remove_generated_service
    Provider.send(:remove_const, :AltWithdrawalService) if Provider.const_defined?(:AltWithdrawalService, false)
  end
end
