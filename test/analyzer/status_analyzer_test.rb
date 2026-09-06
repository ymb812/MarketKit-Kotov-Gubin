# frozen_string_literal: true

require_relative "../test_helper"

class StatusAnalyzerTest < Minitest::Test
  def test_prefers_direct_status_over_nested_array_status
    operation = {
      "method" => "GET",
      "path" => "/transfers/{id}",
      "parameters" => [],
      "responses" => {
        "200" => {
          "content" => {
            "application/json" => {
              "schema" => {
                "kind" => "object",
                "properties" => {
                  "events" => {
                    "kind" => "array",
                    "items" => {
                      "kind" => "object",
                      "properties" => {
                        "status" => { "kind" => "string", "enum" => %w[event_created event_failed] }
                      }
                    }
                  },
                  "status" => { "kind" => "string", "enum" => %w[received booked failed] }
                }
              }
            }
          }
        }
      }
    }
    key = IntegrationGenerator::Analyzer::Support.operation_key(operation)
    capabilities = %w[create_payout fetch_status cancel_payout webhook balance].to_h do |intent|
      [intent, { "status" => intent == "fetch_status" ? "detected" : "missing",
                 "operation_key" => intent == "fetch_status" ? key : nil }]
    end

    result = IntegrationGenerator::Analyzer::StatusAnalyzer.new.analyze([operation], capabilities)

    assert_equal "status", result.dig("status_mapping", "selected", "path")
    assert_equal %w[received booked failed], result.dig("status_mapping", "selected", "values")
  end
end
