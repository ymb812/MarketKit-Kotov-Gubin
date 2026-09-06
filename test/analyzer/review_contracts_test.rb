# frozen_string_literal: true

require_relative "../test_helper"

class AnalyzerReviewContractsTest < Minitest::Test
  def test_scoped_resource_path_maps_only_the_payout_identifier
    operation = operation_with(
      parameters: [path_parameter("merchant_id"), path_parameter("payout_id")]
    )

    result = field_analyzer(operation, "fetch_status")
    mappings = result.dig("field_mappings", "fetch_status", "request")

    assert_equal %w[payout_id merchant_id], mappings.map { |mapping| mapping["target"] }
    assert_equal false, mappings.first["requires_review"]
    assert_nil mappings.last["source_candidate"]
    assert_equal true, mappings.last["requires_review"]
    assert_includes result["warnings"].map { |warning| warning["code"] }, "REQUEST_PARAMETER_MAPPING_NOT_FOUND"
    refute_includes result["warnings"].map { |warning| warning["code"] },
                    "AMBIGUOUS_PROVIDER_OPERATION_ID_MAPPING"
  end

  def test_multiple_payout_identifiers_are_not_silently_marked_ready
    operation = operation_with(
      parameters: [path_parameter("payout_id"), path_parameter("transfer_id")]
    )

    result = field_analyzer(operation, "fetch_status")
    mappings = result.dig("field_mappings", "fetch_status", "request")

    assert mappings.all? { |mapping| mapping["requires_review"] }
    assert mappings.all? { |mapping| mapping["confidence"] < 0.8 }
    assert_includes result["warnings"].map { |warning| warning["code"] },
                    "AMBIGUOUS_PROVIDER_OPERATION_ID_MAPPING"
  end

  def test_request_and_response_mappings_respect_read_only_and_write_only
    operation = operation_with(
      method: "POST",
      path: "/payouts",
      parameters: [],
      request_schema: object_schema(
        {
          "id" => { "kind" => "string", "read_only" => true },
          "amount" => { "kind" => "integer", "description" => "cents" }
        },
        required: %w[id amount]
      ),
      responses: {
        "201" => response_with(
          object_schema(
            {
              "id" => { "kind" => "string", "write_only" => true },
              "external_id" => { "kind" => "string" },
              "status" => { "kind" => "string", "write_only" => true, "enum" => ["completed"] }
            }
          )
        )
      }
    )

    result = field_analyzer(operation, "create_payout")

    assert_equal ["amount"], result.dig("field_mappings", "create_payout", "request").map { |item| item["target"] }
    assert_equal ["external_id"], result.dig("field_mappings", "create_payout", "response").map { |item| item["source"] }
    refute_includes result["warnings"].map { |warning| warning["code"] },
                    "REQUIRED_REQUEST_BODY_MAPPING_NOT_FOUND"
  end

  def test_statuses_come_only_from_success_responses_including_2xx_ranges
    operation = operation_with(
      responses: {
        "200" => response_with(status_schema("completed")),
        "2XX" => response_with(status_schema("pending")),
        "400" => response_with(status_schema("error"))
      }
    )

    result = IntegrationGenerator::Analyzer::StatusAnalyzer.new.analyze(
      [operation], capabilities_for("fetch_status", operation)
    )

    assert_equal %w[completed pending], result.dig("status_mapping", "mappings").keys
    refute_includes result.dig("status_mapping", "mappings").keys, "error"
  end

  def test_response_mappings_cover_each_exact_and_range_success_response
    operation = operation_with(
      method: "POST",
      path: "/payouts",
      request_schema: object_schema({ "amount" => { "kind" => "integer", "description" => "cents" } }),
      responses: {
        "204" => { "headers" => {}, "content" => {} },
        "201" => response_with(object_schema({ "id" => { "kind" => "string" } })),
        "2XX" => response_with(object_schema({ "payout_id" => { "kind" => "string" } }))
      }
    )

    mappings = field_analyzer(operation, "create_payout").dig("field_mappings", "create_payout", "response")

    assert_equal [["201", "id"], ["2XX", "payout_id"]],
                 mappings.map { |mapping| [mapping["http_status"], mapping["source"]] }
  end

  def test_response_mapping_prefers_direct_resource_fields_and_ignores_boolean_status
    operation = operation_with(
      method: "POST",
      path: "/transfers",
      request_schema: object_schema({ "amount" => { "kind" => "integer", "description" => "cents" } }),
      responses: {
        "201" => response_with(
          object_schema(
            {
              "account" => object_schema({ "id" => { "kind" => "string" } }),
              "id" => { "kind" => "string" },
              "status" => { "kind" => "string", "enum" => %w[received booked] },
              "metadata" => object_schema({ "state" => { "kind" => "string" } })
            }
          )
        ),
        "202" => response_with(object_schema({ "status" => { "kind" => "boolean" } }))
      }
    )

    mappings = field_analyzer(operation, "create_payout").dig("field_mappings", "create_payout", "response")

    assert_equal [["201", "id", "provider_operation_id"], ["201", "status", "status"]],
                 mappings.map { |mapping| [mapping["http_status"], mapping["source"], mapping["role"]] }
  end

  def test_code_path_parameter_maps_to_provider_operation_key
    operation = operation_with(parameters: [path_parameter("code")])

    mapping = field_analyzer(operation, "fetch_status").dig("field_mappings", "fetch_status", "request", 0)

    assert_equal "operation.provider_operation_key", mapping["source_candidate"]
    assert_equal false, mapping["requires_review"]
  end

  def test_colliding_auth_types_receive_distinct_env_names
    schemes = {
      "ClientKey" => auth_scheme("header", "X-Client-Key"),
      "PartnerKey" => auth_scheme("query", "partner_key")
    }
    operation = operation_with(
      security: [{ "ClientKey" => [], "PartnerKey" => [] }]
    )
    document = { "security_schemes" => schemes, "security" => nil }

    auth = IntegrationGenerator::Analyzer::AuthAnalyzer.new("dual_key").analyze(document, [operation])["auth"]
    envs = auth["schemes"].to_h { |scheme| [scheme["name"], scheme["config_env"]] }

    assert_equal "DUAL_KEY_CLIENT_KEY_API_KEY", envs["ClientKey"]
    assert_equal "DUAL_KEY_PARTNER_KEY_API_KEY", envs["PartnerKey"]
    refute_equal envs["ClientKey"], envs["PartnerKey"]

    single = IntegrationGenerator::Analyzer::AuthAnalyzer.new("single").analyze(
      { "security_schemes" => { "ApiKey" => auth_scheme("header", "X-Key") }, "security" => [{ "ApiKey" => [] }] },
      [operation_with(security: nil)]
    )
    assert_equal "SINGLE_API_KEY", single.dig("auth", "schemes", 0, "config_env")
  end

  private

  def field_analyzer(operation, intent)
    IntegrationGenerator::Analyzer::FieldMappingAnalyzer.new.analyze(
      [operation], capabilities_for(intent, operation)
    )
  end

  def capabilities_for(intent, operation)
    key = IntegrationGenerator::Analyzer::Support.operation_key(operation)
    %w[create_payout fetch_status cancel_payout webhook balance].to_h do |candidate|
      if candidate == intent
        [candidate, { "status" => "detected", "operation_key" => key }]
      else
        [candidate, { "status" => "missing", "operation_key" => nil }]
      end
    end
  end

  def operation_with(method: "GET", path: "/payouts/{payout_id}", parameters: [path_parameter("payout_id")],
                     request_schema: nil, responses: nil, security: nil)
    {
      "method" => method,
      "path" => path,
      "operation_id" => nil,
      "description" => nil,
      "parameters" => parameters,
      "request_body" => request_schema && { "content" => { "application/json" => { "schema" => request_schema } } },
      "responses" => responses || { "200" => response_with(status_schema("completed")) },
      "security" => security
    }
  end

  def path_parameter(name)
    { "name" => name, "in" => "path", "required" => true, "schema" => { "kind" => "string" } }
  end

  def object_schema(properties, required: [])
    { "kind" => "object", "properties" => properties, "required" => required }
  end

  def status_schema(value)
    object_schema({ "status" => { "kind" => "string", "enum" => [value] } })
  end

  def response_with(schema)
    { "headers" => {}, "content" => { "application/json" => { "schema" => schema } } }
  end

  def auth_scheme(location, parameter_name)
    {
      "type" => "api_key",
      "scheme" => nil,
      "in" => location,
      "name" => parameter_name,
      "bearer_format" => nil,
      "supported" => true
    }
  end
end
