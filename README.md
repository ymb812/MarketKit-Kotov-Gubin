# HackGenesis Provider Integration Generator

Автономный Ruby-инструмент, который преобразует OpenAPI платёжного провайдера в нормализованную модель и reviewable Integration Manifest, а затем генерирует payout adapter под контракт `Provider::BaseService`, документацию и fixtures.

Текущий завершённый pipeline:

```text
OpenAPI YAML/JSON
  -> validation + local $ref resolution
  -> provider-neutral Generic IR
  -> deterministic semantic analysis
  -> inferred Integration Manifest
  -> validated generic overrides + provenance/audit
  -> final Integration Manifest (YAML/JSON)
  -> Ruby service + integration docs + fixtures + compatibility report
```

Runtime не использует LLM или внешние API. Полный pipeline уже генерирует обязательные артефакты из manifest.

## Как проверять репозиторий

| Задача | Куда перейти |
|---|---|
| Быстро запустить проект и получить результат | раздел «Установка и первый полный запуск» ниже |
| Проверить каждый критерий по коду и тестам | [JURY_GUIDE.md](JURY_GUIDE.md) |
| Проверить Adyen и Airwallex из официальных OpenAPI | [REAL_PROVIDER_EXAMPLES.md](REAL_PROVIDER_EXAMPLES.md) |
| Увидеть покрытие 25 баллов generated service | [CRITERION_2_TEST_EVIDENCE.md](CRITERION_2_TEST_EVIDENCE.md) |
| Разобраться в слоях, связях и точках расширения | [MODULE_MAP.md](MODULE_MAP.md) |
| Взять готовый связный текст третьего чекпоинта | [PRESENTATION_CONTENT.md](PRESENTATION_CONTENT.md) |
| Провести live demo через локальный UI | [DEMO_GUIDE.md](DEMO_GUIDE.md) |

`JURY_GUIDE.md` — основная точка входа для оценки: там есть короткий reproducible flow, все 16 экспертных подкритериев, технический crosswalk, точные ссылки на реализацию/тесты и границы заявленного результата.

Минимальный маршрут жюри: README → [критерии](JURY_GUIDE.md) → [реальные провайдеры](REAL_PROVIDER_EXAMPLES.md) → [тестовые доказательства сервиса](CRITERION_2_TEST_EVIDENCE.md) → [архитектура](MODULE_MAP.md). Доклад и видеосценарий — исторические вспомогательные материалы завершённого чекпоинта.

## Требования

- Ruby 3.1 или новее;
- Bundler.

Проверка окружения:

```bash
ruby --version
bundle --version
```

Если Ruby установлен, но не добавлен в `PATH`, можно вызвать `ruby` и `bundle` по абсолютным путям либо временно расширить `PATH` только для текущего терминала.

## Установка и первый полный запуск

Команды выполняются из корня репозитория. На Windows Ruby может искажать кириллицу в пути скрипта; точки запуска используют существующий путь к проекту и UTF-8 `Dir.pwd` как резерв. При запуске из каталога с кириллицей сначала перейдите в корень проекта. Переименование папки в ASCII остаётся обходным вариантом для старой версии кода, но `-Ilib` само по себе не устраняет эту проблему.

Канонический `examples/provider_api.yaml` должен сохранять LF: правило находится в `.gitattributes`. Оно важно при `core.autocrlf=true`, поскольку manifest хранит SHA-256 исходных байтов. При несовпадении хэша проверьте `git ls-files --eol examples/provider_api.yaml` и локальные изменения; не заменяйте ожидаемый хэш в тесте. Правило должно входить в передаваемый репозиторий, а не оставаться только локальным файлом.

```powershell
bundle install
bundle exec ruby bin/demo
```

`bin/demo` создаёт уникальный каталог в `output/`, проводит canonical, transfer и withdrawal specs через публичный CLI, показывает review transition, генерирует три bundle и запускает `ruby -c` для каждого service. Внутри каждого provider-каталога находятся пять файлов:

```text
output/demo-<id>/novapay/
  novapay_service.rb
  INTEGRATION.md
  compatibility_report.md
  fixtures.json
  integration_manifest.yml
```

