# Руководство для проверки решения

Самый короткий способ проверить проект — запустить `bundle exec ruby bin/demo`. Команда проводит три различающиеся OpenAPI-спецификации через один публичный Ruby pipeline, создаёт по пять файлов на провайдера и проверяет синтаксис каждого generated service. Ниже собраны ожидаемый результат, доказательства по всем подкритериям и границы, за которые решение не выдаётся.

Документ актуализирован после contract/remediation review 6 сентября 2026 года: **134 tests / 792 assertions, 0 failures, 0 errors, 0 skips**; frontend logic **7/7**; три полных bundle; manifest-only byte comparison; Windows-запуск из корня в Unicode-пути с пробелами; локальная HTTP-генерация и скачивание. Это доказательство заявленного subset, а не поддержка всего OpenAPI и не production-сертификация интеграции.

## Проверка за несколько минут

Нужны Ruby 3.1+ и Bundler. Все команды выполняются из корня репозитория.

```powershell
bundle install
$runRoot = 'output/jury-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
bundle exec ruby bin/demo --output $runRoot
```

Ожидаемый результат:

- три каталога: `novapay`, `alt_transfer`, `alt_withdrawal`;
- по пять файлов в каждом: service, `INTEGRATION.md`, `fixtures.json`, `compatibility_report.md`, `integration_manifest.yml`;
- 5/2/5 обнаруженных capabilities: transfer-спека не получает отсутствующие cancel/webhook/balance;
- для withdrawal виден переход `fetch_status: requires_review -> detected` после generic JSON override;
- API key, Bearer и Basic auth проходят один и тот же core;
- для всех трёх Ruby-файлов напечатан успешный `ruby -c`.

Откройте canonical bundle в таком порядке:

1. `$runRoot/novapay/integration_manifest.yml` — источник, operations, confidence/evidence, auth, mappings, overrides и unresolved warnings.
2. `$runRoot/novapay/compatibility_report.md` — короткая readiness-картина. Итог `NEEDS REVIEW` ожидаем: callback secret отсутствует в OpenAPI и должен прийти из ENV.
3. `$runRoot/novapay/novapay_service.rb` — методы BaseService-style adapter и реальное исполняемое поведение.
4. `$runRoot/novapay/INTEGRATION.md` — инструкция интегратору по setup, auth, methods, mappings, statuses, errors и callbacks.
5. `$runRoot/novapay/fixtures.json` — OpenAPI examples, schema-generated значения с provenance и ожидаемая нормализация.

Отдельно проверяется manifest-first граница:

```powershell
bundle exec ruby bin/integrate generate `
  --manifest "$runRoot/novapay/integration_manifest.yml" `
  --output "$runRoot/novapay-from-manifest"

$fromSpec = Get-ChildItem -LiteralPath "$runRoot/novapay" -File |
  Sort-Object Name |
  ForEach-Object { [pscustomobject]@{ Name = $_.Name; Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } }
$fromManifest = Get-ChildItem -LiteralPath "$runRoot/novapay-from-manifest" -File |
  Sort-Object Name |
  ForEach-Object { [pscustomobject]@{ Name = $_.Name; Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } }
Compare-Object $fromSpec $fromManifest -Property Name, Hash
```

Последняя команда ничего не выводит, если все пять файлов совпадают. Генератор при этом не получает ни OpenAPI, ни override.

Полная suite:

```powershell
bundle exec rake test
```

Зафиксированный результат на текущем завершённом core — 134 runs и 792 assertions без failures/errors/skips. Подробная установка, Windows-оговорки и UI находятся в [README.md](README.md); сценарий выступления — в [DEMO_GUIDE.md](DEMO_GUIDE.md).

## Что именно строит проект

Это не обычный OpenAPI SDK generator. Проект переводит transport contract в доменную заготовку payout adapter:

```text
OpenAPI → Generic IR → semantic analysis → inferred manifest
        → reviewed overrides → final manifest
        → Ruby service + integration docs + fixtures + compatibility report
```

