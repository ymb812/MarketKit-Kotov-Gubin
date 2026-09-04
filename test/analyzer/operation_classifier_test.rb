# frozen_string_literal: true

require_relative "../test_helper"

class OperationClassifierTest < Minitest::Test
  def setup
    @classifier = IntegrationGenerator::Analyzer::OperationClassifier.new
    @canonical = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path("provider_api.yaml")).to_h
  end

  def test_classifies_all_canonical_operations
    expected = {
      "createPayout" => "create_payout",
      "getPayoutStatus" => "fetch_status",
      "cancelPayout" => "cancel_payout",
      "payoutWebhook" => "webhook",
      "getBalance" => "balance"
    }

    @canonical["operations"].each do |operation|
      result = @classifier.classify(operation)

      assert_equal expected.fetch(operation["operation_id"]), result["intent"]
      assert_equal "accepted", result["decision"]
      assert_operator result["confidence"], :>=, 0.8
      refute_empty result["evidence"]
    end
  end

  def test_create_without_operation_id_is_reviewable_from_structure
    operation = deep_copy(@canonical["operations"].find { |candidate| candidate["operation_id"] == "createPayout" })
    operation["operation_id"] = nil
    operation["summary"] = nil
    operation["description"] = nil

    result = @classifier.classify(operation)

    assert_equal "create_payout", result["intent"]
    assert_equal "review_recommended", result["decision"]
    assert_operator result["confidence"], :>=, 0.5
    assert_operator result["confidence"], :<, 0.8
  end

  def test_cancel_operation_is_not_misclassified_as_create
    operation = @canonical["operations"].find { |candidate| candidate["operation_id"] == "cancelPayout" }
    result = @classifier.classify(operation)

    assert_equal "cancel_payout", result["intent"]
    create_score = result["alternatives"].find { |candidate| candidate["intent"] == "create_payout" }
    assert_equal 0, create_score["score"]
  end

  def test_unrelated_operation_is_unsupported
    operation = {
      "method" => "GET",
      "path" => "/health",
      "operation_id" => "healthCheck",
      "tags" => [],
      "parameters" => [],
      "request_body" => nil,
      "responses" => { "200" => { "headers" => {}, "content" => {} } }
    }

    result = @classifier.classify(operation)

    assert_equal "unknown", result["intent"]
    assert_equal "unsupported", result["decision"]
  end

  def test_get_cancel_endpoint_is_not_accepted_as_cancel_capability
    operation = deep_copy(@canonical["operations"].find { |candidate| candidate["operation_id"] == "cancelPayout" })
    operation["method"] = "GET"

    result = @classifier.classify(operation)

    refute_equal "accepted", result["decision"]
  end

  def test_generic_event_endpoint_is_not_accepted_as_webhook
    operation = {
      "method" => "POST",
      "path" => "/events",
      "operation_id" => "createEvent",
      "tags" => ["Events"],
      "parameters" => [],
      "request_body" => {
        "content" => {
          "application/json" => {
            "schema" => {
              "kind" => "object",
              "properties" => { "event" => { "kind" => "string" } }
            }
          }
        }
      },
      "responses" => { "202" => { "headers" => {}, "content" => {} } }
    }

    result = @classifier.classify(operation)

    refute_equal "webhook", result["intent"] if result["decision"] == "accepted"
  end

  def test_create_description_may_mention_cancellation_without_zeroing_create_score
    operation = deep_copy(@canonical["operations"].find { |candidate| candidate["operation_id"] == "createPayout" })
    operation["description"] = "Creates a payout that can later be cancelled."

    result = @classifier.classify(operation)

    assert_equal "create_payout", result["intent"]
    assert_equal "accepted", result["decision"]
  end

  def test_multiple_create_operations_require_capability_review
    operations = %w[POST\ /payouts POST\ /transfers].map do |key|
      IntegrationGenerator::ProviderIR::Operation.new(
        "key" => key.tr("\\", ""),
        "intent" => "create_payout",
        "confidence" => 0.9,
        "decision" => "accepted"
      )
    end

    result = IntegrationGenerator::Analyzer::CapabilityResolver.new.resolve(operations)

    assert_equal "requires_review", result.dig("capabilities", "create_payout", "status")
    assert_nil result.dig("capabilities", "create_payout", "operation_key")
    assert_equal 2, result.dig("capabilities", "create_payout", "candidates").length
    assert_includes result["warnings"].map { |warning| warning["code"] }, "AMBIGUOUS_CAPABILITY"
  end

  private

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end
end
