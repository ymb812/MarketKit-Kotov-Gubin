# frozen_string_literal: true

require_relative "../test_helper"

class RuntimeValidationTest < Minitest::Test
  def test_loader_reports_non_object_operation_as_manifest_invalid
    manifest = canonical_manifest
    manifest["operations"] = [nil]

    error = load_error(manifest)

    assert_equal "MANIFEST_INVALID", error.code
    assert_match(/operation 0 must be an object/, error.message)
  end

  def test_loader_reports_non_object_request_mapping_as_manifest_invalid
    manifest = canonical_manifest
    manifest.dig("field_mappings", "create_payout", "request").replace([nil])

    error = load_error(manifest)

    assert_equal "MANIFEST_INVALID", error.code
    assert_match(/field_mappings\.create_payout\.request\.0 must be a Hash/, error.message)
  end

  def test_loader_rejects_missing_per_operation_auth_instead_of_generating_an_unauthenticated_request
    manifest = canonical_manifest
    operation_key = manifest.dig("capabilities", "create_payout", "operation_key")
    manifest.dig("auth", "operations").delete(operation_key)

    error = load_error(manifest)

    assert_equal "MANIFEST_INVALID", error.code
    assert_match(/Missing operation auth entries: #{Regexp.escape(operation_key)}/, error.message)
  end

  def test_loader_rejects_operation_auth_without_requirements_key
    manifest = canonical_manifest
    operation_key = manifest.dig("capabilities", "create_payout", "operation_key")
    manifest.dig("auth", "operations", operation_key).delete("requirements")

    error = load_error(manifest)

    assert_equal "MANIFEST_INVALID", error.code
    assert_match(/auth\.operations\..*\.requirements must be present/, error.message)
  end

  def test_loader_rejects_supported_requirement_that_references_an_unknown_scheme
    manifest = canonical_manifest
    operation_key = manifest.dig("capabilities", "create_payout", "operation_key")
    requirement = manifest.dig("auth", "operations", operation_key, "requirements").first
    requirement["schemes"] = ["missing_scheme"]

    error = load_error(manifest)

    assert_equal "MANIFEST_INVALID", error.code
    assert_match(/marks unknown auth schemes as supported: missing_scheme/, error.message)
  end

  def test_loader_rejects_duplicate_auth_scheme_names
    manifest = canonical_manifest
    manifest.dig("auth", "schemes") << manifest.dig("auth", "schemes").first.dup

    error = load_error(manifest)

    assert_equal "MANIFEST_INVALID", error.code
    assert_match(/Duplicate manifest auth schemes/, error.message)
  end

  private

  def canonical_manifest
    document = IntegrationGenerator::OpenAPI::Parser.parse_file(example_path("provider_api.yaml"))
    IntegrationGenerator::Analyzer::ManifestBuilder.new(document, provider_slug: "validation_probe").build.to_h
  end

  def load_error(manifest)
    Tempfile.create(["invalid-manifest", ".yml"]) do |file|
      file.write(YAML.dump(manifest))
      file.flush
      return assert_raises(IntegrationGenerator::Error) do
        IntegrationGenerator::ProviderIR::ManifestLoader.load_file(file.path)
      end
    end
  end
end