Между «поле или endpoint найден» и «поведение можно исполнять» есть четыре разных состояния:

1. структурный факт из OpenAPI;
2. предложение analyzer с confidence и evidence;
3. подтверждение или исправление общим YAML/JSON override;
4. исполняемое поведение generated service.

Критичная неоднозначность не становится тихой догадкой. Она остаётся warning/TODO, требует review либо блокирует runtime. Это особенно видно на неподтверждённых status synonyms, неизвестном amount exponent, нескольких candidate operations и webhook paths.

## Доказательства по экспертной рубрике

Максимальные веса ниже взяты из задания и приведены только для навигации. Это не заявленная самооценка.

### E1. Разбор API — 20

**E1.1 — методы и параметры, 8.** [`OpenAPI::Parser`](lib/integration_generator/openapi/parser.rb), [`RefResolver`](lib/integration_generator/openapi/ref_resolver.rb) и [`SchemaParser`](lib/integration_generator/openapi/schema_parser.rb) сохраняют verb/path/operationId, path/query/header parameters, JSON request/response schemas, required/optional, examples, headers и вложенные object/array. Проверяют это [`parser_test.rb`](test/openapi/parser_test.rb), [`schema_parser_test.rb`](test/openapi/schema_parser_test.rb) и [`ref_resolver_test.rb`](test/openapi/ref_resolver_test.rb). Canonical assertions начинаются непосредственно с [официальной спеки](examples/provider_api.yaml), а не с переписанных значений. Граница: external/cyclic refs, advanced composition и callbacks objects вне subset; `style/explode` извлекается, но не заявлен как полностью исполняемый transport serializer.

**E1.2 — авторизация, статусы и ошибки, 7.** [`AuthAnalyzer`](lib/integration_generator/analyzer/auth_analyzer.rb), [`StatusAnalyzer`](lib/integration_generator/analyzer/status_analyzer.rb) и [`ErrorAnalyzer`](lib/integration_generator/analyzer/error_analyzer.rb) разделяют security requirements, lifecycle values и HTTP/provider error facts. Schema codes и example codes не смешиваются, `Retry-After` сохраняется. [`manifest_builder_test.rb`](test/analyzer/manifest_builder_test.rb) проверяет API key/Bearer/Basic и канонические errors; [`review_contracts_test.rb`](test/analyzer/review_contracts_test.rb) — success-only lifecycle и auth collisions. OAuth/OIDC/mTLS могут быть распознаны как unsupported, но их runtime execution не заявляется.

**E1.3 — webhook и дополнительные условия, 5.** [`OperationClassifier`](lib/integration_generator/analyzer/operation_classifier.rb), [`WebhookAnalyzer`](lib/integration_generator/analyzer/webhook_analyzer.rb) и [`FieldMappingAnalyzer`](lib/integration_generator/analyzer/field_mapping_analyzer.rb) находят обычный `POST /webhooks/...`, signature header/algorithm, payload paths, events, idempotency и условные fields. [`review_regressions_test.rb`](test/generator/review_regressions_test.rb) доказывает, что несколько подходящих header/id paths остаются неоднозначными до override; [`generated_service_contract_test.rb`](test/generator/generated_service_contract_test.rb) исполняет подтверждённый `required_if`. OpenAPI `callbacks` и top-level `webhooks` keyword пока только диагностируются.

### E2. Generated service — 25

**E2.1 — формирование и отправка запросов, 10.** [`ServiceGenerator`](lib/integration_generator/generator/service_generator.rb) создаёт `Provider::<Name>Service < Provider::BaseService`. `create_request` строит и отправляет запрос, разбирает ответ и возвращает `success(result: { id: provider_id })`; `create_payout` — совместимый alias, `build_provider_request` — отдельная inspection-граница. Fetch/cancel читают `operation.provider_operation_key`. [`generated_service_contract_test.rb`](test/generator/generated_service_contract_test.rb) проверяет этот callback-контракт платформы и SBP/card mapping, [`alt_withdrawal_service_contract_test.rb`](test/generator/alt_withdrawal_service_contract_test.rb) — alternative fetch/cancel/balance с Basic auth.