Canonical bundle после override сохраняет `NEEDS REVIEW` из-за callback secret: это ручная ENV-настройка, которой нет в OpenAPI, а не скрытая ошибка генерации. Ожидаемые 5/2/5 capabilities и порядок чтения файлов описаны в [JURY_GUIDE.md](JURY_GUIDE.md).

Отдельная проверка на двух официальных публичных OpenAPI:

```powershell
bundle exec ruby bin/real_provider_demo
```

Она генерирует и исполняет через recording client сервисы для **Adyen Transfers API v4** и **Airwallex Payouts / Transfers API**. Source repository, commit, upstream SHA-256, сфокусированные snapshots, review overrides, точные assertions и граница между offline contract test и live sandbox описаны в [REAL_PROVIDER_EXAMPLES.md](REAL_PROVIDER_EXAMPLES.md).

## Отдельные команды CLI

```bash
bundle exec ruby bin/integrate --help
bundle exec ruby bin/integrate inspect --spec examples/provider_api.yaml
bundle exec ruby bin/integrate inspect --spec examples/alt_transfer_provider.json --format yaml
bundle exec ruby bin/integrate analyze --spec examples/provider_api.yaml --provider novapay
bundle exec ruby bin/integrate analyze --spec examples/provider_api.yaml --provider novapay --overrides examples/novapay_overrides.yaml
bundle exec ruby bin/integrate analyze --spec examples/alt_transfer_provider.json --format json
bundle exec ruby bin/integrate analyze --spec examples/alt_withdrawal_provider.yaml --provider alt_withdrawal --overrides examples/alt_withdrawal_overrides.json
bundle exec ruby bin/integrate generate --spec examples/provider_api.yaml --provider novapay --output output/novapay
bundle exec ruby bin/integrate generate --spec examples/provider_api.yaml --provider novapay --overrides examples/novapay_overrides.yaml --output output/novapay_overridden
bundle exec ruby bin/integrate generate --spec examples/alt_withdrawal_provider.yaml --provider alt_withdrawal --overrides examples/alt_withdrawal_overrides.json --output output/alt_withdrawal
```

`inspect` по умолчанию выводит Generic IR как JSON. `analyze` по умолчанию выводит финальный Integration Manifest как YAML. Флаг `--overrides` применим к `analyze` и к `generate --spec`; с `generate --manifest` он намеренно несовместим, потому что prebuilt manifest уже считается финальным контрактом. Существующий output-каталог намеренно не перезаписывается: команда завершится с `[OUTPUT_EXISTS]`. Выберите новый путь либо осознанно удалите старый generated-каталог.

## Payout Studio — локальный frontend

```powershell
bundle exec ruby bin/serve
```

Откройте `http://127.0.0.1:9292` в браузере. Другой порт: `bundle exec ruby bin/serve --port 9393`. Остановка — `Ctrl+C` в терминале сервера.

UI работает поверх того же Ruby pipeline; JavaScript только отображает manifest и отправляет локальные запросы. WEBrick устанавливается через `bundle install`; Node.js, сборка frontend, CDN и внешние API не нужны. Сервер слушает только `127.0.0.1`; это однопользовательский локальный инструмент, не публичный hosted service.

Подробный сценарий: [DEMO_GUIDE.md](DEMO_GUIDE.md). Готовый устный текст третьего чекпоинта и монтажная карта к этому сценарию: [PRESENTATION_CONTENT.md](PRESENTATION_CONTENT.md). Оба документа входят в Git.

Короткий сценарий показа:

1. Выберите canonical payout API. Покажите capabilities, endpoints, confidence/evidence и предупреждения.
2. Нажмите «Открыть overrides», просмотрите YAML, включите «Применить overrides при следующем анализе», затем нажмите «Анализировать». В обзоре предупреждения сокращаются с 8 до 1; callback secret остаётся явной runtime-настройкой.
3. Откройте «Преобразования» и «Подключение»: ×100, подтверждённые статусы, host/provider fields, signature header/encoding и HTTP errors.
4. Нажмите «Сгенерировать пакет». Пять файлов доступны в preview, по одному и архивом `.tar.gz`; копия всегда сохраняется в новом `output/web-<id>/` после `ruby -c`.
5. Переключитесь на transfer API (JSON, Bearer, 2 capabilities) и withdrawal API (YAML, Basic, nested payload). У withdrawal JSON override переводит capabilities 4 → 5, warnings 11 → 1.

