# frozen_string_literal: true

require_relative "test_helper"
load File.expand_path("../bin/demo", __dir__)

class DemoTest < Minitest::Test
  def test_creates_three_complete_bundles_in_new_requested_root_and_refuses_repeat
    Dir.mktmpdir("hackgenesis-demo-test") do |directory|
      target = File.join(directory, "presentation-run")
      out = StringIO.new
      err = StringIO.new

      status = HackGenesisDemo.start(["--output", target], out:, err:)

      assert_equal 0, status
      assert_empty err.string
      assert_includes out.string, "fetch_status: requires_review -> detected"
      assert_includes out.string, "novapay: 5/5 capabilities detected; auth=api_key"
      assert_includes out.string, "alt_transfer: 2/5 capabilities detected; auth=http/bearer"
      assert_includes out.string, "alt_withdrawal: 5/5 capabilities detected; auth=http/basic"

      expected = %w[INTEGRATION.md compatibility_report.md fixtures.json integration_manifest.yml]
      %w[novapay alt_transfer alt_withdrawal].each do |provider|
        bundle = File.join(target, provider)
        service = Dir.children(bundle).find { |name| name.end_with?("_service.rb") }
        assert_equal (expected + [service]).sort, Dir.children(bundle).sort
      end

      before = Dir.glob(File.join(target, "**", "*"), File::FNM_DOTMATCH).sort
      repeat_error = StringIO.new
      repeat_status = HackGenesisDemo.start(["--output", target], out: StringIO.new, err: repeat_error)

      assert_equal 2, repeat_status
      assert_includes repeat_error.string, "[DEMO_OUTPUT_EXISTS]"
      assert_equal before, Dir.glob(File.join(target, "**", "*"), File::FNM_DOTMATCH).sort
    end
  end
end