**E2.2 — ответы, статусы и ошибки, 8.** Generated `normalize_response` выбирает mapping по фактическому HTTP status, exact response имеет приоритет над range/default. Публичная граница переводит ошибки в стандартные платформенные symbols: `bad_request`, `unauthorized`, `forbidden`, `unprocessable_entity`, `too_many_requests`, `internal_server_error`; provider-specific symbols не создаются. `amount_limit_exceeded` означает validation rejection конкретной выплаты. [`runtime_review_test.rb`](test/generator/runtime_review_test.rb) исполняет разные 2xx schemas, malformed JSON и HTTP 400/401/402/422/429/500.

**E2.3 — callbacks и конфигурация подключения, 7.** Servers/security/ENV placeholders приходят из final manifest. Host аутентифицирует parsed payload до вызова `process_callback`; terminal status вызывает `approve_operation(provider_id)` или `reject_operation(provider_id, reason)`, а in-progress/unknown не меняет операцию. `process_verified_callback(raw_body, headers:)` проверяет HMAC-SHA256 hex/base64 на исходных байтах и разбирает именно подписанное тело. Tampered bytes, missing config, status-path precedence и nested callback проверяются в трёх runtime contract suites. Callback secret намеренно не генерируется.

### E3. Преобразования — 15

**E3.1 — поля и статусы, 8.** [`FieldMappingAnalyzer`](lib/integration_generator/analyzer/field_mapping_analyzer.rb) использует подтверждённую host-модель: `operation.id`, `operation.amount`, JSONB `operation.payout_requisite` и `operation.provider_operation_key`. SBP читается из `payout_requisite.sbp.*`, номер карты — из плоского `payout_requisite.card_number`; `request_method` и scalar-константы доступны только через явный override. Для незнакомых IBAN/account/tax fields анализатор оставляет TODO вместо одноимённой догадки. [`Overrides::Applier`](lib/integration_generator/overrides/applier.rb) валидирует mapping и пишет before/after audit.

**E3.2 — форматы, required и optional, 7.** Schema layer сохраняет enum/format/pattern/min/max/nullable. Generated runtime исполняет подтверждённые mappings, `required_if`, composite projection и точный major→minor transform через Rational arithmetic. [`review_regressions_test.rb`](test/generator/review_regressions_test.rb) проверяет explicit nullable `nil` против отсутствующего key, optional omission, `false`, nested required, open maps и whole-array projection; [`runtime_review_test.rb`](test/generator/runtime_review_test.rb) — decimal amount и нецелые minor units. Полный runtime JSON Schema validator и per-item host paths вида `items[].field` пока не реализованы.

### E4. Универсальность — 15

**E4.1 — разные спецификации, 7.** [NovaPay YAML](examples/provider_api.yaml), [transfer JSON](examples/alt_transfer_provider.json) и [withdrawal YAML](examples/alt_withdrawal_provider.yaml) различаются версией/форматом, endpoint и field names, набором методов, API key/Bearer/Basic, server variables, nested responses/callbacks, наличием `operationId` и signature encoding. [`demo_test.rb`](test/demo_test.rb), [`manifest_builder_test.rb`](test/analyzer/manifest_builder_test.rb) и [`artifact_bundle_test.rb`](test/generator/artifact_bundle_test.rb) проводят их через один pipeline. Два альтернативных входа — самостоятельные test fixtures, а не production-подключения к публичным провайдерам.

