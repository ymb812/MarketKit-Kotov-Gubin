# frozen_string_literal: true

require_relative "../test_helper"

class ParserTest < Minitest::Test
  def test_parses_novapay_into_generic_ir
    document = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path("provider_api.yaml"))
    ir = document.to_h

    assert_equal "3.0.3", ir["openapi"]
    assert_equal "NovaPay Payout API", ir.dig("info", "title")
    assert_equal 2, ir["servers"].length
    assert_equal 5, ir["operations"].length
    assert_equal true, ir.dig("security_schemes", "ApiKeyAuth", "supported")
    assert_equal "api_key", ir.dig("security_schemes", "ApiKeyAuth", "type")
    assert_equal "X-API-Key", ir.dig("security_schemes", "ApiKeyAuth", "name")

    create = operation(ir, "createPayout")
    assert_equal "POST", create["method"]
    assert_equal "/payouts", create["path"]
    assert_equal "Idempotency-Key", create.dig("parameters", 0, "name")
    assert_equal "integer", create.dig("request_body", "content", "application/json", "schema", "properties", "amount", "kind")
    assert_equal 100_000, create.dig("request_body", "content", "application/json", "schema", "properties", "amount", "constraints", "minimum")
    assert_equal "object", create.dig("request_body", "content", "application/json", "schema", "properties", "recipient", "kind")
    assert_equal "integer", create.dig("responses", "429", "headers", "Retry-After", "schema", "kind")

    webhook = operation(ir, "payoutWebhook")
    assert_equal [], webhook["security"]
    assert_equal "header", webhook.dig("parameters", 0, "in")
    assert_empty ir["warnings"]
    refute_includes JSON.generate(ir), '"$ref"'
    refute_includes JSON.generate(ir), '"intent"'
  end

  def test_parses_structurally_different_json_spec
    document = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path("alt_transfer_provider.json"))
    ir = document.to_h

    assert_equal "3.1.0", ir["openapi"]
    assert_nil ir.dig("info", "description")
    assert_equal [{ "BearerAuth" => [] }], ir["security"]
    assert_equal "http", ir.dig("security_schemes", "BearerAuth", "type")
    assert_equal "bearer", ir.dig("security_schemes", "BearerAuth", "scheme")
    assert_equal true, ir.dig("security_schemes", "BearerAuth", "supported")
    assert_equal "eu", ir.dig("servers", 0, "variables", "region", "default")

    create = operation(ir, "initiateTransfer")
    assert_equal "object", create.dig("request_body", "content", "application/json", "schema", "kind")
    assert_equal "object", create.dig("responses", "4XX", "content", "application/problem+json", "schema", "kind")

    fetch = operation(ir, "retrieveTransaction")
    path_parameter = fetch["parameters"].find { |parameter| parameter["name"] == "transferId" }
    query_parameter = fetch["parameters"].find { |parameter| parameter["name"] == "include" }
    assert_equal true, path_parameter["required"]
    assert_equal "array", query_parameter.dig("schema", "kind")
    assert_equal true, query_parameter.dig("schema", "constraints", "unique_items")
    assert_equal "string", fetch.dig("responses", "200", "headers", "X-Trace-ID", "schema", "kind")
    assert_empty ir["warnings"]
  end

  def test_operation_parameter_replaces_path_parameter_with_same_identity
    source = {
      "openapi" => "3.0.3",
      "info" => {},
      "paths" => {
        "/items/{id}" => {
          "parameters" => [parameter("id", "path", description: "path-level")],
          "get" => {
            "parameters" => [parameter("id", "path", description: "operation-level")],
            "responses" => { "200" => { "description" => "ok" } }
          }
        }
      }
    }

    ir = IntegrationGenerator::OpenAPI::Parser.new(source).parse.to_h

    assert_equal 1, ir.dig("operations", 0, "parameters").length
    assert_equal "operation-level", ir.dig("operations", 0, "parameters", 0, "description")
  end

  def test_unsupported_auth_and_schema_are_warnings
    source = {
      "openapi" => "3.0.3",
      "info" => {},
      "paths" => {},
      "components" => {
        "securitySchemes" => { "OAuth" => { "type" => "oauth2", "flows" => {} } },
        "schemas" => { "Choice" => { "oneOf" => [{ "type" => "string" }] } }
      }
    }

    ir = IntegrationGenerator::OpenAPI::Parser.new(source).parse.to_h

    assert_equal false, ir.dig("security_schemes", "OAuth", "supported")
    assert_equal %w[UNSUPPORTED_AUTH UNSUPPORTED_SCHEMA_KEYWORD], ir["warnings"].map { |warning| warning["code"] }
  end

  def test_callbacks_and_top_level_webhooks_are_reported_as_unsupported
    source = {
      "openapi" => "3.1.0",
      "info" => {},
      "webhooks" => { "event" => {} },
      "paths" => {
        "/items" => {
          "post" => {
            "callbacks" => { "result" => {} },
            "responses" => { "200" => { "description" => "ok" } }
          }
        }
      }
    }

    ir = IntegrationGenerator::OpenAPI::Parser.new(source).parse.to_h

    assert_equal %w[UNSUPPORTED_WEBHOOKS_KEYWORD UNSUPPORTED_CALLBACKS], ir["warnings"].map { |warning| warning["code"] }
  end

  def test_cookie_parameter_and_unknown_security_scheme_are_warnings
    source = {
      "openapi" => "3.0.3",
      "info" => {},
      "security" => [{ "MissingAuth" => [] }],
      "paths" => {
        "/items" => {
          "get" => {
            "parameters" => [
              { "name" => "session", "in" => "cookie", "schema" => { "type" => "string" } }
            ],
            "responses" => { "200" => { "description" => "ok" } }
          }
        }
      }
    }

    ir = IntegrationGenerator::OpenAPI::Parser.new(source).parse.to_h

    assert_equal %w[UNKNOWN_SECURITY_SCHEME UNSUPPORTED_PARAMETER_LOCATION], ir["warnings"].map { |warning| warning["code"] }
  end

  def test_invalid_parameter_location_is_rejected
    source = {
      "openapi" => "3.0.3",
      "info" => {},
      "paths" => {
        "/items" => {
          "post" => {
            "parameters" => [
              { "name" => "payload", "in" => "body", "schema" => { "type" => "object" } }
            ],
            "responses" => { "200" => { "description" => "ok" } }
          }
        }
      }
    }

    error = assert_raises(IntegrationGenerator::Error) do
      IntegrationGenerator::OpenAPI::Parser.new(source).parse
    end

    assert_equal "SPEC_INVALID", error.code
  end

  private

  def operation(ir, operation_id)
    ir["operations"].find { |candidate| candidate["operation_id"] == operation_id }
  end

  def parameter(name, placement, description:)
    {
      "name" => name,
      "in" => placement,
      "description" => description,
      "schema" => { "type" => "string" }
    }
  end
end
