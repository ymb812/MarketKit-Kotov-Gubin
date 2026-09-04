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

  private

  SupportKey = lambda do |operation|
    IntegrationGenerator::Analyzer::Support.operation_key(operation)
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
