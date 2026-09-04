# frozen_string_literal: true

require_relative "test_helper"

class CLITest < Minitest::Test
  def test_root_help
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(["--help"], out:, err:)

    assert_equal 0, status
    assert_includes out.string, "Usage: integrate"
    assert_empty err.string
  end

  def test_inspect_emits_parseable_json_to_stdout
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(
      ["inspect", "--spec", example_path("provider_api.yaml")],
      out:,
      err:
    )

    assert_equal 0, status
    assert_equal "3.0.3", JSON.parse(out.string)["openapi"]
    assert_empty err.string
  end

  def test_inspect_emits_yaml
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(
      ["inspect", "--spec", example_path("alt_transfer_provider.json"), "--format", "yaml"],
      out:,
      err:
    )

    assert_equal 0, status
    assert_equal "3.1.0", YAML.safe_load(out.string)["openapi"]
    assert_empty err.string
  end

  def test_missing_spec_is_a_usage_error
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(["inspect"], out:, err:)

    assert_equal 2, status
    assert_includes err.string, "[CLI_USAGE]"
    assert_empty out.string
  end

  def test_parser_error_is_written_only_to_stderr
    out = StringIO.new
    err = StringIO.new

    status = IntegrationGenerator::CLI.start(
      ["inspect", "--spec", "missing.yaml"],
      out:,
      err:
    )

    assert_equal 1, status
    assert_includes err.string, "[FILE_NOT_FOUND]"
    assert_empty out.string
  end
end
