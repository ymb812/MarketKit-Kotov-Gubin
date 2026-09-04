# frozen_string_literal: true

require_relative "integration_generator/version"
require_relative "integration_generator/errors"
require_relative "integration_generator/ir/document"
require_relative "integration_generator/ir/operation"
require_relative "integration_generator/ir/schema"
require_relative "integration_generator/ir/warning"
require_relative "integration_generator/openapi/loader"
require_relative "integration_generator/openapi/document_validator"
require_relative "integration_generator/openapi/ref_resolver"
require_relative "integration_generator/openapi/schema_parser"
require_relative "integration_generator/openapi/parser"
require_relative "integration_generator/cli"

module IntegrationGenerator
end