**E4.2 — отсутствие provider hardcode, 5.** Parser строит Generic IR, analyzers — manifest, generators читают только final manifest. [`artifact_bundle_test.rb`](test/generator/artifact_bundle_test.rb), тест `test_bundle_can_be_built_from_serialized_manifest_without_openapi`, заменяет parser на исключение и всё равно получает bundle. `generate --manifest` воспроизводит эту границу через CLI. Отсутствие имени NovaPay в `lib/` — дополнительная проверка, но основное доказательство даёт dependency boundary и alternative runtime tests.

**E4.3 — расширение и unsupported, 3.** Правила разделены по предметным analyzers, неоднозначность исправляется versioned override без provider-ветки в core, extra operations попадают в `unsupported_operations`, missing capabilities — в report и `unavailable_fixtures`. [`operation_classifier_test.rb`](test/analyzer/operation_classifier_test.rb) проверяет unrelated/ambiguous operations; [`applier_test.rb`](test/overrides/applier_test.rb) — пересчёт capability после intent override и строгую validation. Путь расширения по слоям описан в [MODULE_MAP.md](MODULE_MAP.md). Пять payout capability slots сейчас фиксированы; новая доменная capability потребует согласованного изменения нескольких слоёв.

### E5. Использование и документация — 15

**E5.1 — понятный последовательный процесс, 6.** [`bin/integrate`](bin/integrate) поддерживает `inspect`, `analyze`, `generate`; [`bin/demo`](bin/demo) даёт один воспроизводимый прогон; [`bin/serve`](bin/serve) запускает локальный UI поверх того же Ruby backend. [`cli_test.rb`](test/cli_test.rb), [`demo_test.rb`](test/demo_test.rb), [`application_test.rb`](test/web/application_test.rb) и [`entrypoints_test.rb`](test/entrypoints_test.rb) проверяют flow и no-overwrite. В review отдельно пройдены Windows root launch в пути с кириллицей/пробелами и настоящий HTTP generation/download. Чистая установка Ruby и gems с пустого cache не входила в этот smoke; запуск Unicode-скрипта из чужого cwd не поддержан.

**E5.2 — инструкция интегратору, 5.** [`DocumentationGenerator`](lib/integration_generator/generator/documentation_generator.rb) создаёт `INTEGRATION.md` с host service contract, гарантированными operation fields, servers, auth ENV, mappings, statuses, error symbols, callback helpers и manual TODO. [`FixturesGenerator`](lib/integration_generator/generator/fixtures_generator.rb) предпочитает OpenAPI examples, помечает synthetic values и фиксирует ожидаемый `approve_operation` / `reject_operation`. Generated инструкция пока на английском; fixtures — не generated RSpec.

**E5.3 — понятный результат и ошибки, 4.** [`DiagnosticRemediation`](lib/integration_generator/diagnostic_remediation.rb) разделяет `reviewable`, `manual_configuration`, `unsupported` и `invalid_spec`. Только первая группа ведёт в overrides. `oneOf` объясняется как неподдержанная конструкция, показывает исходную строку и не предлагает ложное исправление; callback secret ведёт в настройку подключения. Повторная нормализация referenced schema не дублирует одну диагностику, а broken `$ref` ведёт к точному вхождению target. Неоднозначный source location не вызывает ошибочного перехода. Ruby и frontend tests фиксируют все четыре категории и безопасный fallback неизвестного кода.

### E6. Качество реализации — 10

**E6.1 — структура и компоненты, 6.** Каталоги `openapi`, `ir`, `analyzer`, `provider_ir`, `overrides`, `generator`, `web` имеют разные контракты. Один final manifest служит всем четырём содержательным генераторам; `ArtifactBundle` отделён от `OutputWriter`. [`artifact_bundle_test.rb`](test/generator/artifact_bundle_test.rb) проверяет deterministic и manifest-only generation, [`cli_test.rb`](test/cli_test.rb) — сохранение точного final manifest. Полная карта обязанностей, связей, тестов и extension recipes — [MODULE_MAP.md](MODULE_MAP.md). Крупные `Overrides::Applier` и inline service template остаются осознанным техническим долгом, а не скрываются за числом каталогов.

