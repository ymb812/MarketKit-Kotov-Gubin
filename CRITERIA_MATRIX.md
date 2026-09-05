# Рабочая матрица критериев третьего чекпоинта

Составлена и актуализирована 2026-09-05 после этапа 2 [рабочего плана](CHECKPOINT_3_PLAN.md). Все 16 экспертных подкритериев связаны с реализацией и проверками. Результаты ревью, исправления R1–R10 и фактические прогоны — в [REVIEW_REPORT.md](REVIEW_REPORT.md). Матрица остаётся подробным источником трассировки; единый маршрут проверки вынесен в [JURY_GUIDE.md](JURY_GUIDE.md), архитектура — в [MODULE_MAP.md](MODULE_MAP.md). Это не самооценка в баллах.

## Как читать доказательства

На этапе 1 были прочитаны исходники/assertions; на этапе 2 выполнены ревью, исправления и новые проверки: **123 tests / 749 assertions**, три generated bundles + `ruby -c`, manifest-only byte comparison, Windows ASCII/Unicode root launch и HTTP generation/download. Все проверки успешны в указанном scope. В Windows Unicode candidate suite — один отдельный skip для запуска из постороннего cwd. Полная запись evidence и границ находится в REVIEW_REPORT; «подтверждено» здесь не означает все возможные OpenAPI.

## Вердикт по группам после этапа 2

| Подкритерии | Вердикт и оставшаяся граница |
|---|---|
| E1.1–E1.3 | Проверены; исправлены направление readOnly/writeOnly, success-only lifecycle и scoped-ID inference. Полный стандарт, callbacks/top-level webhooks и advanced composition не поддержаны. |
| E2.1–E2.3 | Исправлены и проверены response variants, error precedence, AND/OR auth, parsed callback/verified boundary. Persistence/retry/transport принадлежат хосту. |
| E3.1–E3.2 | Исправлены nullable presence, scoped mappings и direction projection; exact amount подтверждён. Полная runtime scalar constraint validation остаётся ограничением. |
| E4.1–E4.3 | Три спецификации и дополнительные structural mutations, manifest-only boundary подтверждены; расширение правил требует пояснений на этапе 3. |
| E5.1–E5.3 | ASCII/Unicode root launch, LF/SHA, web generation/download и generated docs проверены; judge guide завершён. Фактический presentation-browser rehearsal ещё впереди. |
| E6.1–E6.2 | Границы слоёв сохранены, malformed manifest/auth guards и публикация после validation проверены. Полный deep validator/escaping и широкая декомпозиция остаются backlog. |

Различаем четыре уровня: **структурный факт OpenAPI → предложение analyzer с evidence/confidence → подтверждение override → исполняемое поведение generated service**. Обнаруженная capability не равна production-готовности; `ruby -c` проверяет синтаксис, а contract tests используют локальный host/client harness.

Основной вход — [examples/provider_api.yaml](examples/provider_api.yaml). Canonical generator/runtime tests создают manifest через Parser → ManifestBuilder, при необходимости применяют [novapay_overrides.yaml](examples/novapay_overrides.yaml), затем генерируют сервис. Генераторы не должны читать OpenAPI напрямую.

## Источники рубрики и уточнения

Формулировки и веса экспертных подкритериев сверены по таблице «Корректность разбора API-спецификации … Качество технической реализации» в двух локальных версиях задания:

- `C:/Users/ilya/Downloads/описание (1).docx`, SHA-256 `8807a4dfb98fdcf7b25517e9443a8805a33542ba844d2285cecd3ee7b3fd6b2f` — источник, названный в PROJECT_CONTEXT.
- локальный рабочий файл `docs/описание.docx`, SHA-256 `d0b93ffb5fa2fea6cac9a03fb74a781be8b856adba2af11f17dd8600b7afb463` — побайтово совпадает с `Downloads/описание.docx`. Каталог `docs/` не входит в передачу репозитория; официальный материал уже есть у организаторов.

Экспертные строки и веса совпадают: **100 баллов**. В отдельной технической таблице строки дают **103**; версия `(1)` печатает итог 100, версия без `(1)` — 103. Не выбирать новую шкалу и не перераспределять веса. Техническая детализация вынесена отдельно ниже.

Поздние уточнения: локальный `docs/qa_new.txt`, предоставленный пользователем; условия и иерархия источников — локальный `docs/PROJECT_CONTEXT.md`. Вопросы в Q&A сами по себе не являются ответами эксперта. Требования к независимой установке дополнены первоначальным `Downloads/error.txt`, локальным `docs/install_error_followup.txt` и сообщением пользователя об успешном запуске коллеги. Эти рабочие источники не нужны для запуска или воспроизведения code/test evidence из `JURY_GUIDE.md`.

## Полная экспертная рубрика

ID — наша навигация, формулировки и максимальные баллы — из задания. Знаки препинания унифицированы.

