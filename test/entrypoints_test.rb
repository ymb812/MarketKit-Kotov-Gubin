# frozen_string_literal: true

unless defined?(TestPaths)
  test_helper = File.join(Dir.pwd, "test", "test_helper.rb")
  test_helper = File.expand_path("test_helper.rb", __dir__) unless File.file?(test_helper)
  unless $LOADED_FEATURES.include?(test_helper)
    load test_helper
    $LOADED_FEATURES << test_helper
  end
end
require "open3"
require "rbconfig"

class EntrypointsTest < Minitest::Test
  def test_integrate_help_loads_from_its_own_location
    stdout, stderr, status = run_entrypoint("integrate", "--help")

    assert status.success?, stderr
    assert_includes stdout, "Usage: integrate"
    assert_empty stderr
  end

  def test_demo_help_loads_from_its_own_location
    stdout, stderr, status = run_entrypoint("demo", "--help")

    assert status.success?, stderr
    assert_includes stdout, "Usage: bundle exec ruby bin/demo"
    assert_empty stderr
  end

  def test_serve_validates_port_after_loading_from_its_own_location
    stdout, stderr, status = run_entrypoint("serve", "--port", "0")

    refute status.success?
    assert_empty stdout
    assert_includes stderr, "Port must be between 1 and 65535"
  end

  def test_integrate_prefers_its_script_root_when_called_elsewhere
    script_root = File.expand_path("..", __dir__)
    unless script_root.ascii_only? && File.file?(File.join(script_root, "lib", "integration_generator.rb"))
      skip "Ruby cannot resolve this script root outside a Unicode working directory"
    end

    Dir.mktmpdir("hackgenesis-entrypoint") do |directory|
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        File.join(ROOT, "bin", "integrate"),
        "--help",
        chdir: directory
      )

      assert status.success?, stderr
      assert_includes stdout, "Usage: integrate"
      assert_empty stderr
    end
  end

  private

  def run_entrypoint(name, *arguments)
    Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin", name), *arguments, chdir: ROOT)
  end
end
