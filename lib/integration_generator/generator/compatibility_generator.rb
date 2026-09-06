# frozen_string_literal: true

module IntegrationGenerator
  module Generator
    class CompatibilityGenerator
      CAPABILITIES = %w[create_payout fetch_status cancel_payout webhook balance].freeze
      OUTBOUND_CAPABILITIES = %w[create_payout fetch_status cancel_payout balance].freeze
      MAPPED_CAPABILITIES = %w[create_payout fetch_status cancel_payout].freeze

      def initialize(manifest)
        @manifest = Support.manifest_hash(manifest)
      end

      def render
        sections = [
          title,
          overall,
          capability_coverage,
          authentication,
          data_mappings,
          amount_transformation,
          status_normalization,
          webhook_readiness,
          review_audit,
          unresolved_warnings,
          unsupported_operations
        ]
        "#{sections.join("\n\n")}\n"
      end

      def overall_status
        overall_assessment.first
      end

      private

      def title
        provider = @manifest.dig("provider", "display_name") || @manifest.dig("provider", "slug")
        <<~MARKDOWN.chomp
          # #{Support.escape_markdown(provider)} compatibility report

          Deterministic assessment from the final Integration Manifest. `ready` means the generated contract has enough reviewed data for that area; it does not replace sandbox certification.
        MARKDOWN
      end

      def overall
        status, reasons = overall_assessment
        lines = ["## Overall", "", "**#{label(status)}**"]
        lines << ""
        reasons.each { |reason| lines << "- #{reason}" }
        lines.join("\n")
      end

      def capability_coverage
        lines = [
          "## Capability coverage",
          "",
          "| Capability | Manifest status | Compatibility | Operation | Evidence |",
          "|---|---|---|---|---|"
        ]
        CAPABILITIES.each do |intent|
          capability, operation = Support.capability_row(@manifest, intent)
          assessment = intent == "webhook" ? webhook_assessment.first : capability_assessment(intent)
          operation_text = operation ? "`#{operation['method']} #{Support.escape_markdown(operation['path'])}`" : "—"
          evidence = case capability["status"]
                     when "detected" then "confidence #{format('%.0f%%', capability.fetch('confidence', 0.0) * 100)}"
                     when "requires_review" then "candidate selection is unresolved"
                     else "not exposed by this specification"
                     end
          lines << "| `#{intent}` | #{capability['status']} | **#{label(assessment)}** | #{operation_text} | #{evidence} |"
        end
        lines.join("\n")
      end

      def authentication
        assessment, detail = authentication_assessment
        lines = ["## Authentication", "", "**#{label(assessment)}** — #{detail}", ""]
        schemes = @manifest.dig("auth", "schemes") || []
        if schemes.empty?
          lines << "No security schemes were declared. Per-operation no-auth declarations are evaluated separately."
        else
          lines << "| Scheme | Type | Placement | Generator support |"
          lines << "|---|---|---|---|"
          schemes.each do |scheme|
            type = [scheme["type"], scheme["scheme"]].compact.join("/")
            placement = [scheme["location"], scheme["parameter_name"]].compact.join(": ")
            lines << "| `#{Support.escape_markdown(scheme['name'])}` | #{type} | #{Support.escape_markdown(placement)} | #{scheme['supported'] ? 'ready' : 'unsupported'} |"
          end
        end
        lines.join("\n")
      end

      def data_mappings
        lines = [
          "## Data mappings",
          "",
          "| Capability | Compatibility | Ready mappings | Review-required | Unmapped required |",
          "|---|---|---:|---:|---:|"
        ]
        MAPPED_CAPABILITIES.each do |intent|
          mappings = @manifest.dig("field_mappings", intent, "request") || []
          confirmed = mappings.count { |mapping| mapping_value_declared?(mapping) && !mapping["requires_review"] }
          review = mappings.count { |mapping| mapping["requires_review"] }
          unmapped_required = mappings.count { |mapping| mapping["required"] && !mapping_value_declared?(mapping) }
          lines << "| `#{intent}` | **#{label(mapping_assessment(intent))}** | #{confirmed} | #{review} | #{unmapped_required} |"
        end
        lines.join("\n")
      end

      def amount_transformation
        amount = @manifest.dig("transformations", "amount") || {}
        assessment = amount_assessment
        <<~MARKDOWN.chomp
          ## Amount transformation

          **#{label(assessment)}** — field `#{amount['provider_field'] || 'unknown'}`, unit `#{amount['provider_unit'] || 'unknown'}`, direction `#{amount['direction'] || 'unknown'}`, factor `#{amount['factor'].nil? ? 'unknown' : amount['factor']}`, provenance `#{amount['provenance'] || 'unknown'}`.
        MARKDOWN
      end

      def status_normalization
        mappings = @manifest.dig("status_mapping", "mappings") || {}
        assessment = status_assessment
        unresolved = mappings.count do |_provider_status, mapping|
          mapping["normalized"] == "unknown" || mapping["requires_review"] || mapping["provenance"] == "default_rule"
        end
        <<~MARKDOWN.chomp
          ## Status normalization

          **#{label(assessment)}** — #{mappings.length} provider status value(s), #{unresolved} still depend on unknown or unconfirmed default semantics. Unknown runtime values remain `unknown`.
        MARKDOWN
      end

      def webhook_readiness
        webhook = @manifest["webhook"]
        assessment, details = webhook_assessment
        signature = webhook["signature"] || {}
        payload = webhook["payload"] || {}
        lines = ["## Webhook readiness", "", "**#{label(assessment)}** — #{details}"]
        if webhook["status"] != "missing"
          lines.concat(
            [
              "",
              "- Signature: `#{signature['header'] || 'unknown'}` / `#{signature['algorithm'] || 'unknown'}` / `#{signature['encoding'] || 'unknown'}`",
              "- Payload status path: `#{payload['status_path'] || 'unknown'}`",
              "- Provider operation id path: `#{payload['provider_operation_id_path'] || 'unknown'}`",
              "- Parsed `process_callback(payload)` assumes host authentication and applies terminal states through `approve_operation` / `reject_operation`. Raw body, signature header and callback secret are required by `process_verified_callback(raw_body, headers:)` at the HTTP boundary."
            ]
          )
        end
        lines.join("\n")
      end

      def review_audit
        overrides = @manifest["overrides"] || { "applied" => false }
        lines = ["## Review audit", ""]
        if overrides["applied"]
          lines << "- Overrides: applied (`#{overrides['override_version']}`)"
          lines << "- Source: #{Support.escape_markdown(overrides['source'])}"
          lines << "- Applied changes: #{overrides.fetch('applied_changes', []).length}"
          lines << "- Resolved warnings retained in audit: #{overrides.fetch('resolved_warnings', []).length}"
        else
          lines << "No overrides were applied; semantic mappings retain analyzer provenance."
        end
        lines.join("\n")
      end

      def unresolved_warnings
        warnings = @manifest["warnings"]
        lines = ["## Unresolved warnings", ""]
        if warnings.empty?
          lines << "No analyzer warnings remain unresolved."
        else
          warnings.each do |warning|
            location = warning["location"] ? " (`#{warning['location']}`)" : ""
            lines << "- **#{warning['code']}**#{location}: #{Support.escape_markdown(warning['message'])}"
          end
        end
        lines.join("\n")
      end

      def unsupported_operations
        operations = @manifest["unsupported_operations"]
        lines = ["## Unsupported or extra operations", ""]
        if operations.empty?
          lines << "No extra operations remain outside the supported payout capability set."
        else
          operations.each { |operation| lines << "- `#{Support.escape_markdown(operation)}`" }
        end
        lines.join("\n")
      end

      def overall_assessment
        create_status = capability_assessment("create_payout")
        auth_status, = authentication_assessment
        return ["unsupported", ["Create payout is not available."]] if create_status == "unsupported"
        return ["unsupported", ["Outbound authentication cannot be generated safely."]] if auth_status == "unsupported"

        checks = {
          "create payout capability" => create_status,
          "authentication" => auth_status,
          "create payout mappings" => mapping_assessment("create_payout"),
          "amount transformation" => amount_assessment,
          "status normalization" => status_assessment
        }
        %w[fetch_status cancel_payout].each do |intent|
          next if capability_assessment(intent) == "unsupported"

          checks["#{intent.tr('_', ' ')} capability"] = capability_assessment(intent)
          checks["#{intent.tr('_', ' ')} mappings"] = mapping_assessment(intent)
        end
        webhook_status, = webhook_assessment
        checks["webhook readiness"] = webhook_status unless webhook_status == "unsupported"
        reasons = checks.filter_map { |name, status| "#{name} is #{status}" unless status == "ready" }
        reasons << "#{@manifest['warnings'].length} unresolved analyzer warning(s) remain" unless @manifest["warnings"].empty?
        return ["needs_review", reasons] unless reasons.empty?

        ["ready", ["Available core capabilities, mappings, auth, amount and status normalization are reviewed."]]
      end

      def capability_assessment(intent)
        case @manifest.dig("capabilities", intent, "status")
        when "detected" then "ready"
        when "requires_review" then "needs_review"
        else "unsupported"
        end
      end

      def authentication_assessment
        operations = OUTBOUND_CAPABILITIES.filter_map do |intent|
          capability = @manifest.dig("capabilities", intent)
          capability["operation_key"] if capability && capability["status"] == "detected"
        end
        return ["needs_review", "No outbound operation was detected."] if operations.empty?

        rows = operations.map { |key| @manifest.dig("auth", "operations", key) }
        return ["needs_review", "Authentication requirements are missing for a detected operation."] if rows.any?(&:nil?)
        unless rows.all? { |row| row["requirements"].is_a?(Array) }
          return ["needs_review", "Authentication requirements are incomplete for a detected operation."]
        end

        unsupported = rows.any? do |row|
          requirements = row.fetch("requirements", [])
          !requirements.empty? && requirements.none? { |requirement| requirement["supported"] }
        end
        return ["unsupported", "At least one detected outbound operation has no supported auth alternative."] if unsupported

        ["ready", "Every detected outbound operation has a supported auth alternative or explicitly requires no auth."]
      end

      def mapping_assessment(intent)
        capability_status = @manifest.dig("capabilities", intent, "status")
        return "unsupported" if capability_status == "missing"
        return "needs_review" unless capability_status == "detected"

        mapping = @manifest.dig("field_mappings", intent)
        return "needs_review" unless mapping && mapping["status"] == "detected"

        request = mapping.fetch("request", [])
        return "needs_review" if request.any? { |field| field["requires_review"] }
        return "needs_review" if request.any? { |field| !mapping_value_declared?(field) }

        "ready"
      end

      def mapping_value_declared?(mapping)
        !mapping["source_candidate"].nil? || mapping.key?("constant_value")
      end

      def amount_assessment
        return "unsupported" if capability_assessment("create_payout") == "unsupported"

        amount = @manifest.dig("transformations", "amount") || {}
        return "needs_review" unless amount["provider_field"]
        return "needs_review" if amount["requires_review"] || amount["provider_unit"] == "unknown"
        return "needs_review" unless %w[major_to_minor none].include?(amount["direction"])
        return "needs_review" unless amount["factor"].is_a?(Numeric) && amount["factor"].positive?

        "ready"
      end

      def status_assessment
        mappings = @manifest.dig("status_mapping", "mappings") || {}
        return "needs_review" if mappings.empty?
        return "needs_review" if mappings.values.any? do |mapping|
          mapping["normalized"] == "unknown" || mapping["requires_review"] || mapping["provenance"] == "default_rule"
        end

        "ready"
      end

      def webhook_assessment
        status = @manifest.dig("webhook", "status")
        return ["unsupported", "No webhook capability was detected."] if status == "missing"
        return ["needs_review", "Webhook operation selection requires review."] unless status == "detected"

        signature = @manifest.dig("webhook", "signature") || {}
        payload = @manifest.dig("webhook", "payload") || {}
        missing = []
        missing << "signature header" unless signature["header"]
        missing << "signature algorithm" unless signature["algorithm"]
        missing << "signature encoding" unless signature["encoding"]
        missing << "payload status path" unless payload["status_path"]
        missing << "provider operation id path" unless payload["provider_operation_id_path"]
        return ["needs_review", "Missing #{missing.join(', ')}."] unless missing.empty?
        unless signature["algorithm"] == "hmac_sha256" && %w[hex base64].include?(signature["encoding"])
          return ["needs_review", "Signature algorithm or encoding is not supported by the generated service."]
        end

        if @manifest["warnings"].any? { |warning| warning["code"] == "CALLBACK_SECRET_NOT_DECLARED" }
          return ["needs_review", "Signature and payload mappings are complete, but the callback secret needs runtime configuration."]
        end

        ["ready", "Signature and callback payload mappings are complete; runtime credentials are still required."]
      end

      def label(status)
        status.tr("_", " ").upcase
      end
    end
  end
end