| ID | Группа | Подкритерий | Макс. | Основной вопрос ревью |
|---|---|---|---:|---|
| [E1.1](#e11) | Разбор API | определены основные методы API и параметры запросов и ответов | 8 | Полнота структурного извлечения в заявленном subset |
| [E1.2](#e12) | Разбор API | учтены авторизация, статусы операций и ошибки | 7 | Факты, inferred mappings и доменная политика разделены |
| [E1.3](#e13) | Разбор API | учтены webhook и другие условия взаимодействия, предусмотренные спецификацией | 5 | Detection, условия и неоднозначности; Q2/Q3 |
| [E2.1](#e21) | Генерация сервиса | сервис формирует и отправляет запросы к API | 10 | Работа generated adapter через абстрактный client |
| [E2.2](#e22) | Генерация сервиса | обрабатывает ответы, статусы операций и ошибки | 8 | Реальная нормализация и политика ошибок; Q3 |
| [E2.3](#e23) | Генерация сервиса | поддерживает входящие уведомления и настройку параметров подключения | 7 | Parsed callback из новых Q&A против raw-body requirement; Q2 |
| [E3.1](#e31) | Преобразования | корректно сопоставляются поля запросов, ответов и статусы операций | 8 | Host/provider mappings и подтверждение семантики |
| [E3.2](#e32) | Преобразования | корректно обрабатываются форматы данных, обязательные и необязательные поля | 7 | Извлечённые constraints против runtime validation; Q4 |
| [E4.1](#e41) | Универсальность | решение работает со спецификациями, отличающимися набором методов, полей и параметров | 7 | Достаточность структурных различий трёх входов; Q6 |
| [E4.2](#e42) | Универсальность | основная логика не привязана к одному конкретному провайдеру | 5 | Manifest boundary и отсутствие семантического hardcode |
| [E4.3](#e43) | Универсальность | предусмотрено добавление новых правил и обработка неподдерживаемых элементов спецификации | 3 | Реальная стоимость расширения, visible unsupported |
| [E5.1](#e51) | Использование | решение можно запустить и получить результат через понятный последовательный процесс | 6 | Чистая установка и штатные команды на Windows; Q1 |
| [E5.2](#e52) | Использование | есть необходимая информация по настройке, авторизации и использованию сгенерированной интеграции | 5 | Достаточность инструкции для нового интегратора; Q7 |
| [E5.3](#e53) | Использование | результат работы и возникающие ошибки представлены в понятном виде | 4 | Понятны причины и следующее действие, а не только code |
| [E6.1](#e61) | Качество | код имеет понятную структуру и разделение основных компонентов | 6 | Контракты слоёв, читаемость и излишняя сложность; Q8 |
| [E6.2](#e62) | Качество | предусмотрена обработка ошибок при разборе спецификации и генерации файлов | 4 | Негативные входы и отсутствие частичного результата; Q5 |
| | **Итого** | | **100** | Не самооценка реализации |

## Реализация и проверяемые особенности

<a id="e11"></a>
### E1.1 — Методы и параметры, 8

- **Реализация:** [OpenAPI::Parser](lib/integration_generator/openapi/parser.rb), `parse_operations`, `parse_parameters`, `parse_request_body`, `parse_responses`; [RefResolver](lib/integration_generator/openapi/ref_resolver.rb) и [SchemaParser](lib/integration_generator/openapi/schema_parser.rb). Сохраняются verb/path/operationId/tags/descriptions, path/query/header parameters, JSON body и response schemas/examples/headers, required/optional, вложенные object/array. Operation-level parameter заменяет одноимённый path-level по `(in, name)`; local refs раскрываются до semantic analysis.
- **Особенность для оценки:** полный request/response contract попадает в Generic IR, а не только список endpoints; required path-параметры нормализуются, неподдержанные конструкции не исчезают молча. Эти факты затем доступны manifest и генераторам.
- **Проверка:** [ParserTest](test/openapi/parser_test.rb), `test_parses_novapay_into_generic_ir`, `test_operation_parameter_replaces_path_parameter_with_same_identity`, `test_parses_structurally_different_json_spec`; [SchemaParserTest](test/openapi/schema_parser_test.rb), `test_normalizes_object_array_and_constraints`; [RefResolverTest](test/openapi/ref_resolver_test.rb), `test_resolves_chained_local_references_without_mutating_source`. В canonical assertions проверяются 5 операций, параметры, required, enum, ответы и headers.
- **Граница / ревью:** не весь OpenAPI/JSON Schema: external/cyclic refs, composition и callback objects не поддержаны. Проверить перенос всех обещанных полей до manifest, выбор media types и response variants; сохранённый `style/explode` ещё не доказывает его исполнение клиентом. Команды C1/C2.

<a id="e12"></a>
### E1.2 — Авторизация, статусы и ошибки, 7

- **Реализация:** [AuthAnalyzer](lib/integration_generator/analyzer/auth_analyzer.rb) `analyze`, [StatusAnalyzer](lib/integration_generator/analyzer/status_analyzer.rb) `analyze`, [ErrorAnalyzer](lib/integration_generator/analyzer/error_analyzer.rb) `extract_error`. API key, Bearer/Basic; root/per-operation security; enum statuses и их источники; HTTP errors, code/message paths, headers/examples.
- **Особенность для оценки:** error codes из schema enum и из examples хранятся раздельно; сохраняется `Retry-After`. Статусный словарь — помеченное предложение `default_rule`, unknown остаётся review-required; это не выдаётся за семантический факт провайдера.
- **Проверка:** [ManifestBuilderTest](test/analyzer/manifest_builder_test.rb), `test_builds_complete_canonical_manifest`: auth placement, 5 status mappings/provenance, 10 error entries, schema/example codes и `Retry-After`. `test_builds_alternative_manifest_without_fabricated_capabilities` проверяет Bearer, uppercase statuses и `4XX`; third-manifest test проверяет Basic.
- **Граница / ревью:** OAuth/OIDC/mTLS распознаются как unsupported. Извлечение ошибки не означает retry/block policy. Сверить оригинальную таблицу и новые Q&A — Q3; проверить комбинации security и разнородные status/error shapes — Q6. Команды C1/C2.

<a id="e13"></a>
### E1.3 — Webhook и дополнительные условия, 5

- **Реализация:** [OperationClassifier](lib/integration_generator/analyzer/operation_classifier.rb), [WebhookAnalyzer](lib/integration_generator/analyzer/webhook_analyzer.rb) `extract_signature`, `extract_payload`, `extract_events`; [FieldMappingAnalyzer](lib/integration_generator/analyzer/field_mapping_analyzer.rb) `conditional_requirements`, `parameter_mappings`. Обычный `POST /webhooks/...` классифицируется как входящий callback; извлекаются signature header/algorithm, event/status/id paths, idempotency и условные поля.
- **Особенность для оценки:** при нескольких signature headers/id paths выбор остаётся пустым с warning. Encoding подписи и host idempotency source подтверждаются общим override, условное поле вроде `bank_code` не становится исполняемым требованием из одного текстового предположения.
- **Проверка:** canonical [ManifestBuilderTest](test/analyzer/manifest_builder_test.rb); [ReviewRegressionsTest](test/generator/review_regressions_test.rb), `test_ambiguous_webhook_header_and_id_remain_unset_until_explicit_override`; [GeneratedServiceContractTest](test/generator/generated_service_contract_test.rb), `test_confirmed_canonical_conditional_rule_requires_bank_code_for_sbp`.
- **Граница / ревью:** OpenAPI callbacks/top-level webhooks — warnings; regex извлечения условий зависит от формулировки. Проверить что именно извлечено из OpenAPI, а что подтверждено Q&A/override. Вход callback и конфликт event/status — Q2/Q3. Команды C1/C2/C3.

<a id="e21"></a>
### E2.1 — Формирование и отправка запросов, 10

- **Реализация:** [ServiceGenerator](lib/integration_generator/generator/service_generator.rb), template `check_conditions`, `create_request`, `create_payout`, `fetch_status`, `cancel_payout`, `fetch_balance`, `build_request`, `dispatch`, `apply_auth`. Получаем `Provider::<Name>Service < BaseService`; запрос содержит method/url/headers/query/body из final manifest.
- **Особенность для оценки:** явный `provider_client.call(method:, url:, headers:, query:, body:)`; URL-encoding provider id, API key/Bearer/Basic, idempotency, mappings и amount conversion. Формирование request отделено от вызова client. Provider id возвращается хосту; сервис не сохраняет его сам. Новые Q&A не требуют реального сетевого обращения при проверке решения.
- **Проверка:** [GeneratedServiceContractTest](test/generator/generated_service_contract_test.rb), `test_builds_and_dispatches_create_request_through_explicit_client_boundary` проверяет FakeClient и возвращённый provider id, но использует `allow_unreviewed: true`; для подтверждённого штатного режима дополнительно `test_overridden_service_needs_no_mapping_escape_hatch_and_verifies_hex_webhook`. `test_fetch_status_interpolates_provider_operation_id` проверяет escaped URL. [AltWithdrawalServiceContractTest](test/generator/alt_withdrawal_service_contract_test.rb), `test_fetch_cancel_and_balance_dispatch_basic_authenticated_requests` — Basic и разные методы.
- **Граница / ревью:** production BaseService/operation/client не предоставлены, harness локальный; HTTP transport принадлежит хосту. Проверить соответствие сигнатур, client response contract, required header/query/body mappings и выводы тестов без inspection bypass — Q4/Q6. Команда C3.

<a id="e22"></a>
### E2.2 — Ответы, статусы и ошибки, 8

- **Реализация:** [ServiceGenerator](lib/integration_generator/generator/service_generator.rb), template `normalize_response`, `normalized_success`, `normalized_error`, `normalize_status`. Разделены 2xx/error responses; возвращаются provider id/status, normalized status, HTTP status, error code/message, `retry_after` и raw parsed body.
- **Особенность для оценки:** сохранение provider status и raw помогает разбору проблем; неподтверждённые synonyms не превращаются в финальный статус. Поддержано извлечение вложенных `data.transaction.id/state` на другой структуре API.
- **Проверка:** canonical [GeneratedServiceContractTest](test/generator/generated_service_contract_test.rb) проверяет `:unknown` до review; [AltWithdrawalServiceContractTest](test/generator/alt_withdrawal_service_contract_test.rb), `test_overridden_mapping_projects_host_object_to_provider_schema_and_normalizes_nested_response` — nested response. [ManifestBuilderTest](test/analyzer/manifest_builder_test.rb) доказывает извлечение error definitions, но сам по себе не доказывает исполнение всех error branches.
- **Результат Q3/Q6 / R4–R5:** [RuntimeReviewTest](test/generator/runtime_review_test.rb) проверяет exact/range/default error selection, HTTP 400/401/402/422/429/500, malformed JSON, разные success schemas и пустой 204. Оригинальный пример для 402 — `insufficient_balance` / `retry later`; generated error hash передаёт факты, а policy исполняет хост. Команда C3.

<a id="e23"></a>
### E2.3 — Входящие уведомления и параметры подключения, 7

- **Реализация:** [ServiceGenerator](lib/integration_generator/generator/service_generator.rb), `expanded_base_urls`, `adapter_config`; template `process_callback`, `verify_webhook_signature`, `secure_compare`. Servers/default variables и security приходят через manifest; base URL и credentials допускают ENV config. HMAC-SHA256 hex/base64, header/raw body/secret guards, callback id/status/error mappings.
- **Особенность для оценки:** после успешной подписи обрабатывается именно подписанное тело, что покрыто отдельной regression-проверкой. Неоднозначные id/status paths блокируют обработку даже при валидной подписи. Секреты остаются настройкой интегратора.
- **Проверка:** [GeneratedServiceContractTest](test/generator/generated_service_contract_test.rb), `test_overridden_service_needs_no_mapping_escape_hatch_and_verifies_hex_webhook`; [AltWithdrawalServiceContractTest](test/generator/alt_withdrawal_service_contract_test.rb), `test_overridden_webhook_verifies_base64_signature_and_maps_nested_payload`; [ReviewRegressionsTest](test/generator/review_regressions_test.rb), `test_verified_callback_uses_the_signed_body`, `test_missing_or_ambiguous_webhook_mapping_blocks_runtime_even_with_valid_signature`.
- **Результат Q2 / R3:** `process_callback(Hash)` соответствует parsed input и возвращает `signature_verification: :host_required`; аутентификация до применения результата — ответственность хоста. `process_verified_callback(raw_body, headers:)` проверяет HMAC и затем подписанное тело; legacy kwargs сохраняют verification path. Проверены parsed input, отсутствие ложного verified, tampered bytes и config guards. Docs/fixtures/UI согласованы. Команда C3.

<a id="e31"></a>
### E3.1 — Сопоставление полей и статусов, 8

- **Реализация:** [FieldMappingAnalyzer](lib/integration_generator/analyzer/field_mapping_analyzer.rb), `request_mappings`, `response_mappings`, `operation_mapping`; [StatusAnalyzer](lib/integration_generator/analyzer/status_analyzer.rb); [Overrides::Applier](lib/integration_generator/overrides/applier.rb), `apply_request_mapping!`, `apply_status_mapping!`. Host source → provider target/location/schema; nested response → provider id/status; mapping хранит confidence/evidence/provenance/review.
- **Особенность для оценки:** неизвестное required поле остаётся видимым и исправляется generic override. После parent/child mapping body ограничивается provider schema; внутренние поля host object не утекают в payout. Подтверждение override записано в audit и согласовано с fixtures.
- **Проверка:** [OverridesApplierTest](test/overrides/applier_test.rb), `test_applies_canonical_override_with_provenance_and_explicit_warning_resolution`; [ReviewRegressionsTest](test/generator/review_regressions_test.rb), `test_unknown_required_field_is_visible_overridable_and_preserves_false`, `test_schema_declared_child_can_be_added_by_override`; [AltWithdrawalServiceContractTest](test/generator/alt_withdrawal_service_contract_test.rb), `test_overridden_mapping_projects_host_object_to_provider_schema_and_normalizes_nested_response`.
- **Результат / граница:** mappings всех success responses связаны с HTTP status; runtime выбирает exact перед range, scoped merchant/payout ids разделены и проверены через override. Lexical rules остаются эвристикой, proposed mapping не равен verified. `accepted` остаётся unknown, event возвращается отдельно от status. Команды C2/C3.

<a id="e32"></a>
### E3.2 — Форматы и обязательность, 7

- **Реализация:** [SchemaParser](lib/integration_generator/openapi/schema_parser.rb) сохраняет formats/enums/constraints/nullable; [FieldMappingAnalyzer](lib/integration_generator/analyzer/field_mapping_analyzer.rb) — amount units и conditional requirements. [ServiceGenerator](lib/integration_generator/generator/service_generator.rb), template `transform_value`, `project_to_provider_schema`, `validate_required_body!`, `conditional_requirement_errors` исполняют поддержанные преобразования/проверки.
- **Особенность для оценки:** major→minor использует точную Rational-арифметику и отвергает нецелый результат; ×100 предлагается по явным копейкам/центам, общее `minor units` без exponent требует review. Required проверяется после composite projection, `false` сохраняется; explicit open maps/whole arrays обрабатываются с границей схемы. Подтверждённый `required_if` исполняется.
- **Проверка:** [FieldMappingAnalyzerTest](test/analyzer/field_mapping_analyzer_test.rb), `test_minor_units_without_exact_exponent_requires_review`; canonical overridden test из E2.1 проверяет ×100; [ReviewRegressionsTest](test/generator/review_regressions_test.rb), `test_nested_required_field_is_checked_after_composite_projection`, `test_projection_respects_explicit_open_map_and_schema_valued_additional_properties`, `test_whole_array_mapping_projects_each_item_and_rejects_unknown_item_schema`.
- **Результат Q4 / R7–R8:** explicit nullable nil/absence исправлены; optional omission/false, readOnly request projection и decimal/нецелые minor units проверены. Сохранение pattern/min/max/format в IR по-прежнему не означает полную runtime validation. Per-item host mappings `items[].field` не поддержаны; направления amount ограничены `major_to_minor`/`none`. Команды C1/C3.

<a id="e41"></a>
### E4.1 — Разные спецификации, 7

- **Реализация:** [canonical YAML](examples/provider_api.yaml), [transfer JSON](examples/alt_transfer_provider.json), [withdrawal YAML](examples/alt_withdrawal_provider.yaml), [withdrawal JSON override](examples/alt_withdrawal_overrides.json). Различаются версия/формат OpenAPI, API key/Bearer/Basic, endpoints/fields, набор capabilities, nested responses/callback, наличие operationId и encoding подписи.
- **Особенность для оценки:** одна команда [bin/demo](bin/demo) проводит три входа через публичный pipeline. Transfer даёт create/fetch и не выдумывает остальные методы; withdrawal требует review неоднозначного fetch и подтверждается общим override.
- **Проверка:** [ManifestBuilderTest](test/analyzer/manifest_builder_test.rb), `test_builds_alternative_manifest_without_fabricated_capabilities`, `test_builds_third_manifest_with_basic_auth_nested_responses_and_reviewable_fetch`; [ArtifactBundleTest](test/generator/artifact_bundle_test.rb), `test_third_provider_json_override_generates_basic_base64_nested_bundle`; [DemoTest](test/demo_test.rb), `test_creates_three_complete_bundles_in_new_requested_root_and_refuses_repeat` — ожидаются 5/2/5 detected capabilities и пять файлов на provider.
- **Граница / ревью — Q6:** это один официальный вход и две собственные fixtures; не проверенные реальные публичные provider APIs. Проверить достаточность независимых различий и слабые места на новых комбинациях без автоматического расширения OpenAPI scope. Команды C3/C4.

<a id="e42"></a>
### E4.2 — Отсутствие привязки к провайдеру, 5

- **Реализация:** [Parser](lib/integration_generator/openapi/parser.rb) → [ManifestBuilder](lib/integration_generator/analyzer/manifest_builder.rb) → [Manifest](lib/integration_generator/provider_ir/manifest.rb) → [ArtifactBundle](lib/integration_generator/generator/artifact_bundle.rb). Семантика NovaPay находится во входе и override-примере; rules используют общие признаки операций/полей, generators — final manifest.
- **Особенность для оценки:** `generate --manifest` работает без исходного OpenAPI. Source SHA-256 и override provenance позволяют проследить происхождение решения; не нужно копировать provider facts в шаблон.
- **Проверка:** [ArtifactBundleTest](test/generator/artifact_bundle_test.rb), `test_bundle_can_be_built_from_serialized_manifest_without_openapi` подменяет `Parser.parse_file` на исключение и проверяет генерацию; `test_third_provider_json_override_generates_basic_base64_nested_bundle` исключает NovaPay names в alternative bundle. [CLITest](test/cli_test.rb), `test_generate_accepts_prebuilt_manifest`.
- **Граница / ревью:** отсутствие строки `novapay` не доказывает отсутствия скрытых предположений о единственной форме API. Проверить semantic dependencies и manifest boundary вручную — Q6/Q8; неизменный canonical SHA не является provider-specific runtime логикой. Команды C3/C4.

<a id="e43"></a>
### E4.3 — Расширение правил и unsupported, 3

- **Реализация:** отдельные [analyzers](lib/integration_generator/analyzer), [OperationClassifier](lib/integration_generator/analyzer/operation_classifier.rb), [CapabilityResolver](lib/integration_generator/analyzer/capability_resolver.rb), [Overrides::Applier](lib/integration_generator/overrides/applier.rb), [FixturesGenerator](lib/integration_generator/generator/fixtures_generator.rb). Неизвестные операции идут в unsupported_operations, missing/review capabilities отражаются в warnings/report/unavailable_fixtures.
- **Особенность для оценки:** provider ambiguity можно исправить versioned YAML/JSON override без изменения Ruby core; смена operation intent пересчитывает зависимые секции, а audit сохраняет исходное решение и причину изменения.
- **Проверка:** [OperationClassifierTest](test/analyzer/operation_classifier_test.rb), `test_unrelated_operation_is_unsupported`, `test_multiple_create_operations_require_capability_review`; [OverridesApplierTest](test/overrides/applier_test.rb), `test_operation_intent_override_recalculates_capabilities_generically`, `test_strict_validation_rejects_unknown_targets_keys_and_values`; [ArtifactBundleTest](test/generator/artifact_bundle_test.rb), `test_alternative_artifacts_do_not_fabricate_missing_capabilities`.
- **Граница / ревью — Q8:** пять capability slots фиксированы; добавление нового доменного метода требует согласованных изменений слоёв. Generic overrides — конфигурация, не plugin API для нового правила. Документировать конкретный путь добавления rule/template и проверить стоимость расширения; лишние операции не обязаны становиться BaseService methods. Команды C2/C3.

<a id="e51"></a>
### E5.1 — Запуск и последовательный процесс, 6

- **Реализация:** [README](README.md), [CLI](lib/integration_generator/cli.rb) `inspect/analyze/generate`, [bin/demo](bin/demo), [bin/serve](bin/serve), [Web::Application](lib/integration_generator/web/application.rb). CLI запускает весь pipeline одной командой; UI использует те же слои и выдаёт файлы/архив.
- **Особенность для оценки:** нет Node build, CDN или внешнего runtime API; demo создаёт уникальный output root, показывает before/after и все обязательные артефакты. Установка gems и автономная работа установленного решения — разные этапы.
- **Проверка:** [CLITest](test/cli_test.rb), `test_generate_writes_validated_artifacts_and_refuses_overwrite`; [DemoTest](test/demo_test.rb), `test_creates_three_complete_bundles_in_new_requested_root_and_refuses_repeat`; [WebApplicationTest](test/web/application_test.rb), `test_generate_publishes_five_artifacts_and_matching_safe_archive`. Проверка upload Unicode filename не покрывает путь установки проекта.
- **Результат Q1 / R1–R2:** отдельно воспроизведены Unicode loader и CRLF/SHA проблемы. Bootstrap исправлен, candidate checkout в ASCII/Unicode+spaces с `core.autocrlf=true` прошёл LF/SHA, штатный запуск из root, demo и настоящий HTTP generation/download. Existing installed gems использованы повторно; чистая установка Ruby/gem cache не проверялась. External-cwd Unicode invocation вне поддержанного root-flow. Подробные пути и результаты — REVIEW_REPORT.

<a id="e52"></a>
### E5.2 — Информация для интегратора, 5

- **Реализация:** [DocumentationGenerator](lib/integration_generator/generator/documentation_generator.rb), `source_and_servers`, `authentication`, `capabilities`, `field_mappings`, `transformations`, `status_mapping`, `errors`, `webhook`, `manual_steps`; [FixturesGenerator](lib/integration_generator/generator/fixtures_generator.rb). В `INTEGRATION.md` — endpoints, ENV placeholders, mappings, conditions, signature details, warnings и host-client boundary.
- **Особенность для оценки:** inferred/overridden/unresolved решения разделены, source и audit видны. Fixtures предпочитают реальные OpenAPI examples, отмечают schema-generated данные и unavailable capabilities, не обещают подтверждённый результат для unreviewed status.
- **Проверка:** [ArtifactBundleTest](test/generator/artifact_bundle_test.rb), `test_renders_required_canonical_artifacts`: пять файлов, status docs, warning, named request example, parameter provenance, error response и callbacks; `test_alternative_artifacts_do_not_fabricate_missing_capabilities` — missing webhook. Это частичные assertions содержания; полнота инструкции ещё требует чтения generated файла.
- **Граница / ревью — Q7:** проверить достаточно ли сведений для реального подключения host/client и использования каждого метода, включая параметры ответов. Согласовать callback instruction с Q2. Английский язык generated инструкции пока сохраняется. Не выдавать JSON fixtures за generated RSpec. Команды C3/C4.

<a id="e53"></a>
### E5.3 — Понятный результат и ошибки, 4

- **Реализация:** [Error](lib/integration_generator/errors.rb), [CLI](lib/integration_generator/cli.rb) `run`, [CompatibilityGenerator](lib/integration_generator/generator/compatibility_generator.rb), [web/app.js](web/app.js). Machine-readable code/message/location, stderr/exit codes, readiness report, before/after audit и UI объяснения.
- **Особенность для оценки:** compatibility report различает READY/NEEDS REVIEW/UNSUPPORTED, не создаёт искусственный процент готовности. Снятые warnings остаются в audit; output lists и downloads связаны с тем же bundle.
- **Проверка:** [CLITest](test/cli_test.rb), `test_parser_error_is_written_only_to_stderr`, `test_analyze_reports_subject_specific_override_error`; [CompatibilityGeneratorTest](test/generator/compatibility_generator_test.rb), `test_reports_reviewed_canonical_areas_and_remaining_secret_configuration`, `test_cancel_review_is_in_overall_and_missing_optional_capabilities_are_not_fatal`; [WebApplicationTest](test/web/application_test.rb), `test_analyze_returns_inferred_and_final_manifest_for_canonical_spec` — final/inferred и needs_review.
- **Граница / ревью — Q7:** проверить читабельность и следующее действие для parser/config/override errors; частичный override не равен полному review. Секрет и конфликт host callback не должны смешиваться в одно успокаивающее объяснение NEEDS REVIEW. Browser QA в статусе историческая, проверка presentation browser ещё не закрыта. Команды C3/C5.

<a id="e61"></a>
### E6.1 — Структура и разделение компонентов, 6

- **Реализация:** раздельные [openapi](lib/integration_generator/openapi), [ir](lib/integration_generator/ir), [analyzer](lib/integration_generator/analyzer), [provider_ir](lib/integration_generator/provider_ir), [overrides](lib/integration_generator/overrides), [generator](lib/integration_generator/generator), [web](lib/integration_generator/web); [CLI](lib/integration_generator/cli.rb) оркестрирует pipeline. Основная реализация Ruby, UI — тонкий JS-слой.
- **Особенность для оценки:** один final manifest служит сервису, документации, fixtures и report; serializable IR и versioned overrides делают промежуточное решение проверяемым. Генерация отделена от публикации файлов и их проверки.
- **Проверка:** [ArtifactBundleTest](test/generator/artifact_bundle_test.rb), `test_artifacts_are_deterministic`, `test_bundle_can_be_built_from_serialized_manifest_without_openapi`; [CLITest](test/cli_test.rb), `test_generate_with_overrides_persists_exact_final_manifest`; чтение архитектуры в README и реализаций boundary.
- **Граница / ревью — Q8:** большой Overrides::Applier и inline Ruby template требуют оценки читаемости, связности и стоимости изменений, а не автоматической декомпозиции. Наличие каталогов не доказывает качество архитектуры. Проверить generic helpers/coupling, ясность контрактов и отсутствие runtime LLM/proprietary dependency; generated output не включать как аргумент о доле Ruby. Команды C2/C3 плюс code review.

<a id="e62"></a>
### E6.2 — Ошибки разбора и генерации, 4

- **Реализация:** [Loader](lib/integration_generator/openapi/loader.rb), [DocumentValidator](lib/integration_generator/openapi/document_validator.rb), [RefResolver](lib/integration_generator/openapi/ref_resolver.rb), [Manifest](lib/integration_generator/provider_ir/manifest.rb), [ArtifactBundle](lib/integration_generator/generator/artifact_bundle.rb) `validate!`, [OutputWriter](lib/integration_generator/generator/output_writer.rb) `write`. Safe YAML/JSON load, предметные errors, проверка Ruby/fixtures/manifest, staging и lock, запрет overwrite.
- **Особенность для оценки:** внешний `ruby -c` выполняется до rename staging-каталога в итоговый output; невалидный сервис не публикуется как успешный результат. Ошибки filesystem переводятся в предметные коды.
- **Проверка:** [OutputWriterTest](test/generator/output_writer_test.rb), `test_rejects_unsafe_artifact_filename_without_creating_target`, `test_runs_ruby_c_before_publishing_output` — target отсутствует и staging очищен; [CLITest](test/cli_test.rb), `test_generate_writes_validated_artifacts_and_refuses_overwrite`, `test_generate_requires_exactly_one_input`; negative tests в [test/openapi](test/openapi).
- **Граница / ревью — Q5:** manifest validation не покрывает все nested runtime shapes, Markdown escaping не полное. Проверить последствия некорректного prebuilt manifest, permission/write/lock errors и special paths. Проверка непустоты документа не доказывает корректность его содержания. Команды C1/C3 и targeted негативные случаи на этапе 2.

## Отдельная техническая детализация

Это crosswalk к тем же доказательствам, а не дополнительные баллы экспертной шкалы. По каждому техническому пункту на ревью проверить указанную часть отдельно.

| ID | Подкритерий технического жюри | Макс. | Evidence / вопрос |
|---|---|---:|---|
| T1.1 | определены доступные методы API | 5 | E1.1: operations |
| T1.2 | распознаны параметры запросов и ответов | 5 | E1.1: request/response contract |
| T1.3 | распознаны требования к авторизации | 4 | E1.2: security requirements |
| T1.4 | распознаны статусы и ошибки | 3 | E1.2, Q3 |
| T1.5 | распознаны webhook и дополнительные условия взаимодействия | 3 | E1.3 |
| T2.1 | сгенерированный сервис, соответствующий контракту Provider::BaseService | 5 | E2.1/E2.3, Q2: parsed callback |
| T2.2 | формирование и отправка запросов | 5 | E2.1: abstract client, без требования реальной сети |
| T2.3 | получение и обработка статуса операции | 4 | E2.2/E3.1: fetch и confirmed status |
| T2.4 | обработка ответов и ошибок | 4 | E2.2, Q3/Q6 |
| T2.5 | обработка входящих уведомлений | 4 | E2.3, Q2 |
| T2.6 | конфигурация адресов и параметров подключения | 3 | E2.3: servers/security/ENV |
| T3.1 | корректное сопоставление статусов | 5 | E3.1, Q3 |
| T3.2 | корректное сопоставление полей запросов и ответов | 4 | E3.1 |
| T3.3 | корректное преобразование форматов и единиц данных | 3 | E3.2, Q4 |
| T3.4 | корректная обработка обязательных и необязательных полей | 3 | E3.2, Q4 |
| T4.1 | поддерживаются спецификации с разным набором методов и полей | 5 | E4.1, Q6 |
| T4.2 | логика генерации отделена от особенностей конкретного провайдера | 3 | E4.2 |
| T4.3 | предусмотрено расширение шаблонов и правил генерации | 1 | E4.3/E6.1, Q8 |
| T4.4 | система сообщает о неподдерживаемых или неоднозначных элементах спецификации | 1 | E4.3/E5.3 |
| T5.1 | описание настройки и авторизации | 5 | E5.2 |
| T5.2 | описание методов, статусов и ошибок | 4 | E5.2, Q7 |
| T5.3 | после генерации сервиса есть также примеры запросов, ответов и уведомлений в файле fixtures.json | 4 | E5.2: named examples/provenance/unavailable; ArtifactBundleTest |
| T6.1 | понятный способ запуска | 4 | E5.1, Q1 |
| T6.2 | результат создается за один последовательный процесс | 3 | E5.1 |
| T6.3 | пользователь получает понятные сообщения о результате и ошибках | 3 | E5.3 |
| T7.1 | понятная архитектура и читаемый код | 4 | E6.1, Q8 |
| T7.2 | предусмотрена обработка ошибок при разборе спецификации и генерации файлов | 3 | E6.2, Q5 |
| T7.3 | инструкция по запуску и настройке | 3 | E5.1/E5.2, Q1/Q7 |
| | **Сумма строк** | **103** | В версии задания `(1)` итог напечатан как 100 |

Отраслевую рубрику также сохраняем отдельно: дополнительные идеи — 6 (manifest review, evidence, overrides, compatibility, validation; E4.3/E5.3/E6.2); выступление — 6 (этап сильного текста ещё впереди, видео отложено); полнота проработки — 8 (совокупность E1–E6 с явными ограничениями). Итого 20. Наличие UI само по себе не обосновывает дополнительные баллы.

## Исходная очередь вопросов этапа 2

Ниже сохранена постановка вопросов до исправлений. Их актуальные вердикты и фактические результаты находятся в REVIEW_REPORT и сводке в начале этой матрицы; это не список незавершённых блокеров.

| ID | Приоритет и предмет | Что уже известно | Чем закрыть |
|---|---|---|---|
| Q1 | В первую очередь: независимая установка | Файл есть, failed `-Ilib`, `$LOAD_PATH` содержит `????`; пользователь сообщил об успешном запуске после анализа. `bin/serve` и `.gitattributes` уже изменены до этой работы. SHA mismatch — отдельная ошибка. | Чистый Windows checkout с `core.autocrlf=true`; ASCII/кириллица/пробелы, штатные serve/integrate/demo, SHA/line endings. Успех обходного пути не приравнивать к устранению дефекта. |
| Q2 | В первую очередь: callback contract | Parsed JSON из Q&A и обязательный raw-body context текущего template расходятся по ожиданиям. | Явное решение host/service boundary, тест публичного payload-входа и сохранение корректной signature policy, синхронное обновление docs/fixtures. |
| Q3 | Core: статусы и error policy | Оригинал: pending/processing→in_progress, completed→approved, failed/cancelled→rejected; HTTP 402→insufficient_balance и пример действия retry later. Новые Q&A отсылают к этой документации. `accepted` и приоритет event/status в найденных таблицах не определены. | Подтвердить границу error facts/host actions; runtime tests нужных HTTP branches; документированное поведение неизвестного status и event/status conflict без выдуманной семантики. |
| Q4 | Core: formats/required/mappings | Есть required/composite/conditional и exact amount; нет полного runtime JSON Schema validator, известен required-nullable edge case. | Проверить исполнение заявленных constraints, nil/absence/false, optional fields, decimal amount и projection; устранить существенные пробелы или точно обозначить границу. |
| Q5 | Корректность диагностики и публикации | Основные guards есть, nested manifest validation и escaping неполные. | Прицельные негативные случаи и отсутствие частичного output; оценка влияния ограничений на критерии. |
| Q6 | Доказательства универсальности и runtime | Три repo specs, две искусственные; часть tests использует inspection flags, error runtime coverage ограничено выбранными assertions. | Сверить каждый claim с тестом без bypass, проверить response/security variants и новые комбинации структуры; решить, нужен ли дополнительный независимый вход. |
| Q7 | Документация и воспроизводимость claims | Guides есть, generated docs содержат основные разделы; это ещё не проверка достаточности для нового интегратора. | Прочитать fresh bundle как интегратор, сверить setup/auth/методы/errors/fixtures, привести README к одной актуальной цепочке ссылок. |
| Q8 | Архитектура и расширение без overhead | Слои разделены, но большие Applier/template и фиксированные capabilities требуют проверки. | Оценить реальные зависимости и добавить краткое описание расширения; refactor только по подтверждённой причине. |

Приоритеты определяют порядок, а не автоматическое исключение остальных вопросов. Это список рисков и проверок, не восемь уже подтверждённых багов.

## Команды воспроизведения

Запускать из корня проекта после установки Ruby/Bundler по README. На текущей машине для нового PowerShell при необходимости: `$env:Path = "C:\Ruby34-x64\bin;$env:Path"`. Команды служат воспроизведению; фактические результаты этапа 2 записаны в REVIEW_REPORT.

- **C1 — parser:** `bundle exec ruby -Itest test/openapi/parser_test.rb`, затем аналогично `schema_parser_test.rb` и `ref_resolver_test.rb` из той же папки. [Canonical manifest assertions](test/analyzer/manifest_builder_test.rb) проверяют следующее звено, но это C2.
- **C2 — semantic/override:** `bundle exec ruby -Itest test/analyzer/manifest_builder_test.rb`, `bundle exec ruby -Itest test/overrides/applier_test.rb`. Для изолированного случая Minitest принимает `--name test_...`.
- **C3 — generated artifacts/runtime:** `bundle exec ruby -Itest test/generator/generated_service_contract_test.rb`; аналогично `alt_withdrawal_service_contract_test.rb`, `review_regressions_test.rb`, `artifact_bundle_test.rb`, `compatibility_generator_test.rb`, `output_writer_test.rb`. Это repo Minitest, не generated RSpec.
- **C4 — полный pipeline:** `bundle exec ruby bin/demo` — новый уникальный output root, три provider bundles, `ruby -c` перед публикацией. Фактический путь брать из stdout. Для manifest boundary: `bundle exec ruby bin/integrate generate --manifest <созданный_manifest.yml> --output <новый_каталог>`; заменить placeholders реальными путями и сравнить bundle.
- **C5 — интерфейсы:** `bundle exec ruby -Itest test/cli_test.rb`, `bundle exec ruby -Itest test/web/application_test.rb`; штатный старт `bundle exec ruby bin/serve` и последовательность из README. Smoke/browser test не заменяется только WebApplication unit tests.

После существенных исправлений общая проверка — `bundle exec rake test`, затем canonical/alternate generation и syntax validation в порядке AGENTS.md. Не повторять дорогие успешные проверки без изменений, которые могли повлиять на результат.

## Передача на следующий этап

Матрица содержит 16 экспертных карточек, 28 технических соответствий, отраслевые критерии отдельно. Этапы 2–3 завершены: вопросы Q1–Q8 имеют итог в REVIEW_REPORT, а [JURY_GUIDE.md](JURY_GUIDE.md) и [MODULE_MAP.md](MODULE_MAP.md) дают внешний маршрут проверки. Очередь выше сохраняет исходные review-вопросы для трассировки. Следующий этап — сильный текст по всем критериям. Основываться на итоговых результатах и ограничениях, не на предположении о максимальных баллах.