Свой файл: в «Обзоре» справа от «Входная спецификация» нажмите «Загрузить свою OpenAPI ↑». Можно также загрузить YAML/JSON в панели OpenAPI раздела «Спецификация» или вставить текст в редактор. Изменение входа сбрасывает старый результат; генерация доступна только после нового успешного анализа. Лимит загружаемого файла — 1 МБ, всего JSON-запроса — 2 МБ. Не помещайте реальные credentials в demo-spec: секреты нужны в ENV host-приложения, а не генератору.

Загрузка файлов и реальные скачивания проверены во встроенном браузере Codex. Ссылки на скачивание действуют до перезапуска сервера; затем сгенерируйте пакет заново. Файлы в `output/web-<id>/` сохраняются. Экранное видео третьего чекпоинта уже записано и показано; CLI-демо ниже остаётся воспроизводимым сценарием для проверки кода.

## Демо для оценки — одна команда

```powershell
bundle exec ruby bin/demo
```

Скрипт создаёт новый уникальный каталог внутри `output/`, не удаляя и не перезаписывая предыдущие результаты. Он через публичный CLI генерирует три bundle: канонический payout API, альтернативный transfer API и withdrawal API. В консоли видны честная review-точка `fetch_status: requires_review -> detected` после JSON override, различия API key/Bearer/Basic auth, число обнаруженных capabilities, итоговая readiness-оценка и успешный `ruby -c` каждого generated service.

Для фиксированного нового пути передайте отсутствующий каталог; повторный запуск с тем же путём безопасно завершится ошибкой:

```powershell
bundle exec ruby bin/demo --output output/presentation-run
```

Сценарий экранного видео и устного рассказа для третьего чекпоинта привязан к критериям кейса. Регламент — **8 минут**; точная раскладка до 7:35 и 25-секундный резерв находятся в [DEMO_GUIDE.md](DEMO_GUIDE.md). Порядок кадров:

| Кадр | Тезис и доказательство | Критерий экспертов |
|---|---|---|
| 1 | Из OpenAPI получаем заготовку payout-интеграции; показать официальный вход | Разбор API — 20 |
| 2 | Открыть service, показать запрос, auth и обработку ответа | Генерация сервиса — 25 |
| 3 | Показать amount conversion, status mappings и условный `bank_code`; неподтверждённые статусы остаются `unknown` | Преобразование данных — 15 |
| 4 | Сравнить три спеки и `fetch_status: requires_review -> detected` после JSON override | Универсальность — 15 |
| 5 | Открыть docs/fixtures/report, показать тесты и manifest как общий источник артефактов | Понятность — 15; качество реализации — 10 |

Эти числа — веса критериев, а не самооценка решения. Время ручной production-интеграции не измерялось: демонстрация доказывает генерацию и локальные проверки заготовки. `NEEDS REVIEW` из-за callback secret объясняем как явную настройку credentials. Payout Studio показывает тот же pipeline через визуальные экраны; CLI можно держать открытым как резерв.

## Быстрый запуск перед показом

На этой машине Ruby находится в `C:\Ruby34-x64\bin`. В новом PowerShell:

```powershell
$env:Path = "C:\Ruby34-x64\bin;$env:Path"
bundle check
bundle exec rake test
bundle exec ruby bin/integrate generate --spec examples/provider_api.yaml --provider novapay --overrides examples/novapay_overrides.yaml --output output/checkpoint_novapay
ruby -c output/checkpoint_novapay/novapay_service.rb
```

Дальше показать в таком порядке:

1. `examples/provider_api.yaml` — официальный вход кейса.
2. `output/checkpoint_novapay/integration_manifest.yml` — все 5 capabilities, confidence/evidence, auth, mappings и честные warnings.
3. `output/checkpoint_novapay/compatibility_report.md` — компактная readiness-картина по capabilities, auth, mappings, status, amount и webhook.
4. `output/checkpoint_novapay/novapay_service.rb` — `Provider::BaseService`, request/auth/amount/status/error/callback logic и явный host-client boundary.
5. `output/checkpoint_novapay/INTEGRATION.md` — готовая инструкция интегратору.
6. `output/checkpoint_novapay/fixtures.json` — реальные OpenAPI examples и помеченные schema-generated fixtures.

Затем одной командой показать универсальность:

```powershell
bundle exec ruby bin/integrate generate --spec examples/alt_transfer_provider.json --provider alt_transfer --output output/checkpoint_alt
ruby -c output/checkpoint_alt/alt_transfer_service.rb
```

В alternative output обратить внимание на `/transfers`, Bearer auth, другие field names и на то, что отсутствующие cancel/webhook/balance не выдуманы, а явно помечены как missing.

Третий пример проверяет другой набор структурных различий: YAML, withdrawal terminology, Basic auth, endpoint без `operationId`, nested responses, другое имя webhook и JSON override:

```powershell
bundle exec ruby bin/integrate generate `
  --spec examples/alt_withdrawal_provider.yaml `
  --provider alt_withdrawal `
  --overrides examples/alt_withdrawal_overrides.json `
  --output output/checkpoint_withdrawal
ruby -c output/checkpoint_withdrawal/alt_withdrawal_service.rb
```

После override все пять capabilities доступны, nested `data.transaction.id/state` нормализуются, webhook проверяется как HMAC-SHA256/base64, а `compatibility_report.md` оставляет callback secret явной runtime-настройкой. Composite host objects перед отправкой ограничиваются provider schema, поэтому внутренние поля не протекают в API payload.

Если каталоги от предыдущего прогона существуют, удаляйте только эти точные generated targets либо используйте новые имена. Для краткого доказательства manifest-first architecture можно сгенерировать второй bundle без исходного OpenAPI:

```powershell
bundle exec ruby bin/integrate generate --manifest output/checkpoint_novapay/integration_manifest.yml --output output/checkpoint_from_manifest
```

Generated service блокирует неподтверждённые mappings и неполную raw-body webhook verification. Параметры `allow_unreviewed: true` / `allow_unverified: true` предназначены только для явного inspection/demo, не для production.

По уточнённому контракту Q&A `create_request` отправляет запрос, разбирает ответ и возвращает `success(result: { id: provider_id })`; платформа сохраняет этот id как `provider_operation_key`. `fetch_status` и `process_callback` не возвращают новый статус в `result`: подтверждённые terminal statuses применяются через `approve_operation` / `reject_operation`, а in-progress/unknown не меняют операцию. `create_payout` сохранён как совместимый alias, а `build_provider_request` — как отдельная граница для inspection и contract tests.

Гарантированные входы host operation: `id`, `amount`, `payout_requisite`. Для СБП canonical mapping читает `payout_requisite.sbp.phone/bank_code/bank_name`, для карты — плоский `payout_requisite.card_number`. Неизвестный обязательный реквизит не связывается с одноимённым ключом автоматически: manifest оставляет TODO до явного решения интегратора.

`process_callback(payload)` принимает parsed Hash после аутентификации на HTTP-границе хоста. `process_verified_callback(raw_body, headers:)` проверяет HMAC по исходным байтам и разбирает именно подписанное тело; повторная сериализация Hash для проверки запрещена. Статус берётся из подтверждённого payload mapping, event его не переопределяет. HTTP errors преобразуются в стандартные платформенные symbols (`unauthorized`, `too_many_requests`, `unprocessable_entity` и другие), а `amount_limit_exceeded` отклоняет конкретную выплату как validation failure.

Generic status synonyms сохраняются в manifest как предложения, но generated runtime использует их только после подтверждения override. До подтверждения terminal helper не вызывается, а fixtures не обещают смену статуса. Для старых manifests это правило также определяется по `provenance: default_rule`.