**E6.2 — ошибки разбора и генерации, 4.** [`Loader`](lib/integration_generator/openapi/loader.rb), [`DocumentValidator`](lib/integration_generator/openapi/document_validator.rb), [`RefResolver`](lib/integration_generator/openapi/ref_resolver.rb), [`ProviderIR::Manifest`](lib/integration_generator/provider_ir/manifest.rb), [`ArtifactBundle`](lib/integration_generator/generator/artifact_bundle.rb) и [`OutputWriter`](lib/integration_generator/generator/output_writer.rb) проверяют вход и результат на последовательных границах. Writer использует lock/staging, запрещает overwrite, запускает внешний `ruby -c` и публикует каталог только после успеха. [`output_writer_test.rb`](test/generator/output_writer_test.rb), [`runtime_validation_test.rb`](test/provider_ir/runtime_validation_test.rb) и negative tests в [`test/openapi`](test/openapi) проверяют отсутствие частичного результата и malformed manifest/auth. Полная semantic validation любого hand-edited manifest и context-aware Markdown escaping не заявляются.

## Техническая детализация задания

Техническая таблица задания раскрывает те же свойства мельче. Её строки арифметически дают 103, хотя в одной версии напечатан итог 100; проект не нормализует и не переоценивает эту шкалу. Каждая строка ниже ведёт к экспертной карточке с кодом, тестом и границей.

| Технический ID | Где проверять | Технический ID | Где проверять |
|---|---|---|---|
| T1.1 методы API | E1.1 | T1.2 request/response parameters | E1.1 |
| T1.3 auth requirements | E1.2 | T1.4 statuses/errors | E1.2, E2.2 |
| T1.5 webhook/conditions | E1.3 | T2.1 BaseService-style service | E2.1, E2.3 |
| T2.2 request dispatch | E2.1 | T2.3 status retrieval/handling | E2.2, E3.1 |
| T2.4 responses/errors | E2.2 | T2.5 incoming notifications | E2.3 |
| T2.6 connection config | E2.3 | T3.1 status mapping | E3.1 |
| T3.2 field mapping | E3.1 | T3.3 formats/units | E3.2 |
| T3.4 required/optional | E3.2 | T4.1 differing specs | E4.1 |
| T4.2 provider-neutral generation | E4.2 | T4.3 extensible rules/templates | E4.3, E6.1 |
| T4.4 unsupported/ambiguous reporting | E4.3, E5.3 | T5.1 setup/auth docs | E5.2 |
| T5.2 methods/status/errors docs | E5.2 | T5.3 `fixtures.json` | E5.2 |
| T6.1 launch path | E5.1 | T6.2 one sequential process | E5.1 |
| T6.3 understandable output/errors | E5.3 | T7.1 architecture/readability | E6.1 |
| T7.2 parse/generation error handling | E6.2 | T7.3 run/setup instruction | E5.1, E5.2 |

## Прицельные команды

Полная suite удобна для итоговой проверки. Если нужно изолировать конкретный слой:

```powershell
# OpenAPI / Generic IR
bundle exec ruby -Itest test/openapi/parser_test.rb
bundle exec ruby -Itest test/openapi/schema_parser_test.rb
bundle exec ruby -Itest test/openapi/ref_resolver_test.rb

# Semantic analysis / overrides / manifest validation
bundle exec ruby -Itest test/analyzer/manifest_builder_test.rb
bundle exec ruby -Itest test/analyzer/review_contracts_test.rb
bundle exec ruby -Itest test/overrides/applier_test.rb
bundle exec ruby -Itest test/provider_ir/runtime_validation_test.rb

# Generated runtime and artifacts
bundle exec ruby -Itest test/generator/generated_service_contract_test.rb
bundle exec ruby -Itest test/generator/runtime_review_test.rb
bundle exec ruby -Itest test/generator/alt_withdrawal_service_contract_test.rb
bundle exec ruby -Itest test/generator/review_regressions_test.rb
bundle exec ruby -Itest test/generator/artifact_bundle_test.rb
bundle exec ruby -Itest test/generator/output_writer_test.rb

# CLI and local web backend
bundle exec ruby -Itest test/cli_test.rb
bundle exec ruby -Itest test/web/application_test.rb
bundle exec ruby -Itest test/web/server_test.rb
```

