# frozen_string_literal: true

require_relative "../test_helper"

class FieldMappingAnalyzerTest < Minitest::Test
  def test_minor_units_without_exact_exponent_requires_review
    operation = create_operation(amount_description: "Amount in minor units")
    capabilities = capabilities_for(SupportKey.call(operation))

    result = IntegrationGenerator::Analyzer::FieldMappingAnalyzer.new.analyze([operation], capabilities)
    amount = result.dig("transformations", "amount")

    assert_equal "minor", amount["provider_unit"]
    assert_nil amount["factor"]
    assert_equal true, amount["requires_review"]
    assert_includes result["warnings"].map { |warning| warning["code"] }, "AMOUNT_FACTOR_AMBIGUOUS"
  end

  def test_required_child_under_optional_parent_is_not_globally_required
    operation = create_operation(amount_description: "Amount in major units")
    schema = operation.dig("request_body", "content", "application/json", "schema")
    schema["properties"]["optional_details"] = {
      "kind" => "object",
      "required" => ["country"],
      "properties" => { "country" => { "kind" => "string" } }
    }

    result = analyze(operation)
    targets = result.dig("field_mappings", "create_payout", "request").map { |mapping| mapping["target"] }

    refute_includes targets, "optional_details.country"
    refute_includes result["warnings"].map { |warning| warning["location"] },
                    "#/field_mappings/create_payout/request/optional_details.country"
  end

  def test_object_amount_uses_scalar_leaf_without_duplicate_parent_mapping
    operation = create_operation(amount_description: "Amount object")
    schema = operation.dig("request_body", "content", "application/json", "schema")
    schema["properties"]["amount"] = {
      "kind" => "object",
      "required" => %w[currency value],
      "properties" => {
        "currency" => { "kind" => "string" },
        "value" => { "kind" => "integer", "description" => "Amount in minor units" }
      }
    }

    result = analyze(operation)
    mappings = result.dig("field_mappings", "create_payout", "request")

    refute mappings.any? { |mapping| mapping["target"] == "amount" }
    assert mappings.any? { |mapping| mapping["target"] == "amount.value" && mapping["role"] == "amount" }
    assert mappings.any? { |mapping| mapping["target"] == "amount.currency" && mapping["required"] }
    assert_equal "minor", result.dig("transformations", "amount", "provider_unit")
  end

  def test_does_not_infer_unsupported_per_item_array_mapping
    operation = create_operation(amount_description: "Amount in major units")
    schema = operation.dig("request_body", "content", "application/json", "schema")
    schema["properties"]["fees"] = {
      "kind" => "array",
      "items" => {
        "kind" => "object",
        "properties" => { "amount" => { "kind" => "integer" } }
      }
    }

    mappings = analyze(operation).dig("field_mappings", "create_payout", "request")

    refute mappings.any? { |mapping| mapping["target"].include?("[]") }
  end

  def test_multiple_amount_fields_are_fail_closed_until_reviewed
    operation = create_operation(amount_description: "Transfer amounts")
    schema = operation.dig("request_body", "content", "application/json", "schema")
    schema["properties"] = {
      "source_amount" => { "kind" => "number" },
      "transfer_amount" => { "kind" => "number" }
    }
    schema["required"] = []

    result = analyze(operation)
    amounts = result.dig("field_mappings", "create_payout", "request")
                    .select { |mapping| mapping["role"] == "amount" }

    assert_equal %w[source_amount transfer_amount], amounts.map { |mapping| mapping["target"] }
    assert amounts.all? { |mapping| mapping["requires_review"] }
    assert_equal true, result.dig("transformations", "amount", "requires_review")
    assert_includes result["warnings"].map { |warning| warning["code"] }, "AMBIGUOUS_AMOUNT_MAPPING"
  end

  private

  SupportKey = lambda do |operation|
    IntegrationGenerator::Analyzer::Support.operation_key(operation)
  end

  def analyze(operation)
    IntegrationGenerator::Analyzer::FieldMappingAnalyzer.new.analyze(
      [operation], capabilities_for(SupportKey.call(operation))
    )
  end

  def create_operation(amount_description:)
    {
      "method" => "POST",
      "path" => "/transfers",
      "operation_id" => "createTransfer",
      "description" => nil,
      "parameters" => [],
      "request_body" => {
        "content" => {
          "application/json" => {
            "schema" => {
              "kind" => "object",
              "required" => ["amount"],
              "properties" => {
                "amount" => { "kind" => "integer", "description" => amount_description }
              }
            }
          }
        }
      },
      "responses" => { "201" => { "headers" => {}, "content" => {} } }
    }
  end

  def capabilities_for(create_key)
    %w[create_payout fetch_status cancel_payout webhook balance].to_h do |intent|
      if intent == "create_payout"
        [intent, { "status" => "detected", "operation_key" => create_key }]
      else
        [intent, { "status" => "missing", "operation_key" => nil }]
      end
    end
  end
end
