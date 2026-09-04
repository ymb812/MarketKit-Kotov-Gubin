# frozen_string_literal: true

require_relative "../test_helper"

class OutputWriterTest < Minitest::Test
  def test_rejects_unsafe_artifact_filename_without_creating_target
    Dir.mktmpdir("integration-generator-writer") do |directory|
      target = File.join(directory, "generated")

      error = assert_raises(IntegrationGenerator::Error) do
        IntegrationGenerator::Generator::OutputWriter.new.write({ ".." => "unsafe" }, target)
      end

      assert_equal "GENERATION_INVALID", error.code
      refute File.exist?(target)
      assert_empty Dir.children(directory)
    end
  end

  def test_runs_ruby_c_before_publishing_output
    Dir.mktmpdir("integration-generator-writer") do |directory|
      target = File.join(directory, "generated")

      error = assert_raises(IntegrationGenerator::Error) do
        IntegrationGenerator::Generator::OutputWriter.new.write(
          { "broken_service.rb" => "class Broken\n" },
          target
        )
      end

      assert_equal "GENERATION_INVALID", error.code
      assert_includes error.message, "ruby -c"
      refute File.exist?(target)
      assert_empty Dir.children(directory)
    end
  end
end
