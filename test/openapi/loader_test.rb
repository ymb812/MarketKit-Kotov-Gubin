# frozen_string_literal: true

require_relative "../test_helper"

class LoaderTest < Minitest::Test
  def test_loads_yaml_and_supports_safe_aliases
    with_file(".yaml", <<~YAML) do |path|
      shared: &shared
        type: string
      schema:
        <<: *shared
    YAML
      document = IntegrationGenerator::OpenAPI::Loader.load_file(path)

      assert_equal({ "type" => "string" }, document["schema"])
    end
  end

  def test_loads_json
    with_file(".json", '{"openapi":"3.1.0","paths":{}}') do |path|
      document = IntegrationGenerator::OpenAPI::Loader.load_file(path)

      assert_equal "3.1.0", document["openapi"]
    end
  end

  def test_rejects_unsafe_yaml_tags
    with_file(".yaml", "--- !ruby/object:Object {}\n") do |path|
      error = assert_raises(IntegrationGenerator::Error) do
        IntegrationGenerator::OpenAPI::Loader.load_file(path)
      end

      assert_equal "PARSE_ERROR", error.code
    end
  end

  def test_reports_malformed_yaml
    with_file(".yaml", "openapi: [unterminated\n") do |path|
      error = assert_raises(IntegrationGenerator::Error) do
        IntegrationGenerator::OpenAPI::Loader.load_file(path)
      end

      assert_equal "PARSE_ERROR", error.code
    end
  end

  def test_rejects_cyclic_yaml_aliases
    with_file(".yaml", "root: &root\n  - *root\n") do |path|
      error = assert_raises(IntegrationGenerator::Error) do
        IntegrationGenerator::OpenAPI::Loader.load_file(path)
      end

      assert_equal "PARSE_ERROR", error.code
      assert_includes error.message, "Cyclic YAML aliases"
    end
  end

  def test_reports_missing_file
    error = assert_raises(IntegrationGenerator::Error) do
      IntegrationGenerator::OpenAPI::Loader.load_file("definitely-missing.yaml")
    end

    assert_equal "FILE_NOT_FOUND", error.code
  end

  def test_rejects_unknown_extension
    with_file(".txt", "openapi: 3.0.3\n") do |path|
      error = assert_raises(IntegrationGenerator::Error) do
        IntegrationGenerator::OpenAPI::Loader.load_file(path)
      end

      assert_equal "UNSUPPORTED_FORMAT", error.code
    end
  end

  private

  def with_file(extension, content)
    Tempfile.create(["openapi", extension]) do |file|
      file.write(content)
      file.flush
      yield file.path
    end
  end
end
