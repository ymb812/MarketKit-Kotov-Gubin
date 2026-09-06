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
          host_contract,
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
          # #{Support.escape_markdown(name)} payout integration

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
        lines << ""
        lines << "Per-operation requirements (AND within a group, OR between groups):"
        @manifest.dig("auth", "operations").each do |operation, configuration|
          groups = configuration["requirements"] || []
          description = groups.map { |group| group["schemes"].empty? ? "anonymous" : group["schemes"].join(" AND ") }.join(" OR ")
          lines << "- `#{Support.escape_markdown(operation)}`: #{Support.escape_markdown(description.empty? ? 'no authentication requirement' : description)}"
        end
        lines << "The generated client selects a supported alternative whose credentials are configured; all schemes in an AND group must be configured."
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
            source = if field.key?("constant_value")
                       "constant: #{field['constant_value'].inspect}"
                     else
                       field["source_candidate"] || "unmapped"
                     end
            lines << "| `#{intent}` | `#{field['role']}` | `#{Support.escape_markdown(field['target'])}` | #{field['location'] || 'body'} | `#{Support.escape_markdown(source)}` | #{confidence} | `#{field['provenance'] || 'inferred'}` | #{field['requires_review'] ? 'yes' : 'no'} |"
          end
        end
        return "## Field mappings\n\nNo request field mappings were inferred." if count.zero?

        lines.join("\n")
      end

      def host_contract
        <<~MARKDOWN.chomp
          ## Host service contract

          - Guaranteed operation inputs are `operation.id`, `operation.amount` and the JSONB/hash `operation.payout_requisite`. Fetch/cancel use `operation.provider_operation_key` after creation.
          - `create_request` sends the provider request, parses the response and returns `success(result: { id: provider_id })`. `create_payout` is a compatibility alias.
          - `fetch_status` and `process_callback` apply terminal states through `approve_operation` / `reject_operation`; they do not return `success(result: { status: ... })` for the platform to interpret.
          - Provider HTTP errors are converted to platform codes such as `bad_request`, `unauthorized`, `forbidden`, `unprocessable_entity`, `too_many_requests` and `internal_server_error`.
          - `request_method` is the logical gateway/payment method, not an HTTP verb. A reviewed mapping may use it for fields such as recipient type.
          - `build_provider_request` is an inspection/testing boundary that builds but does not send the outbound request.
          - The provider's `<PROVIDER>_BASE_URL` environment variable overrides the selected operation/path/root server. Server variables use their declared defaults.
          - Fetch terminal helpers receive the host `operation.id`; callback helpers receive the mapped provider id. Adapt these isolated helper calls to the production host contract.
          - Provider code/message/Retry-After are extracted internally; public `failure` returns platform code/message only. The host must arrange access to transport details for retry or diagnostics.
        MARKDOWN
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
        lines << "Default-rule or review-required mappings are proposals only: they do not trigger terminal actions until confirmed by an override."
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
        lines << "The manifest describes provider facts. Generated runtime failures use the platform's standard error symbols; provider-specific retry/block/alert policy is not inferred from OpenAPI. A provider code equal to `amount_limit_exceeded` is treated as a per-operation validation rejection (`unprocessable_entity`) for this contract."
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
            "`process_callback(payload)` accepts a parsed JSON object after the host has authenticated the notification. It maps the configured status path and calls `approve_operation(provider_id)` or `reject_operation(provider_id, reason)` for terminal states; in-progress or unknown states return plain `success`.",
            "",
            "At the HTTP boundary, call `process_verified_callback(raw_body, headers:)` to verify the exact signed bytes and then map that body. It requires the signature header and callback secret, and fails closed when configuration or verification is incomplete. Never re-serialize a parsed Hash to reconstruct signed bytes. Legacy `process_callback` calls with explicit raw_body/headers also use this verification path.",
            "",
            "The configured payload status path determines the normalized status; event text does not override it. Unknown or unconfirmed statuses do not change the platform operation. Any provider-specific event/status precedence must be reviewed explicitly."
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
        lines << "- **HOST_CONTRACT**: provide `provider_client.call(method:, url:, headers:, query:, body:)`, `success`, `failure`, `approve_operation`, `reject_operation` and the documented operation fields."
        lines << "- **UNKNOWN_REQUISITES**: when a required provider field has no confirmed host schema (for example an unfamiliar account or tax identifier), keep the generated TODO and add an explicit reviewed mapping. Do not assume `payout_requisite[provider_field_name]`."
        lines << "- **SAFE_DEFAULTS**: request mappings marked for review and incompletely configured raw-body webhook verification fail closed. The host must authenticate parsed callbacks before calling `process_callback`. Use explicit inspection flags only outside production until an override is applied."
        lines.join("\n")
      end
    end
  end
end
