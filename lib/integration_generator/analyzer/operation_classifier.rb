# frozen_string_literal: true

module IntegrationGenerator
  module Analyzer
    class OperationClassifier
      INTENTS = %w[create_payout fetch_status cancel_payout webhook balance].freeze
      MONEY_RESOURCES = %w[payout payouts withdrawal withdrawals transfer transfers disbursement disbursements remittance remittances].freeze
      CREATE_VERBS = %w[create initiate send submit start request].freeze
      FETCH_VERBS = %w[get fetch retrieve lookup check query status].freeze
      CANCEL_VERBS = %w[cancel void reverse abort revoke].freeze
      WEBHOOK_WORDS = %w[webhook webhooks callback callbacks notification notifications notify].freeze
      EVENT_WORDS = %w[event events].freeze
      BALANCE_WORDS = %w[balance balances available_balance funds wallet wallets].freeze
      AMOUNT_FIELDS = %w[amount value sum money].freeze
      CURRENCY_FIELDS = %w[currency asset currency_code].freeze
      DESTINATION_FIELDS = %w[recipient destination beneficiary payee account iban phone card bank].freeze
      STATE_FIELDS = %w[status state payment_status transfer_status payout_status].freeze
      ID_FIELDS = %w[id payout_id transfer_id transaction_id operation_id reference].freeze
      SIGNATURE_WORDS = %w[signature signed hmac digest].freeze

      MAX_SCORES = {
        "create_payout" => 90,
        "fetch_status" => 88,
        "cancel_payout" => 73,
        "webhook" => 87,
        "balance" => 75
      }.freeze

      def classify(operation)
        candidates = INTENTS.map { |intent| score(intent, operation) }
        ranked = candidates.sort_by { |candidate| [-candidate["confidence"], INTENTS.index(candidate["intent"])] }
        top = ranked.first
        second = ranked[1]
        ambiguous = top["confidence"] >= 0.5 && (top["confidence"] - second["confidence"]) < 0.1

        intent, decision = decision(top, ambiguous)
        {
          "intent" => intent,
          "confidence" => top["confidence"],
          "decision" => decision,
          "evidence" => top["evidence"],
          "alternatives" => ranked.map do |candidate|
            candidate.slice("intent", "score", "max_score", "confidence")
          end
        }
      end

      private

      def decision(top, ambiguous)
        return ["unknown", "ambiguous"] if ambiguous
        return [top["intent"], "accepted"] if top["confidence"] >= 0.8
        return [top["intent"], "review_recommended"] if top["confidence"] >= 0.5

        ["unknown", "unsupported"]
      end

      def score(intent, operation)
        evidence = []
        raw_score = send("score_#{intent}", operation, evidence)
        raw_score -= 5 if operation["deprecated"] == true
        raw_score = [raw_score, 0].max
        max_score = MAX_SCORES.fetch(intent)

        {
          "intent" => intent,
          "score" => raw_score,
          "max_score" => max_score,
          "confidence" => [(raw_score.to_f / max_score).round(2), 1.0].min,
          "evidence" => evidence
        }
      end

      def score_create_payout(operation, evidence)
        tokens = Support.text_tokens(operation)
        identity_tokens = Support.tokenize([operation["path"], operation["operation_id"]].compact.join(" "))
        request_fields = Support.request_field_tokens(operation)
        return 0 if Support.intersection?(identity_tokens, CANCEL_VERBS)

        score = 0
        score += add(evidence, "write_method", 10, "method is #{operation['method']}") if %w[POST PUT].include?(operation["method"])
        if operation.fetch("parameters", []).none? { |parameter| parameter["in"] == "path" }
          score += add(evidence, "collection_path", 12, "path has no item identifier")
        end
        score += add(evidence, "money_resource", 12, "operation text contains a payout-like resource") if Support.intersection?(tokens, MONEY_RESOURCES)
        has_create_verb = Support.intersection?(tokens, CREATE_VERBS)
        score += add(evidence, "create_verb", 25, "operation text contains a create-like verb") if has_create_verb
        score += add(evidence, "amount_field", 10, "request contains amount/value") if Support.intersection?(request_fields, AMOUNT_FIELDS)
        score += add(evidence, "currency_field", 4, "request contains currency/asset") if Support.intersection?(request_fields, CURRENCY_FIELDS)
        score += add(evidence, "destination_field", 12, "request contains recipient/destination data") if Support.intersection?(request_fields, DESTINATION_FIELDS)
        success_statuses = operation.fetch("responses", {}).keys
        score += add(evidence, "creation_response", 5, "response includes 201/202") unless (success_statuses & %w[201 202]).empty?
        score = [score, 44].min if operation["request_body"].nil? && !has_create_verb
        score
      end

      def score_fetch_status(operation, evidence)
        tokens = Support.text_tokens(operation)
        response_fields = Support.response_field_tokens(operation)
        path_parameters = operation.fetch("parameters", []).select { |parameter| parameter["in"] == "path" }
        return 0 if Support.intersection?(tokens, BALANCE_WORDS)

        score = 0
        score += add(evidence, "read_method", 18, "method is GET") if operation["method"] == "GET"
        score += add(evidence, "item_path", 15, "operation has a path parameter") unless path_parameters.empty?
        score += add(evidence, "money_resource", 10, "operation text contains a payout-like resource") if Support.intersection?(tokens, MONEY_RESOURCES)
        has_fetch_verb = Support.intersection?(tokens, FETCH_VERBS)
        score += add(evidence, "fetch_verb", 22, "operation text contains fetch/status semantics") if has_fetch_verb
        score += add(evidence, "state_response", 15, "response contains status/state") if Support.intersection?(response_fields, STATE_FIELDS)
        if path_parameters.any? { |parameter| Support.intersection?(Support.tokenize(parameter["name"]), ID_FIELDS) }
          score += add(evidence, "identifier_parameter", 8, "path parameter is identifier-like")
        end
        score = [score, 49].min if path_parameters.empty? && !tokens.include?("status")
        score
      end

      def score_cancel_payout(operation, evidence)
        tokens = Support.text_tokens(operation)
        return 0 unless Support.intersection?(tokens, CANCEL_VERBS)

        response_fields = Support.response_field_tokens(operation)
        mutation_method = %w[POST DELETE PATCH].include?(operation["method"])
        score = 0
        score += add(evidence, "mutation_method", 10, "method can mutate/cancel a resource") if mutation_method
        if operation.fetch("parameters", []).any? { |parameter| parameter["in"] == "path" }
          score += add(evidence, "item_path", 10, "operation has a path parameter")
        end
        score += add(evidence, "cancel_verb", 35, "operation text contains cancel/reverse semantics")
        score += add(evidence, "money_resource", 10, "operation text contains a payout-like resource") if Support.intersection?(tokens, MONEY_RESOURCES)
        score += add(evidence, "state_response", 8, "response contains status/state") if Support.intersection?(response_fields, STATE_FIELDS)
        score = [score, 49].min unless mutation_method
        score
      end

      def score_webhook(operation, evidence)
        tokens = Support.text_tokens(operation)
        request_fields = Support.request_field_tokens(operation)
        header_tokens = operation.fetch("parameters", [])
                                 .select { |parameter| parameter["in"] == "header" }
                                 .flat_map { |parameter| Support.tokenize([parameter["name"], parameter["description"]].compact.join(" ")) }
        has_webhook_word = Support.intersection?(tokens, WEBHOOK_WORDS)
        has_event_word = Support.intersection?(tokens, EVENT_WORDS)
        has_event = request_fields.include?("event") || request_fields.include?("event_type")
        has_signature = Support.intersection?(header_tokens, SIGNATURE_WORDS)

        score = 0
        score += add(evidence, "post_method", 5, "method is POST") if operation["method"] == "POST"
        score += add(evidence, "webhook_terms", 30, "operation text contains webhook/callback semantics") if has_webhook_word
        score += add(evidence, "event_terms", 8, "operation text contains generic event semantics") if has_event_word && !has_webhook_word
        score += add(evidence, "event_field", 15, "request contains event data") if has_event
        score += add(evidence, "state_field", 7, "request contains status/state") if Support.intersection?(request_fields, STATE_FIELDS)
        score += add(evidence, "signature_header", 25, "request has a signature-like header") if has_signature
        score += add(evidence, "explicit_no_auth", 5, "operation explicitly disables outbound auth") if operation["security"] == []
        score = [score, 29].min unless has_webhook_word || has_event || has_signature
        score
      end

      def score_balance(operation, evidence)
        tokens = Support.text_tokens(operation)
        response_fields = Support.response_field_tokens(operation)
        has_balance_word = Support.intersection?(tokens, BALANCE_WORDS)

        score = 0
        score += add(evidence, "read_method", 15, "method is GET") if operation["method"] == "GET"
        score += add(evidence, "balance_terms", 35, "operation text contains balance/funds semantics") if has_balance_word
        score += add(evidence, "balance_response", 20, "response contains balance/funds data") if Support.intersection?(response_fields, BALANCE_WORDS)
        score += add(evidence, "currency_response", 5, "response contains currency/asset") if Support.intersection?(response_fields, CURRENCY_FIELDS)
        score = [score, 39].min if operation["request_body"] && !has_balance_word
        score
      end

      def add(evidence, rule, points, detail)
        evidence << { "rule" => rule, "score" => points, "detail" => detail }
        points
      end
    end
  end
end