Проекция composite values — консервативная политика adapter: именованные properties разрешены; явный `additionalProperties: true` разрешает остальные ключи, schema-valued `additionalProperties` проецирует их рекурсивно. Если `additionalProperties` не задан, adapter переносит только именованные properties; это политика экспорта host-модели, а не утверждение, что OpenAPI запрещает дополнительные свойства. У object без properties/явной политики и array без items граница неизвестна — generated service выдаёт ошибку. Обязательные поля проверяются на итоговом body после parent/child mappings. Per-item пути вида `items[].field` пока требуют отдельной поддержки; whole-array mapping доступен при определённой items schema.

## Overrides: before / after

Без override OpenAPI остаётся единственным источником структурных фактов. Анализатор уверенно находит endpoints, API key, amount в копейках и HMAC-SHA256, но честно помечает как review-required низкоуверенные host mappings, idempotency source, текстовые `required_if`, generic status synonyms и неизвестный webhook encoding:

```powershell
bundle exec ruby bin/integrate analyze --spec examples/provider_api.yaml --provider novapay --format yaml
```

Canonical data-only override подтверждает или уточняет только эти решения, не добавляя provider branches в Ruby-core:

```powershell
bundle exec ruby bin/integrate analyze `
  --spec examples/provider_api.yaml `
  --provider novapay `
  --overrides examples/novapay_overrides.yaml `
  --format yaml

bundle exec ruby bin/integrate generate `
  --spec examples/provider_api.yaml `
  --provider novapay `
  --overrides examples/novapay_overrides.yaml `
  --output output/novapay_overridden
```

После override:

- inferred: OpenAPI operations/contracts, auth, response/error shapes и остальные структурные факты;
- overridden: operation intent confirmation, все пять status mappings, amount unit/direction/factor, необходимые request mapping sources, `required_if` и webhook `hmac_sha256/hex`;
- unresolved: callback secret по-прежнему отсутствует в OpenAPI и должен прийти из `NOVAPAY_WEBHOOK_SECRET` для `process_verified_callback`; этот путь требует точный raw body и signature header. Parsed `process_callback` оставляет аутентификацию хосту.

Финальный `integration_manifest.yml` хранит `overrides.applied_changes` с before/after, source/reason и `resolved_warnings`. Warning исчезает из unresolved-списка только по точному селектору `code + location`, связанному с реально применённым изменением; остальные warnings сохраняются.

Override-файл имеет независимую версию `override_version: "1.0"`. Поддерживаемые sections:

- `operations` — intent по точному ключу `METHOD /path`;
- `status_mapping` — provider status → `approved`, `rejected`, `in_progress` или `unknown`;
- `field_mappings` — явный `operation.*` host source, логический `request_method` либо scalar `value`, плюс `confirm: true`; body-field можно добавить только по существующему пути request schema;
- `transformations.amount` — provider unit, direction и положительный factor;
- `transformations.conditional_requirements` — проверяемый `required_if` по существующим request fields;
- `webhook.signature` — поддержанные algorithm/encoding и выбор объявленного header;
- `webhook.payload` — явные event/status/id/error paths из объявленной webhook schema;
- `resolve_warnings` — точные warning selectors, сохраняемые в audit.

Схема строгая: неизвестный ключ, operation, capability, field/status/warning или недопустимое значение завершают команду предметной ошибкой вида `[OVERRIDE_UNKNOWN_FIELD]` / `[OVERRIDE_INVALID_VALUE]`. `source` и `value` взаимоисключающие. В canonical override `recipient.type` берётся из `request_method`, валюта задана константой `RUB`, а idempotency header — из гарантированного `operation.id`.

Пример ошибки:

```text
[REF_NOT_FOUND] Reference target does not exist at #/components/schemas/Missing
```

## Что содержит Generic IR

- OpenAPI version и базовый `info`;
- servers и server variables;
- root/operation security requirements;
- API key, HTTP Bearer и HTTP Basic security schemes;
- HTTP operations, включая path-level и operation-level parameters;
- JSON request bodies, schemas, examples и required fields;
- responses, response headers и media types;
- component schemas с основными constraints;
- machine-readable warnings для обнаруженных, но пока неподдержанных конструкций.

Parser не присваивает операциям payout-intents и не содержит provider-specific branches. Semantic analyzers читают только Generic IR.

