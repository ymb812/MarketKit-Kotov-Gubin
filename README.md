# HackGenesis Provider Integration Generator

Автономный Ruby-инструмент, который преобразует OpenAPI платёжного провайдера в нормализованную модель и reviewable Integration Manifest, а затем генерирует payout adapter под контракт `Provider::BaseService`, документацию и fixtures.

Текущий завершённый pipeline:

```text
OpenAPI YAML/JSON
  -> validation + local $ref resolution
  -> provider-neutral Generic IR
  -> deterministic semantic analysis
  -> reviewable Integration Manifest (YAML/JSON)
  -> Ruby service + integration docs + fixtures
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
bundle exec ruby bin/integrate analyze --spec examples/alt_transfer_provider.json --format json
bundle exec ruby bin/integrate generate --spec examples/provider_api.yaml --provider novapay --output output/novapay
```

`inspect` по умолчанию выводит Generic IR как JSON. `analyze` по умолчанию выводит Integration Manifest как YAML. `generate` создаёт новый output-каталог с четырьмя проверенными артефактами:

```text
output/novapay/
  novapay_service.rb
  INTEGRATION.md
  fixtures.json
  integration_manifest.yml
```

Существующий output-каталог намеренно не перезаписывается: команда завершится с `[OUTPUT_EXISTS]`. Выберите новый путь либо осознанно удалите старый generated-каталог.

## Быстрый запуск перед показом

На этой машине Ruby находится в `C:\Ruby34-x64\bin`. В новом PowerShell:

```powershell
$env:Path = "C:\Ruby34-x64\bin;$env:Path"
bundle check
bundle exec rake test
bundle exec ruby bin/integrate generate --spec examples/provider_api.yaml --provider novapay --output output/checkpoint_novapay
ruby -c output/checkpoint_novapay/novapay_service.rb
```

Дальше показать в таком порядке:

1. `examples/provider_api.yaml` — официальный вход кейса.
2. `output/checkpoint_novapay/integration_manifest.yml` — все 5 capabilities, confidence/evidence, auth, mappings и честные warnings.
3. `output/checkpoint_novapay/novapay_service.rb` — `Provider::BaseService`, request/auth/amount/status/error/callback logic и явный host-client boundary.
4. `output/checkpoint_novapay/INTEGRATION.md` — готовая инструкция интегратору.
5. `output/checkpoint_novapay/fixtures.json` — реальные OpenAPI examples и помеченные schema-generated fixtures.

Затем одной командой показать универсальность:

```powershell
bundle exec ruby bin/integrate generate --spec examples/alt_transfer_provider.json --provider alt_transfer --output output/checkpoint_alt
ruby -c output/checkpoint_alt/alt_transfer_service.rb
```

В alternative output обратить внимание на `/transfers`, Bearer auth, другие field names и на то, что отсутствующие cancel/webhook/balance не выдуманы, а явно помечены как missing.

Если каталоги от предыдущего прогона существуют, удаляйте только эти точные generated targets либо используйте новые имена. Для краткого доказательства manifest-first architecture можно сгенерировать второй bundle без исходного OpenAPI:

```powershell
bundle exec ruby bin/integrate generate --manifest output/checkpoint_novapay/integration_manifest.yml --output output/checkpoint_from_manifest
```

Generated service безопасно блокирует неподтверждённые mappings и неполную webhook verification. Параметры `allow_unreviewed: true` / `allow_unverified: true` предназначены только для явного inspection/demo, не для production.

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
  -> ProviderIR::Manifest
  -> Service / Documentation / Fixtures generators
  -> validated output bundle
```

Основная точка программного входа:

```ruby
document = IntegrationGenerator::OpenAPI::Parser.parse_file("examples/provider_api.yaml")
manifest = IntegrationGenerator::Analyzer::ManifestBuilder.new(
  document,
  provider_slug: "novapay"
).build
serializable_hash = manifest.to_h
```

`ProviderIR::Manifest` валидирует обязательные sections и ссылки capabilities на operations. Это единственный input для code/docs/fixtures generators; генераторы не читают OpenAPI или Generic IR. CLI поддерживает `generate --manifest`, чтобы эту границу можно было проверить отдельно.

## Поддерживаемое подмножество OpenAPI

Parser поддерживает OpenAPI 3.x YAML/JSON, local JSON Pointer references `#`/`#/...`, servers, paths, стандартные HTTP methods, parameters, JSON request/response content, headers, examples, component schemas и security schemes.

Соседние поля рядом с `$ref` детерминированно накладываются поверх resolved object. Path-level parameters объединяются с operation-level parameters по паре `[in, name]`; operation-level значение имеет приоритет. Path parameters всегда нормализуются как required.

Сейчас явно не поддерживаются:

- external/remote `$ref`;
- циклические/recursive schemas;
- multi-type unions кроме `T | null`, а также `allOf`, `oneOf`, `anyOf`, `not`, discriminator и JSON Schema conditionals;
- OpenAPI callbacks и top-level `webhooks` keyword;
- исполнение OAuth/OpenID/mTLS авторизации;
- generic overrides;
- exact production `Provider::BaseService`, operation model и HTTP client contract — generated service предоставляет документированный adapter boundary.

Unsupported schema/auth/callback constructs становятся warnings. Broken, external или cyclic `$ref` завершают parsing предметной ошибкой. Обычный `POST /webhooks/...` остаётся стандартной HTTP operation и уже извлекается.

## Тесты

```bash
bundle exec rake test
```

Тесты покрывают parser, deterministic semantic rules, ambiguity guards, status/error/webhook/field extraction, manifest validation, все три generators, runtime request/response/callback contract, no-overwrite CLI и обе demo specs. Перед публикацией writer отдельно запускает `ruby -c` для generated service.

## Demo specs

- `examples/provider_api.yaml` — каноническая NovaPay OpenAPI 3.0.3 из материалов хакатона. Исходный файл: `provider_api (1).yaml`, SHA-256 `415F50EE36FB331DFAB49CEED0E8ED3B0EBE16053D7E00DBABD32282F4396551`.
- `examples/alt_transfer_provider.json` — самостоятельная OpenAPI 3.1 fixture с другими endpoint/field names, Bearer auth, server variables и `application/problem+json`.

## После чекпоинта

Ближайшее усиление core — generic overrides для подтверждения или исправления ambiguous intent/status/unit/signature facts без изменения Ruby-кода ядра. Web UI имеет смысл добавлять только поверх этого уже работающего pipeline как удобный demo/review layer.
