# frozen_string_literal: true

require_relative "../test_helper"

class DocumentValidatorTest < Minitest::Test
  def test_accepts_openapi_3_0_and_3_1
    %w[3.0.0 3.0.3 3.1.0].each do |version|
      document = { "openapi" => version, "info" => {}, "paths" => {} }

      assert_same document, IntegrationGenerator::OpenAPI::DocumentValidator.validate!(document)
    end
  end

  def test_rejects_swagger_2
    error = assert_raises(IntegrationGenerator::Error) do
      IntegrationGenerator::OpenAPI::DocumentValidator.validate!(
        "openapi" => "2.0",
        "info" => {},
        "paths" => {}
      )
    end

    assert_equal "UNSUPPORTED_OPENAPI_VERSION", error.code
  end

  def test_requires_mapping_root_info_and_paths
    [
      nil,
      [],
      { "openapi" => "3.0.3", "info" => [], "paths" => {} },
      { "openapi" => "3.0.3", "info" => {}, "paths" => [] }
    ].each do |document|
      error = assert_raises(IntegrationGenerator::Error) do
        IntegrationGenerator::OpenAPI::DocumentValidator.validate!(document)
      end

      assert_equal "SPEC_INVALID", error.code
    end
  end

  def test_optional_components_must_be_a_mapping
    error = assert_raises(IntegrationGenerator::Error) do
      IntegrationGenerator::OpenAPI::DocumentValidator.validate!(
        "openapi" => "3.0.3",
        "info" => {},
        "paths" => {},
        "components" => []
      )
    end

    assert_equal "SPEC_INVALID", error.code
  end
end
