# frozen_string_literal: true

require_relative "../test_helper"

class SchemaParserTest < Minitest::Test
  def test_normalizes_object_array_and_constraints
    warnings = []
    schema = IntegrationGenerator::OpenAPI::SchemaParser.new(warnings).parse(
      {
        "type" => "object",
        "required" => ["values"],
        "properties" => {
          "values" => {
            "type" => "array",
            "minItems" => 1,
            "uniqueItems" => true,
            "items" => { "type" => "string", "maxLength" => 10 }
          }
        }
      },
      location: "#/schema"
    ).to_h

    assert_equal "object", schema["kind"]
    assert_equal ["values"], schema["required"]
    assert_equal "array", schema.dig("properties", "values", "kind")
    assert_equal 1, schema.dig("properties", "values", "constraints", "min_items")
    assert_equal true, schema.dig("properties", "values", "constraints", "unique_items")
    assert_equal 10, schema.dig("properties", "values", "items", "constraints", "max_length")
    assert_empty warnings
  end

  def test_exposes_unsupported_composition_as_warning
    warnings = []
    schema = IntegrationGenerator::OpenAPI::SchemaParser.new(warnings).parse(
      { "oneOf" => [{ "type" => "string" }, { "type" => "integer" }] },
      location: "#/schema"
    ).to_h

    assert_equal "unknown", schema["kind"]
    assert_equal ["oneOf"], schema["unsupported_keywords"]
    assert_equal "UNSUPPORTED_SCHEMA_KEYWORD", warnings.first.code
  end

  def test_openapi_3_1_null_union_is_nullable
    warnings = []
    schema = IntegrationGenerator::OpenAPI::SchemaParser.new(warnings).parse(
      { "type" => ["string", "null"] },
      location: "#/schema"
    ).to_h

    assert_equal "string", schema["kind"]
    assert_equal true, schema["nullable"]
    assert_empty warnings
  end

  def test_non_nullable_type_union_is_not_silently_narrowed
    warnings = []
    schema = IntegrationGenerator::OpenAPI::SchemaParser.new(warnings).parse(
      { "type" => ["string", "integer"] },
      location: "#/schema"
    ).to_h

    assert_equal "unknown", schema["kind"]
    assert_equal ["type"], schema["unsupported_keywords"]
    assert_equal "UNSUPPORTED_SCHEMA_KEYWORD", warnings.first.code
  end

  def test_null_only_type_is_preserved
    warnings = []
    schema = IntegrationGenerator::OpenAPI::SchemaParser.new(warnings).parse(
      { "type" => ["null"] },
      location: "#/schema"
    ).to_h

    assert_equal "null", schema["kind"]
    assert_empty warnings
  end

  def test_unknown_schema_keyword_is_reported
    warnings = []
    schema = IntegrationGenerator::OpenAPI::SchemaParser.new(warnings).parse(
      { "type" => "string", "const" => "fixed" },
      location: "#/schema"
    ).to_h

    assert_equal ["const"], schema["unsupported_keywords"]
    assert_equal "#/schema/const", warnings.first.location
  end
end
