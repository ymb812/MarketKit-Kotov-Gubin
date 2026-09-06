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

module Provider
  class BaseService
    attr_reader :platform_actions

    def initialize
      @platform_actions = []
    end

    def success(payload = nil, **keywords)
      data = payload.is_a?(Hash) ? payload : {}
      { success: true }.merge(data).merge(keywords)
    end

    def failure(code, message)
      { success: false, code: code, message: message }
    end

    def approve_operation(operation_id)
      @platform_actions << { action: :approve, operation_id: operation_id }
      success
    end

    def reject_operation(operation_id, reason)
      @platform_actions << { action: :reject, operation_id: operation_id, reason: reason }
      success
    end
  end
end

module TestPaths
  ROOT = HACKGENESIS_TEST_ROOT

  def example_path(name)
    File.join(ROOT, "examples", name)
  end
end

class Minitest::Test
  include TestPaths
end