Node.js нужен только для development-теста frontend logic: `node --test test/web/frontend_test.js`. Запуск продукта, CLI и локального UI от Node не зависят.

## Сравнение трёх входов

| Свойство | Canonical NovaPay | Alternative transfer | Alternative withdrawal |
|---|---|---|---|
| Файл | YAML, OpenAPI 3.0.3 | JSON, OpenAPI 3.1 | YAML, OpenAPI 3.0.3 |
| Терминология | payouts | transfers | withdrawals |
| Auth | API key header | Bearer | Basic |
| Capabilities после review | 5 | 2 | 5 |
| Response shape | top-level id/status | другие имена полей | nested `data.transaction.*` |
| Webhook | HMAC-SHA256 hex | отсутствует | HMAC-SHA256 base64, nested payload |
| Review point | status/fields/amount/encoding | остаются mapping/amount gaps | endpoint без `operationId` подтверждается JSON override |

Transfer-вариант важен именно неполнотой: отсутствие методов не маскируется stub-реализацией. Withdrawal-вариант проверяет другую комбинацию сложностей, а не только замену слова `payout`.

## Границы готовности

- Поддерживается заявленный subset OpenAPI 3.x YAML/JSON с local acyclic refs. Не заявляются remote/cyclic refs, advanced composition/discriminator, OpenAPI callbacks/top-level webhooks и arbitrary media serialization.
- OAuth/OIDC/mTLS execution, полный runtime JSON Schema validator, все `style/explode` варианты и per-array-element host mappings не реализованы.
- Production `Provider::BaseService`, operation model, HTTP transport и sandbox credentials не были предоставлены. Generated adapter использует документированный host/client boundary и локальный harness.
- Parsed callback сам не доказывает подпись; проверку делает host либо `process_verified_callback` с exact raw body. Secret остаётся ручной ENV-настройкой.
- Create возвращает нормализованный provider id через `success(result: ...)`; terminal fetch/callback меняют статус только BaseService-хелперами. Persistence выполняет платформа.
- Новые типы реквизитов требуют подтверждённой схемы host-модели и явного mapping; одинаковое имя provider field не считается доказательством.
- `ruby -c` подтверждает синтаксис; runtime contract tests подтверждают локальный adapter contract. Это не сертификат совместимости с production API.
- Две альтернативные спеки созданы для structural testing и не выдаются за реальные публичные provider integrations.
- Generated RSpec пока не создаётся. В проекте есть runtime contract tests генератора и JSON fixtures с provenance.
- Полная validation любого произвольно отредактированного manifest и полное контекстное Markdown escaping остаются в backlog.
- Локальный browser flow проверен во встроенном браузере Codex; фактический презентационный Chrome/проектор требует короткого smoke перед выступлением.

## Навигация по репозиторию

| Нужно понять | Документ |
|---|---|
| Установка, команды, UI, overrides и supported subset | [README.md](README.md) |
| Модули, их входы/выходы, зависимости и расширение | [MODULE_MAP.md](MODULE_MAP.md) |
| Пошаговая live-демонстрация и резервный CLI-сценарий | [DEMO_GUIDE.md](DEMO_GUIDE.md) |
| Связный текст третьего чекпоинта и отдельный будущий storyboard | [PRESENTATION_CONTENT.md](PRESENTATION_CONTENT.md) |

Рабочие планы, матрица ревью, review report и файлы из `docs/` не нужны для воспроизведения результата: все актуальные claims, команды, ссылки и границы собраны в этом руководстве. Внутренние материалы можно хранить локально вне judge-facing набора.
