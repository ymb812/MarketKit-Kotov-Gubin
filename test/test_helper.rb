# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "stringio"
require "tempfile"
require "yaml"
HACKGENESIS_TEST_ROOT = File.expand_path("..", __dir__) unless defined?(HACKGENESIS_TEST_ROOT)
HACKGENESIS_TEST_ROOT = Dir.pwd unless File.file?(File.join(HACKGENESIS_TEST_ROOT, "lib", "integration_generator.rb"))
$LOAD_PATH.unshift(File.join(HACKGENESIS_TEST_ROOT, "lib"))

require "integration_generator"

module TestPaths
  ROOT = HACKGENESIS_TEST_ROOT

  def example_path(name)
    File.join(ROOT, "examples", name)
  end
end

class Minitest::Test
  include TestPaths
end
