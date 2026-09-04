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

## Требования

- Ruby 3.1 или новее;
- Bundler.

Проверка окружения:

```bash
ruby --version
bundle --version
```

Если Ruby установлен, но не добавлен в `PATH`, можно вызвать `ruby` и `bundle` по абсолютным путям либо временно расширить `PATH` только для текущего терминала.

## Установка и запуск

```bash
bundle install
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

`inspect` по умолчанию выводит Generic IR как JSON. `analyze` по умолчанию выводит финальный Integration Manifest как YAML. Флаг `--overrides` применим к `analyze` и к `generate --spec`; с `generate --manifest` он намеренно несовместим, потому что prebuilt manifest уже считается финальным контрактом. `generate` создаёт новый output-каталог с пятью проверенными артефактами:

```text
output/novapay/
  novapay_service.rb
  INTEGRATION.md
  compatibility_report.md
  fixtures.json
  integration_manifest.yml
```

Существующий output-каталог намеренно не перезаписывается: команда завершится с `[OUTPUT_EXISTS]`. Выберите новый путь либо осознанно удалите старый generated-каталог.

## Демо для оценки — одна команда

```powershell
bundle exec ruby bin/demo
```

Скрипт создаёт новый уникальный каталог внутри `output/`, не удаляя и не перезаписывая предыдущие результаты. Он через публичный CLI генерирует три bundle: канонический payout API, альтернативный transfer API и withdrawal API. В консоли видны честная review-точка `fetch_status: requires_review -> detected` после JSON override, различия API key/Bearer/Basic auth, число обнаруженных capabilities, итоговая readiness-оценка и успешный `ruby -c` каждого generated service.

Для фиксированного нового пути передайте отсутствующий каталог; повторный запуск с тем же путём безопасно завершится ошибкой:

```powershell
bundle exec ruby bin/demo --output output/presentation-run
```

Сценарий демонстрации привязан к критериям кейса. Пример репетиции на четыре минуты (длительность выступления уточняется отдельно):

| Время | Тезис и доказательство | Критерий экспертов |
|---|---|---|
| 0:00–0:30 | Из OpenAPI получаем заготовку payout-интеграции; показать официальный вход | Разбор API — 20 |
| 0:30–1:20 | Запустить `bin/demo`, открыть service, показать запрос, auth и обработку ответа | Генерация сервиса — 25 |
| 1:20–2:10 | Показать amount conversion, status mappings и условный `bank_code`; неподтверждённые статусы остаются `unknown` | Преобразование данных — 15 |
| 2:10–3:00 | Сравнить три спеки и `fetch_status: requires_review -> detected` после JSON override | Универсальность — 15 |
| 3:00–4:00 | Открыть docs/fixtures/report, показать тесты и manifest как общий источник артефактов | Понятность — 15; качество реализации — 10 |

Эти числа — веса критериев, а не самооценка решения. Время ручной production-интеграции не измерялось: демонстрация доказывает генерацию и локальные проверки заготовки. `NEEDS REVIEW` из-за callback secret объясняем как явную настройку credentials. Планируемый frontend покажет этот же сценарий: загрузка спеки → обнаруженные возможности → review/override → скачивание артефактов.

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

Generated service безопасно блокирует неподтверждённые mappings и неполную webhook verification. Параметры `allow_unreviewed: true` / `allow_unverified: true` предназначены только для явного inspection/demo, не для production.

Generic status synonyms сохраняются в manifest как предложения, но generated runtime использует их только после подтверждения override. До подтверждения runtime возвращает `unknown`, а fixtures не обещают соответствующий normalized status. Для старых manifests это правило также определяется по `provenance: default_rule`.

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
- unresolved: callback secret по-прежнему отсутствует в OpenAPI и должен прийти из `NOVAPAY_WEBHOOK_SECRET`; callback всё равно требует точный raw body и signature header.

Финальный `integration_manifest.yml` хранит `overrides.applied_changes` с before/after, source/reason и `resolved_warnings`. Warning исчезает из unresolved-списка только по точному селектору `code + location`, связанному с реально применённым изменением; остальные warnings сохраняются.

Override-файл имеет независимую версию `override_version: "1.0"`. Поддерживаемые sections:

- `operations` — intent по точному ключу `METHOD /path`;
- `status_mapping` — provider status → `approved`, `rejected`, `in_progress` или `unknown`;
- `field_mappings` — явный `operation.*` host source и `confirm: true`; body-field может быть добавлен по существующему пути request schema, даже если анализатор не узнал его имя;
- `transformations.amount` — provider unit, direction и положительный factor;
- `transformations.conditional_requirements` — проверяемый `required_if` по существующим request fields;
- `webhook.signature` — поддержанные algorithm/encoding и выбор объявленного header;
- `webhook.payload` — явные event/status/id/error paths из объявленной webhook schema;
- `resolve_warnings` — точные warning selectors, сохраняемые в audit.

Схема строгая: неизвестный ключ, operation, capability, field/status/warning или недопустимое значение завершают команду предметной ошибкой вида `[OVERRIDE_UNKNOWN_FIELD]` / `[OVERRIDE_INVALID_VALUE]`. `Idempotency-Key` становится подтверждённым только при явном host mapping, например `source: operation.idempotency_key`.

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

## Архитектура

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

Unsupported schema/auth/callback constructs становятся warnings. Broken, external или cyclic `$ref` завершают parsing предметной ошибкой. Обычный `POST /webhooks/...` остаётся стандартной HTTP operation и уже извлекается.

## Тесты

```bash
bundle exec rake test
```

Тесты покрывают parser, deterministic semantic rules, ambiguity guards, status/error/webhook/field extraction, manifest validation, все четыре generators, runtime request/response/callback contract, no-overwrite CLI и три demo specs. Перед публикацией writer отдельно запускает `ruby -c` для generated service.

## Demo specs

- `examples/provider_api.yaml` — каноническая NovaPay OpenAPI 3.0.3 из материалов хакатона. Исходный файл: `provider_api (1).yaml`, SHA-256 `415F50EE36FB331DFAB49CEED0E8ED3B0EBE16053D7E00DBABD32282F4396551`.
- `examples/alt_transfer_provider.json` — самостоятельная OpenAPI 3.1 fixture с другими endpoint/field names, Bearer auth, server variables и `application/problem+json`.
- `examples/alt_withdrawal_provider.yaml` — самостоятельная OpenAPI 3.0.3 fixture с withdrawal terminology, Basic auth, nested response/webhook payloads, endpoint без `operationId` и conditional beneficiary fields. `examples/alt_withdrawal_overrides.json` демонстрирует тот же generic override contract в JSON.

## Следующий этап

После review-исправлений и one-command demo следующий этап — выразительный frontend для показа manifest/review/артефактов и презентация по критериям выше. Основной pipeline остаётся Ruby. Generated service spec, расширение OpenAPI subset и глубокая декомпозиция отложены до завершения демонстрационного сценария.
