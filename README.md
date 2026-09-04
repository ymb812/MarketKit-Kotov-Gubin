# HackGenesis Provider Integration Generator

Автономный Ruby-инструмент, который преобразует OpenAPI платёжного провайдера в нормализованную модель, а затем будет генерировать payout adapter под контракт `Provider::BaseService`, документацию и fixtures.

Текущий завершённый срез — V0:

```text
OpenAPI YAML/JSON -> validation -> local $ref resolution -> Generic IR -> JSON/YAML stdout
```

Semantic classification, Integration Manifest и generators будут добавлены следующими вертикальными этапами. Runtime не использует LLM или внешние API.

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
```

JSON — формат вывода по умолчанию. `inspect` пишет только machine-readable IR в stdout; предметные ошибки выводятся в stderr и возвращают ненулевой exit code.

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

Parser не присваивает операциям payout-intents и не содержит provider-specific branches. Будущие semantic analyzers будут читать только Generic IR.

## Архитектура V0

```text
bin/integrate
  -> IntegrationGenerator::CLI
  -> OpenAPI::Loader
  -> OpenAPI::DocumentValidator
  -> OpenAPI::RefResolver
  -> OpenAPI::Parser + SchemaParser
  -> IR::Document / Operation / Schema / Warning
  -> JSON or YAML
```

Основная точка программного входа:

```ruby
document = IntegrationGenerator::OpenAPI::Parser.parse_file("examples/provider_api.yaml")
serializable_hash = document.to_h
```

## Поддерживаемое подмножество OpenAPI

V0 поддерживает OpenAPI 3.x YAML/JSON, local JSON Pointer references `#`/`#/...`, servers, paths, стандартные HTTP methods, parameters, JSON request/response content, headers, examples, component schemas и security schemes.

Соседние поля рядом с `$ref` детерминированно накладываются поверх resolved object. Path-level parameters объединяются с operation-level parameters по паре `[in, name]`; operation-level значение имеет приоритет. Path parameters всегда нормализуются как required.

Сейчас явно не поддерживаются:

- external/remote `$ref`;
- циклические/recursive schemas;
- multi-type unions кроме `T | null`, а также `allOf`, `oneOf`, `anyOf`, `not`, discriminator и JSON Schema conditionals;
- OpenAPI callbacks и top-level `webhooks` keyword;
- исполнение OAuth/OpenID/mTLS авторизации;
- semantic payout classification, status/error/field mapping;
- Integration Manifest, overrides и generators.

Unsupported schema/auth/callback constructs становятся warnings. Broken, external или cyclic `$ref` завершают parsing предметной ошибкой. Обычный `POST /webhooks/...` остаётся стандартной HTTP operation и уже извлекается.

## Тесты

```bash
bundle exec rake test
```

Тесты покрывают YAML/JSON loading, safe YAML aliases/tags, OpenAPI version guard, local refs и ошибки refs, schema normalization, auth, параметры, request/response parsing, обе demo specs и CLI JSON/YAML output.

## Demo specs

- `examples/provider_api.yaml` — каноническая NovaPay OpenAPI 3.0.3 из материалов хакатона. Исходный файл: `provider_api (1).yaml`, SHA-256 `415F50EE36FB331DFAB49CEED0E8ED3B0EBE16053D7E00DBABD32282F4396551`.
- `examples/alt_transfer_provider.json` — самостоятельная OpenAPI 3.1 fixture с другими endpoint/field names, Bearer auth, server variables и `application/problem+json`.

## Следующий этап

Следующий вертикальный срез: `Generic IR -> deterministic semantic analysis -> reviewable Integration Manifest` с intents, confidence/evidence, auth/status/error/webhook extraction и явными warnings на неоднозначности.

Стабильный проектный контекст и фактический прогресс находятся в `docs/PROJECT_CONTEXT.md` и `docs/PROJECT_STATUS.md`.
