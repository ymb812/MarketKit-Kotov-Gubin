# frozen_string_literal: true

require "digest"
require "open3"
require "rbconfig"
require_relative "../test_helper"

class RealProviderExamplesTest < Minitest::Test
  FakeClient = Struct.new(:response, :requests) do
    def call(**request)
      requests << request
      response
    end
  end

  SCENARIOS = {
    "adyen_transfer_v4" => {
      spec: "adyen_transfer_v4.yaml",
      repository: "https://github.com/Adyen/adyen-openapi",
      commit: "f82d1fe674e536cc2c6b0d7946e0e827873a4fbf",
      source_path: "yaml/TransferService-v4.yaml",
      source_sha256: "4d9803371cda6c5be7ca456e201cb287e7851830ba1d96506224d0542cec59a5",
      snapshot_sha256: "fda275e9d189087ee8f50b522039c0aade75697ec131d93dda3171949800cb06",
      paths: ["/transfers", "/transfers/{id}"],
      class_name: :AdyenTransferV4Service
    },
    "airwallex_transfer" => {
      spec: "airwallex_transfer.json",
      repository: "https://github.com/airwallex/airwallex-openapi",
      commit: "a8a09eb98ccf65e4a44481f768ac58cbd6540fa5",
      source_path: "openapi/client-api/latest/airwallex-openapi-latest.json",
      source_sha256: "ee3add01d9e521467b023711f965dc5dba78ee9246f566295725e62fd13629a2",
      snapshot_sha256: "19440873342ba5437b7774d720ca0ccaa8fe9f206d81cfe9e6d5dbebbd209f7e",
      paths: [
        "/api/v1/transfers/create",
        "/api/v1/transfers/{id}",
        "/api/v1/transfers/{id}/cancel"
      ],
      class_name: :AirwallexTransferService
    }
  }.freeze

  def teardown
    SCENARIOS.each_value { |scenario| remove_service(scenario.fetch(:class_name)) }
    ENV.keys.grep(/\A(?:ADYEN_TRANSFER_V4|AIRWALLEX_TRANSFER)_/).each { |name| ENV.delete(name) }
  end

  def test_snapshots_are_pinned_to_official_provider_sources
    SCENARIOS.each do |name, expected|
      path = real_example_path(expected.fetch(:spec))
      document = IntegrationGenerator::OpenAPI::Loader.load_file(path)
      source = document.fetch("x-hackgenesis-source")

      assert_equal expected.fetch(:repository), source.fetch("repository")
      assert_equal expected.fetch(:commit), source.fetch("commit")
      assert_equal expected.fetch(:source_path), source.fetch("path")
      assert_equal expected.fetch(:source_sha256), source.fetch("source_sha256")
      assert_equal expected.fetch(:paths), source.fetch("included_paths")
      assert_equal expected.fetch(:paths), document.fetch("paths").keys
      assert_equal expected.fetch(:snapshot_sha256), Digest::SHA256.file(path).hexdigest
    end
  end

  def test_both_real_specs_generate_complete_syntax_valid_bundles
    SCENARIOS.each_key do |name|
      artifacts = artifacts_for(name)

      assert_equal [
        "INTEGRATION.md", "compatibility_report.md", "fixtures.json",
        "integration_manifest.yml", "#{name}_service.rb"
      ].sort, artifacts.keys.sort
      Tempfile.create([name, ".rb"]) do |file|
        file.write(artifacts.fetch("#{name}_service.rb"))
        file.flush
        _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-c", file.path)
        assert status.success?, stderr
      end
    end
  end

  def test_adyen_service_dispatches_request_and_applies_reviewed_status
    service_class = load_service("adyen_transfer_v4")
    auth_env = service_class::ADAPTER_CONFIG.fetch("auth").fetch("schemes")
                            .find { |scheme| scheme["name"] == "ApiKeyAuth" }.fetch("config_env")
    ENV[auth_env] = "adyen-test-key"
    client = FakeClient.new(
      { status: 200, headers: {}, body: { "id" => "TR_1", "status" => "received" } },
      []
    )
    service = service_class.new
    service.provider_client = client
    operation = {
      "id" => "host-op-1",
      "amount" => "123.45",
      "payout_requisite" => { "balanceAccountId" => "BA_1" }
    }

    result = service.create_request(operation)
    request = client.requests.fetch(0)

    assert_equal true, result[:success]
    assert_equal "TR_1", result.dig(:result, :id)
    assert_equal :post, request[:method]
    assert_equal "https://balanceplatform-api-test.adyen.com/btl/v4/transfers", request[:url]
    assert_equal "adyen-test-key", request.dig(:headers, "X-API-Key")
    assert_equal "host-op-1", request.dig(:headers, "Idempotency-Key")
    assert_equal({ "value" => 12_345, "currency" => "EUR" }, request.dig(:body, "amount"))
    assert_equal "internal", request.dig(:body, "category")
    assert_equal({ "balanceAccountId" => "BA_1" }, request.dig(:body, "counterparty"))

    client.response = { status: 200, headers: {}, body: { "id" => "TR_1", "status" => "booked" } }
    service.fetch_status({ "id" => "host-op-1", "provider_operation_key" => "TR/1" })

    assert_equal :get, client.requests.last[:method]
    assert_equal "https://balanceplatform-api-test.adyen.com/btl/v4/transfers/TR%2F1", client.requests.last[:url]
    assert_equal [{ action: :approve, operation_id: "host-op-1" }], service.platform_actions
  end

  def test_airwallex_service_dispatches_create_and_cancel_and_normalizes_error_details
    service_class = load_service("airwallex_transfer")
    auth_env = service_class::ADAPTER_CONFIG.fetch("auth").fetch("schemes").first.fetch("config_env")
    ENV[auth_env] = "airwallex-test-token"
    client = FakeClient.new(
      { status: 201, headers: {}, body: { "id" => "AWX_1", "status" => "PENDING" } },
      []
    )
    service = service_class.new
    service.provider_client = client
    operation = { "id" => "host-op-2", "amount" => "50.25", "recipient_code" => "BEN_1" }

    result = service.create_request(operation)
    request = client.requests.fetch(0)

    assert_equal true, result[:success]
    assert_equal "AWX_1", result.dig(:result, :id)
    assert_equal :post, request[:method]
    assert_equal "https://api.airwallex.com/api/v1/transfers/create", request[:url]
    assert_equal "Bearer airwallex-test-token", request.dig(:headers, "Authorization")
    assert_equal "BEN_1", request.dig(:body, "beneficiary_id")
    assert_equal "50.25", request.dig(:body, "transfer_amount")
    assert_equal "EUR", request.dig(:body, "transfer_currency")
    assert_equal "payout", request.dig(:body, "reason")
    assert_equal "host-op-2", request.dig(:body, "reference")
    assert_equal "host-op-2", request.dig(:body, "request_id")
    refute request[:body].key?("beneficiary")
    refute request[:body].key?("source_amount")

    error_response = {
      status: 400,
      headers: {},
      body: { "code" => "declaration_required", "message" => "Additional declaration is required" }
    }
    client.response = error_response
    failure = service.create_request(operation)
    normalized = service.send(:normalize_response, error_response, "create_payout")
    assert_equal :bad_request, failure[:code]
    assert_equal "declaration_required", normalized[:provider_code]
    assert_equal "Additional declaration is required", normalized[:message]

    client.response = { status: 200, headers: {}, body: { "id" => "AWX_1", "status" => "PENDING" } }
    status_result = service.fetch_status({ "id" => "host-op-2", "provider_operation_key" => "AWX/2" })
    assert_equal true, status_result[:success]
    assert_equal :get, client.requests.last[:method]
    assert_equal "https://api.airwallex.com/api/v1/transfers/AWX%2F2", client.requests.last[:url]
    assert_empty service.platform_actions

    client.response = { status: 200, headers: {}, body: {} }
    cancel = service.cancel_payout({ "id" => "host-op-2", "provider_operation_key" => "AWX/2" })
    assert_equal true, cancel[:success]
    assert_equal :post, client.requests.last[:method]
    assert_equal "https://api.airwallex.com/api/v1/transfers/AWX%2F2/cancel", client.requests.last[:url]
  end

  private

  def artifacts_for(name)
    spec = SCENARIOS.fetch(name).fetch(:spec)
    document = IntegrationGenerator::OpenAPI::Parser.parse_file(real_example_path(spec))
    inferred = IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: name).build
    overrides = IntegrationGenerator::Overrides::Loader.load_file(real_example_path("#{name}_overrides.yaml"))
    manifest = IntegrationGenerator::Overrides::Applier.new(inferred, overrides).apply
    IntegrationGenerator::Generator::ArtifactBundle.new(manifest).render
  end

  def load_service(name)
    class_name = SCENARIOS.fetch(name).fetch(:class_name)
    remove_service(class_name)
    source = artifacts_for(name).fetch("#{name}_service.rb")
    eval(source, TOPLEVEL_BINDING, "generated/#{name}_service.rb") # rubocop:disable Security/Eval
    Provider.const_get(class_name)
  end

  def remove_service(name)
    Provider.send(:remove_const, name) if Provider.const_defined?(name, false)
  end

  def real_example_path(name)
    example_path(File.join("real", name))
  end
end
