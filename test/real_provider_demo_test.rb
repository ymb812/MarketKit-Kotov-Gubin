# frozen_string_literal: true

require_relative "test_helper"
load File.expand_path("../bin/real_provider_demo", __dir__)

class RealProviderDemoTest < Minitest::Test
  def test_generates_and_exercises_two_official_provider_examples
    Dir.mktmpdir("hackgenesis-real-provider-demo-test") do |directory|
      target = File.join(directory, "real-provider-run")
      out = StringIO.new
      err = StringIO.new

      status = HackGenesisRealProviderDemo.start(["--output", target], out:, err:)

      assert_equal 0, status, err.string
      assert_empty err.string
      assert_includes out.string, "OFFLINE: provider endpoints are not called"
      assert_includes out.string, "adyen_transfer_v4"
      assert_includes out.string, "booked -> approve_operation"
      assert_includes out.string, "airwallex_transfer"
      assert_includes out.string, "HTTP 400 provider code/message normalized"
      assert_includes out.string, "PASS: two pinned official OpenAPI examples"
      %w[adyen_transfer_v4 airwallex_transfer].each do |name|
        assert_equal 5, Dir.children(File.join(target, name)).length
      end
    end
  end
end
