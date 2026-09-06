# frozen_string_literal: true

module IntegrationGenerator
  # Converts parser/analyzer diagnostics into an explicit user action contract.
  # It does not change the manifest or claim that an unsupported construct can
  # be repaired by an override.
  module DiagnosticRemediation
    KINDS = %w[reviewable manual_configuration unsupported invalid_spec].freeze

    REVIEWABLE_CODES = %w[
      AMBIGUOUS_CAPABILITY AMBIGUOUS_OPERATION_INTENT
      AMBIGUOUS_PROVIDER_OPERATION_ID_MAPPING AMBIGUOUS_WEBHOOK_PAYLOAD_PATH
      AMBIGUOUS_WEBHOOK_SIGNATURE_HEADER AMOUNT_FACTOR_AMBIGUOUS
      AMOUNT_UNIT_AMBIGUOUS CONDITIONAL_REQUIREMENT_INFERRED
      CONFLICTING_STATUS_ENUMS IDEMPOTENCY_SOURCE_REQUIRES_REVIEW
      PROVIDER_OPERATION_ID_MAPPING_NOT_FOUND REQUEST_PARAMETER_MAPPING_NOT_FOUND
      REQUIRED_REQUEST_BODY_MAPPING_NOT_FOUND STATUS_FIELD_NOT_FOUND
      STATUS_MAPPING_DEFAULT_RULES_APPLIED UNKNOWN_STATUS
      WEBHOOK_SIGNATURE_ALGORITHM_UNKNOWN WEBHOOK_SIGNATURE_ENCODING_UNKNOWN
      WEBHOOK_SIGNATURE_NOT_FOUND
    ].freeze

    MANUAL_CONFIGURATION_CODES = %w[
      CALLBACK_SECRET_NOT_DECLARED
    ].freeze

    UNSUPPORTED_CODES = %w[
      AUTH_NOT_DETECTED AUTH_REQUIREMENTS_VARY_BY_OPERATION MISSING_CAPABILITY
      PROVIDER_ERROR_CODE_NOT_FOUND UNKNOWN_SECURITY_SCHEME UNSUPPORTED_AUTH
      UNSUPPORTED_CALLBACKS UNSUPPORTED_CAPABILITY UNSUPPORTED_MEDIA_TYPE
      UNSUPPORTED_OPERATION UNSUPPORTED_PARAMETER_CONTENT
      UNSUPPORTED_PARAMETER_LOCATION UNSUPPORTED_PATH_ITEM
      UNSUPPORTED_PATH_ITEM_FIELD UNSUPPORTED_REFERENCE UNSUPPORTED_SCHEMA
      UNSUPPORTED_SCHEMA_KEYWORD UNSUPPORTED_WEBHOOKS_KEYWORD
    ].freeze

    INVALID_SPEC_CODES = %w[
      FILE_NOT_FOUND FILE_NOT_READABLE PARSE_ERROR REF_CYCLE REF_NOT_FOUND
      SPEC_INVALID UNSUPPORTED_FORMAT UNSUPPORTED_OPENAPI_VERSION
    ].freeze

    SOURCE_DIAGNOSTIC_CODES = %w[
      UNKNOWN_SECURITY_SCHEME UNSUPPORTED_AUTH UNSUPPORTED_CALLBACKS
      UNSUPPORTED_MEDIA_TYPE UNSUPPORTED_PARAMETER_CONTENT
      UNSUPPORTED_PARAMETER_LOCATION UNSUPPORTED_PATH_ITEM
      UNSUPPORTED_PATH_ITEM_FIELD UNSUPPORTED_REFERENCE UNSUPPORTED_SCHEMA
      UNSUPPORTED_SCHEMA_KEYWORD UNSUPPORTED_WEBHOOKS_KEYWORD
    ].freeze

    SPECIFIC = {
      "UNSUPPORTED_SCHEMA_KEYWORD" => {
        "title" => "Конструкция схемы пока не поддерживается",
        "guidance" => "Генератор сохранил ограничение, но не нормализует эту конструкцию. Проверьте исходный фрагмент; override не добавит поддержку ключевого слова."
      },
      "CALLBACK_SECRET_NOT_DECLARED" => {
        "title" => "Нужен callback secret в окружении",
        "guidance" => "OpenAPI не должен содержать рабочий секрет. Задайте переменную окружения в host-приложении при подключении интеграции."
      },
      "STATUS_MAPPING_DEFAULT_RULES_APPLIED" => {
        "title" => "Подтвердите смысл статусов",
        "guidance" => "Сопоставления предложены общими правилами. Сверьте их с документацией провайдера и подтвердите через override."
      },
      "REQUEST_PARAMETER_MAPPING_NOT_FOUND" => {
        "title" => "Укажите источник параметра",
        "guidance" => "Свяжите поле провайдера с подтверждённым host source, request_method или явной константой."
      },
      "REQUIRED_REQUEST_BODY_MAPPING_NOT_FOUND" => {
        "title" => "Нужно явное сопоставление обязательного поля",
        "guidance" => "Неизвестное поле не привязано к payout_requisite вслепую. Добавьте подтверждённый source, request_method или константу в override."
      },
      "AMOUNT_UNIT_AMBIGUOUS" => {
        "title" => "Уточните единицы суммы",
        "guidance" => "Подтвердите единицу, направление и коэффициент преобразования по контракту провайдера."
      },
      "MISSING_CAPABILITY" => {
        "title" => "Возможность не найдена",
        "guidance" => "Это состав обнаруженного API. Отсутствующую операцию генератор не объявляет доступной и не может создать её через override."
      },
      "PROVIDER_ERROR_CODE_NOT_FOUND" => {
        "title" => "Код ошибки не заявлен",
        "guidance" => "HTTP-ответ сохранён, но структурный provider code не найден. Проверьте исходный error contract и учтите ограничение при подключении."
      }
    }.freeze

    module_function

    def decorate(diagnostics)
      diagnostics.map { |diagnostic| decorate_one(diagnostic) }
    end

    def summary(diagnostics)
      counts = KINDS.to_h { |kind| [kind, 0] }
      decorate(diagnostics).each { |diagnostic| counts[diagnostic.fetch("kind")] += 1 }
      counts.merge("total" => diagnostics.length)
    end

    def decorate_one(diagnostic)
      value = stringify_keys(diagnostic)
      code = value["code"].to_s
      kind = kind_for(code)
      known = known_code?(code)
      specific = SPECIFIC.fetch(code, {})
      value.merge(
        "kind" => kind,
        "title" => specific["title"] || default_title(kind),
        "guidance" => specific["guidance"] || default_guidance(kind),
        "override_supported" => kind == "reviewable",
        "target" => known ? target_for(kind, code) : nil,
        "source_location" => known ? source_location(kind, code, value["location"]) : nil
      )
    end

    def for_error(code, message, location = nil)
      decorate_one("code" => code, "message" => message, "location" => location)
    end

    def kind_for(code)
      return "reviewable" if REVIEWABLE_CODES.include?(code)
      return "manual_configuration" if MANUAL_CONFIGURATION_CODES.include?(code)
      return "invalid_spec" if INVALID_SPEC_CODES.include?(code)

      "unsupported"
    end

    def target_for(kind, code)
      case kind
      when "reviewable"
        { "view" => "source", "focus" => "overrides", "label" => "Открыть overrides" }
      when "manual_configuration"
        { "view" => "webhook", "focus" => "connection", "label" => "Открыть подключение" }
      when "invalid_spec", "unsupported"
        if kind == "invalid_spec" || SOURCE_DIAGNOSTIC_CODES.include?(code)
          { "view" => "source", "focus" => "specification", "label" => "Показать в OpenAPI" }
        else
          { "view" => "overview", "focus" => nil, "label" => "Открыть обзор" }
        end
      end
    end

    def source_location(kind, code, location)
      return nil unless kind == "invalid_spec" || SOURCE_DIAGNOSTIC_CODES.include?(code)

      location
    end

    def known_code?(code)
      REVIEWABLE_CODES.include?(code) || MANUAL_CONFIGURATION_CODES.include?(code) ||
        UNSUPPORTED_CODES.include?(code) || INVALID_SPEC_CODES.include?(code)
    end

    def default_title(kind)
      {
        "reviewable" => "Нужно решение интегратора",
        "manual_configuration" => "Нужна настройка подключения",
        "unsupported" => "Ограничение генератора или состава API",
        "invalid_spec" => "Спецификация некорректна"
      }.fetch(kind)
    end

    def default_guidance(kind)
      {
        "reviewable" => "Проверьте предложенное решение и зафиксируйте подтверждённое значение в override.",
        "manual_configuration" => "Выполните настройку в host-приложении; изменение OpenAPI или override не требуется.",
        "unsupported" => "Автоматического исправления нет. Изучите исходный фрагмент и сохранённое ограничение.",
        "invalid_spec" => "Исправьте входной OpenAPI в указанном месте и повторите анализ."
      }.fetch(kind)
    end

    def stringify_keys(value)
      value.to_h.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
    end
  end
end