## Что содержит Integration Manifest

- source SHA-256 и версии analyzer/ruleset;
- классифицированные operations с intent, confidence и evidence;
- capability resolution для `create_payout`, `fetch_status`, `cancel_payout`, `webhook`, `balance`;
- default и per-operation auth;
- status mapping с provenance и безопасным `unknown/requires_review`;
- HTTP errors, отдельно schema/example provider codes;
- webhook signature/payload/event candidates;
- field mappings для create/fetch/cancel и amount/conditional transformations;
- override provenance, applied changes и resolved warning audit;
- missing/ambiguous/unsupported capabilities и machine-readable warnings.

Порог classifier: confidence от `0.8` принимается автоматически, `0.5..0.79` требует review, ниже `0.5` операция остаётся unsupported. Это детерминированные эвристики, а не provider-specific код.

## Архитектура и карта модулей

Подробная карта ответственности, входов/выходов, разрешённых зависимостей, тестов и extension recipes находится в [MODULE_MAP.md](MODULE_MAP.md). Критичный инвариант: generators получают только final Integration Manifest и не читают исходный OpenAPI.

```text
bin/integrate
  -> IntegrationGenerator::CLI
  -> OpenAPI::Loader
  -> OpenAPI::DocumentValidator
  -> OpenAPI::RefResolver
  -> OpenAPI::Parser + SchemaParser
  -> IR::Document / Operation / Schema / Warning
  -> Analyzer rules
  -> inferred ProviderIR::Manifest
  -> Overrides::Loader + Overrides::Applier
  -> final ProviderIR::Manifest
  -> Service / Documentation / Fixtures / Compatibility generators
  -> validated output bundle
```

Основная точка программного входа:

```ruby
document = IntegrationGenerator::OpenAPI::Parser.parse_file("examples/provider_api.yaml")
manifest = IntegrationGenerator::Analyzer::ManifestBuilder.new(
  document,
  provider_slug: "novapay"
).build
overrides = IntegrationGenerator::Overrides::Loader.load_file("examples/novapay_overrides.yaml")
final_manifest = IntegrationGenerator::Overrides::Applier.new(
  manifest,
  overrides,
  path: "examples/novapay_overrides.yaml"
).apply
serializable_hash = final_manifest.to_h
```

`ProviderIR::Manifest` валидирует обязательные sections, ссылки capabilities на operations и override audit. Только финальный manifest является input для service/docs/fixtures/compatibility generators; генераторы не читают OpenAPI, Generic IR или override-файл. CLI поддерживает `generate --manifest`, чтобы эту границу можно было проверить отдельно.

## Поддерживаемое подмножество OpenAPI

Parser поддерживает OpenAPI 3.x YAML/JSON, local JSON Pointer references `#`/`#/...`, servers, paths, стандартные HTTP methods, parameters, JSON request/response content, headers, examples, component schemas и security schemes.

Соседние поля рядом с `$ref` детерминированно накладываются поверх resolved object. Path-level parameters объединяются с operation-level parameters по паре `[in, name]`; operation-level значение имеет приоритет. Path parameters всегда нормализуются как required.

Сейчас явно не поддерживаются:

- external/remote `$ref`;
- циклические/recursive schemas;
- multi-type unions кроме `T | null`, а также `allOf`, `oneOf`, `anyOf`, `not`, discriminator и JSON Schema conditionals;
- OpenAPI callbacks и top-level `webhooks` keyword;
- исполнение OAuth/OpenID/mTLS авторизации;
- exact production `Provider::BaseService`, operation model и HTTP client contract — generated service предоставляет документированный adapter boundary.

Runtime также не является полным JSON Schema/HTTP serializer: scalar enum/pattern/min/max извлекаются, но не все исполняются; `style/explode` и произвольные media types требуют host transport. Body mappings генерируются для create; fetch/cancel используют parameters, balance — адрес/auth без пользовательских mappings. Application error внутри HTTP 2xx не превращается автоматически в failure. При нескольких одинаково подходящих response id/status paths выбирается детерминированный кандидат, поэтому такие response schemas требуют ручной проверки manifest. Полная совместимость подобных вариантов не заявляется.

