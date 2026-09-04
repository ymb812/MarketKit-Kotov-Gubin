# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "json"
require "minitest/autorun"
require "stringio"
require "tempfile"
require "yaml"
require "integration_generator"

module TestPaths
  ROOT = File.expand_path("..", __dir__)

  def example_path(name)
    File.join(ROOT, "examples", name)
  end
end

class Minitest::Test
  include TestPaths
end

