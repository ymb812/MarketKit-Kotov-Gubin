# frozen_string_literal: true

module IntegrationGenerator
  module Generator
    class DocumentationGenerator
      CAPABILITIES = %w[create_payout fetch_status cancel_payout webhook balance].freeze

      def initialize(manifest)
        @manifest = Support.manifest_hash(manifest)
      end

      def render
        sections = [
          title,
          source_and_servers,
          review_provenance,
          capabilities,
          authentication,
          field_mappings,
          transformations,
          status_mapping,
          errors,
          webhook,
          unsupported_operations,
          manual_steps
        ]
        "#{sections.reject(&:empty?).join("\n\n")}\n"
      end

      private

      def review_provenance
        audit = @manifest["overrides"] || { "applied" => false, "applied_changes" => [], "resolved_warnings" => [] }
        lines = ["## Review provenance", "", "### Inferred", ""]
        lines << "Semantic facts not listed under Overridden remain analyzer inferences with their manifest confidence/evidence."
        lines << ""
        lines << "### Overridden"
        lines << ""
        if audit["applied"]
          lines << "- Override version: `#{audit['override_version']}`"
          lines << "- Source: #{Support.escape_markdown(audit['source'])}"
          lines << "- Reason: #{Support.escape_markdown(audit['reason'])}"
          lines << "- File: `#{Support.escape_markdown(audit['file'])}`" if audit["file"]
          audit.fetch("applied_changes", []).each do |change|
            lines << "- `#{Support.escape_markdown(change['path'])}` — confirmed or changed by override"
          end
          lines << ""
          lines << "Resolved analyzer warnings are retained in the manifest audit:"
          audit.fetch("resolved_warnings", []).each do |entry|
            warning = entry.fetch("warning")
            lines << "- **#{warning['code']}** (`#{warning['location']}`) — #{entry['resolution']}"
          end
        else
          lines << "No overrides were applied."
        end
        lines << ""
        lines << "### Still unresolved"
        lines << ""
        if @manifest["warnings"].empty?
          lines << "No analyzer warnings remain unresolved."
        else
          @manifest["warnings"].each do |warning|
            location = warning["location"] ? " (`#{warning['location']}`)" : ""
            lines << "- **#{warning['code']}**#{location}: #{Support.escape_markdown(warning['message'])}"
          end
        end
        lines.join("\n")
      end

      def title
        name = @manifest.dig("provider", "display_name") || @manifest.dig("provider", "slug")
        <<~MARKDOWN.chomp
          # #{name} payout integration

          Generated from Integration Manifest v#{@manifest['manifest_version']}. Review every warning and configuration placeholder before production use.
        MARKDOWN
      end

      def source_and_servers
        lines = [
          "## Source and servers",
          "",
          "- OpenAPI: `#{@manifest.dig('source', 'openapi_version') || 'unknown'}`",
          "- SHA-256: `#{@manifest.dig('source', 'sha256') || 'unavailable'}`",
          "- Analyzer/ruleset: `#{@manifest.dig('analyzer', 'version')}` / `#{@manifest.dig('analyzer', 'ruleset_version')}`",
          ""
        ]
        if @manifest["servers"].empty?
          lines << "No base URL was declared. Configure it manually."
        else
          lines << "| URL | Description |"
          lines << "|---|---|"
          @manifest["servers"].each do |server|
            variables = server.fetch("variables", {}).map { |name, value| "#{name}=#{value['default']}" }.join(", ")
            description = [server["description"], variables.empty? ? nil : "variables: #{variables}"].compact.join("; ")
            lines << "| `#{Support.escape_markdown(server['url'])}` | #{Support.escape_markdown(description)} |"
          end
        end
        lines.join("\n")
      end

      def capabilities
        lines = [
          "## Capabilities",
          "",
          "| Capability | Status | Operation | Confidence |",
          "|---|---|---|---:|"
        ]
        CAPABILITIES.each do |intent|
          capability, operation = Support.capability_row(@manifest, intent)
          operation_text = operation ? "`#{operation['method']} #{Support.escape_markdown(operation['path'])}`" : "—"
          confidence = format("%.0f%%", capability.fetch("confidence", 0.0) * 100)
          lines << "| `#{intent}` | #{capability['status']} | #{operation_text} | #{confidence} |"
        end
        lines.join("\n")
      end

      def authentication
        lines = ["## Authentication and configuration", ""]
        schemes = @manifest.dig("auth", "schemes") || []
        if schemes.empty?
          lines << "No supported authentication scheme was detected."
        else
          lines << "| Scheme | Type | Placement | Credential placeholder |"
          lines << "|---|---|---|---|"
          schemes.each do |scheme|
            type = [scheme["type"], scheme["scheme"]].compact.join("/")
            placement = [scheme["location"], scheme["parameter_name"]].compact.join(": ")
            lines << "| `#{Support.escape_markdown(scheme['name'])}` | #{type} | #{Support.escape_markdown(placement)} | `ENV[\"#{scheme['config_env']}\"]` |"
          end
        end
        default = @manifest.dig("auth", "default")
        if default
          lines << ""
          suffix = default["suggested"] ? " (suggested from operation consensus)" : ""
          lines << "Default source: `#{default['source']}`#{suffix}. Generated requests still use per-operation requirements."
        end
        lines.join("\n")
      end

      def field_mappings
        lines = [
          "## Field mappings",
          "",
          "| Capability | Role | Provider target | Location | Internal source candidate | Confidence | Provenance | Review |",
          "|---|---|---|---|---|---:|---|---|"
        ]
        count = 0
        @manifest.fetch("field_mappings").each do |intent, mapping|
          mapping.fetch("request", []).each do |field|
            count += 1
            confidence = format("%.0f%%", field.fetch("confidence", 0.0) * 100)
            lines << "| `#{intent}` | `#{field['role']}` | `#{Support.escape_markdown(field['target'])}` | #{field['location'] || 'body'} | `#{field['source_candidate'] || 'unmapped'}` | #{confidence} | `#{field['provenance'] || 'inferred'}` | #{field['requires_review'] ? 'yes' : 'no'} |"
          end
        end
        return "## Field mappings\n\nNo request field mappings were inferred." if count.zero?

        lines.join("\n")
      end

      def transformations
        amount = @manifest.dig("transformations", "amount") || {}
        conditions = @manifest.dig("transformations", "conditional_requirements") || []
        lines = [
          "## Transformations and conditions",
          "",
          "Amount: provider field `#{amount['provider_field'] || 'unknown'}`, unit `#{amount['provider_unit'] || 'unknown'}`, direction `#{amount['direction'] || 'none'}`, factor `#{amount['factor'].nil? ? 'review required' : amount['factor']}`, provenance `#{amount['provenance'] || 'inferred'}`."
        ]
        unless conditions.empty?
          lines << ""
          lines << "Conditional requirements (each rule carries its own provenance/review state in the manifest):"
          conditions.each do |condition|
            required_if = condition.fetch("required_if")
            lines << "- `#{condition['field']}` when `#{required_if['field']} = #{required_if['equals']}` — `#{condition['provenance']}`, review: #{condition['requires_review'] ? 'yes' : 'no'}"
          end
        end
        lines.join("\n")
      end

      def status_mapping
        mappings = @manifest.dig("status_mapping", "mappings") || {}
        lines = ["## Status mapping", ""]
        if mappings.empty?
          lines << "No enum-backed payout status mapping was found."
        else
          lines << "| Provider status | Normalized status | Confidence | Provenance |"
          lines << "|---|---|---:|---|"
          mappings.each do |provider_status, mapping|
            confidence = format("%.0f%%", mapping.fetch("confidence", 0.0) * 100)
            lines << "| `#{Support.escape_markdown(provider_status)}` | `#{mapping['normalized']}` | #{confidence} | `#{mapping['provenance']}` |"
          end
        end
        lines << ""
        lines << "Unknown provider statuses remain `unknown` and require review."
        lines.join("\n")
      end

      def errors
        lines = ["## Error handling contract", ""]
        if @manifest["errors"].empty?
          lines << "No error responses were declared. Retry/reject/block policy must be configured manually."
          return lines.join("\n")
        end

        lines << "| Operation | HTTP | Code path(s) | Example code(s) | Headers |"
        lines << "|---|---:|---|---|---|"
        @manifest["errors"].each do |error|
          lines << "| `#{Support.escape_markdown(error['operation_key'])}` | `#{error['http_status']}` | `#{error.fetch('provider_code_paths', []).join(', ')}` | `#{error.fetch('example_provider_codes', []).join(', ')}` | `#{error.fetch('headers', []).join(', ')}` |"
        end
        lines << ""
        lines << "The manifest describes provider facts only. Operational retry/block/alert policy is not inferred from OpenAPI."
        lines.join("\n")
      end

      def webhook
        data = @manifest["webhook"]
        lines = ["## Webhook callback", ""]
        unless data["status"] == "detected"
          lines << "Webhook status: `#{data['status']}`. No callback endpoint is generated from missing or review-only evidence."
          return lines.join("\n")
        end

        signature = data.fetch("signature")
        payload = data.fetch("payload")
        lines.concat(
          [
            "- Operation: `#{data['operation_key']}`",
            "- Signature header: `#{signature['header'] || 'unknown'}`",
            "- Algorithm / encoding: `#{signature['algorithm'] || 'unknown'}` / `#{signature['encoding'] || 'unknown'}`",
            "- Signature provenance: `#{signature['provenance'] || 'inferred'}`",
            "- Secret placeholder: `ENV[\"#{@manifest.dig('provider', 'slug').upcase}_WEBHOOK_SECRET\"]`",
            "- Event/status/id paths: `#{payload['event_path'] || 'unknown'}` / `#{payload['status_path'] || 'unknown'}` / `#{payload['provider_operation_id_path'] || 'unknown'}`",
            "",
            "Cryptographic verification requires the exact raw request body, signature header and configured callback secret. If algorithm or encoding is unknown, generated code fails closed by default; `allow_unverified: true` exists only for explicit inspection/demo parsing."
          ]
        )
        lines.join("\n")
      end

      def unsupported_operations
        values = @manifest["unsupported_operations"]
        return "" if values.empty?

        (["## Unsupported/discovered operations", ""] + values.map { |key| "- `#{key}`" }).join("\n")
      end

      def manual_steps
        lines = ["## Manual configuration and TODOs", ""]
        lines << "- **HOST_CONTRACT**: provide `provider_client.call(method:, url:, headers:, query:, body:)` and the host `Provider::BaseService`/operation model."
        lines << "- **SAFE_DEFAULTS**: request mappings marked for review and incompletely configured webhook verification fail closed. Use explicit inspection flags only outside production until an override is applied."
        lines.join("\n")
      end
    end
  end
end
