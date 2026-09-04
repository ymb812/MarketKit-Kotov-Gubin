# frozen_string_literal: true

require_relative "../test_helper"

class RefResolverTest < Minitest::Test
  def test_resolves_chained_local_references_without_mutating_source
    document = {
      "components" => {
        "schemas" => {
          "Target" => { "type" => "string" },
          "Alias" => { "$ref" => "#/components/schemas/Target" }
        }
      },
      "schema" => { "$ref" => "#/components/schemas/Alias", "description" => "Merged sibling" }
    }
    original = Marshal.load(Marshal.dump(document))

    resolved = IntegrationGenerator::OpenAPI::RefResolver.new(document).resolve

    assert_equal "string", resolved.dig("schema", "type")
    assert_equal "Merged sibling", resolved.dig("schema", "description")
    assert_equal original, document
  end

  def test_decodes_json_pointer_tokens
    document = {
      "components" => { "schemas" => { "A/B~C" => { "type" => "integer" } } },
      "schema" => { "$ref" => "#/components/schemas/A~1B~0C" }
    }

    resolved = IntegrationGenerator::OpenAPI::RefResolver.new(document).resolve

    assert_equal "integer", resolved.dig("schema", "type")
  end

  def test_reports_missing_reference
    error = assert_raises(IntegrationGenerator::Error) do
      IntegrationGenerator::OpenAPI::RefResolver.new(
        "schema" => { "$ref" => "#/components/schemas/Missing" }
      ).resolve
    end

    assert_equal "REF_NOT_FOUND", error.code
  end

  def test_rejects_external_reference
    error = assert_raises(IntegrationGenerator::Error) do
      IntegrationGenerator::OpenAPI::RefResolver.new(
        "schema" => { "$ref" => "shared.yaml#/Thing" }
      ).resolve
    end

    assert_equal "UNSUPPORTED_REFERENCE", error.code
  end

  def test_reports_reference_cycle
    document = {
      "components" => {
        "schemas" => {
          "A" => { "$ref" => "#/components/schemas/B" },
          "B" => { "$ref" => "#/components/schemas/A" }
        }
      }
    }

    error = assert_raises(IntegrationGenerator::Error) do
      IntegrationGenerator::OpenAPI::RefResolver.new(document).resolve
    end

    assert_equal "REF_CYCLE", error.code
  end
end