Для canonical card flow структурная схема `Recipient` требует `phone` при любом `type`; adapter сохраняет это требование. Тест карты проверяет `card_number` вместе с заполненным SBP phone, а не полноценную card-only операцию. Менять официальную OpenAPI или угадывать другую бизнес-семантику генератор не должен.

Публичный `failure` содержит platform code/message; детали provider code/message и `Retry-After` доступны внутри нормализации и не возвращаются этим методом автоматически. Fetch terminal helpers получают host `operation.id`, callback helpers — provider id: точные production helper signatures должны быть согласованы при подключении хоста. Parsed callback не возвращает отдельный `signature_verification` marker; аутентификация является предусловием host boundary.

Unsupported schema/auth/callback constructs становятся warnings. В Payout Studio они разделены на `reviewable`, `manual_configuration`, `unsupported` и `invalid_spec`; только `reviewable` предлагает override. Для `oneOf` UI объясняет границу поддержки, показывает исходную строку и не обещает исправление через override. Broken, external или cyclic `$ref` завершают parsing предметной ошибкой. Обычный `POST /webhooks/...` остаётся стандартной HTTP operation и уже извлекается.

## Тесты

```bash
bundle exec rake test
```

Проверки frontend presentation logic (Node нужен только для этих dev-тестов):

```bash
node --test test/web/frontend_test.js
```

Тесты покрывают parser, deterministic semantic rules, ambiguity guards, status/error/webhook/field extraction, manifest validation, все четыре generators, runtime request/response/callback contract, no-overwrite CLI, три synthetic demo specs и два официальных real-provider snapshots. Перед публикацией writer отдельно запускает `ruby -c` для generated service. Точная матрица по 10+8+7 баллам generated service находится в [CRITERION_2_TEST_EVIDENCE.md](CRITERION_2_TEST_EVIDENCE.md).

## Demo specs

- `examples/provider_api.yaml` — каноническая NovaPay OpenAPI 3.0.3 из материалов хакатона. Исходный файл: `provider_api (1).yaml`, SHA-256 `415F50EE36FB331DFAB49CEED0E8ED3B0EBE16053D7E00DBABD32282F4396551`.
- `examples/alt_transfer_provider.json` — самостоятельная OpenAPI 3.1 fixture с другими endpoint/field names, Bearer auth, server variables и `application/problem+json`.
- `examples/alt_withdrawal_provider.yaml` — самостоятельная OpenAPI 3.0.3 fixture с withdrawal terminology, Basic auth, nested response/webhook payloads, endpoint без `operationId` и conditional beneficiary fields. `examples/alt_withdrawal_overrides.json` демонстрирует тот же generic override contract в JSON.
- `examples/real/adyen_transfer_v4.yaml` — сфокусированный snapshot официальной Adyen Transfers API v4 на закреплённом commit.
- `examples/real/airwallex_transfer.json` — сфокусированный snapshot официальной Airwallex Payouts / Transfers API на закреплённом commit.

Real-provider snapshots воспроизводятся командой `bundle exec ruby bin/refresh_real_examples`: загрузчик проверяет SHA-256 полного upstream-файла и сохраняет выбранные payout paths с транзитивно достижимыми local `$ref`. Обычный demo работает offline и не требует provider credentials.

## Статус

Третий чекпоинт пройден. Актуальная Ruby suite — **152 tests / 899 assertions**, без failures/errors/skips; frontend logic — 7/7. Помимо трёх synthetic demo specs, два официальных real-provider snapshots проходят generation, `ruby -c` и runtime contract tests. Основные документы для проверки кода: [JURY_GUIDE.md](JURY_GUIDE.md), [REAL_PROVIDER_EXAMPLES.md](REAL_PROVIDER_EXAMPLES.md), [CRITERION_2_TEST_EVIDENCE.md](CRITERION_2_TEST_EVIDENCE.md) и [MODULE_MAP.md](MODULE_MAP.md). Live sandbox calls без credentials не заявляются. Generated RSpec artifact, расширение OpenAPI subset и глубокая декомпозиция сохранены в backlog.
