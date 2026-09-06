# Критерий 2: реализация и доказательства тестами

Эта карта отвечает на вопрос жюри, как реализация и тесты соотносятся со всеми тремя подпунктами критерия «Генерация интеграционного сервиса» суммарным весом **25 баллов**. Это traceability, а не самостоятельно присвоенная оценка. Главная исполняемая реализация находится в [`ServiceGenerator`](lib/integration_generator/generator/service_generator.rb); тесты генерируют Ruby через штатный pipeline, загружают generated class и проверяют наблюдаемое поведение через recording client и тестовый `Provider::BaseService`.

| Подкритерий | Что реализовано | Автоматическое доказательство |
|---|---|---|
| **10 — формирует и отправляет запросы к API** | `create_request`/`create_payout`, `fetch_status`, `cancel_payout`, `balance`; method/base URL/path/query/header/body; URL encoding; API key/Bearer/Basic и AND/OR auth; major-to-minor; явная отправка через `provider_client.call` | [`generated_service_contract_test.rb`](test/generator/generated_service_contract_test.rb): create dispatch, SBP/card, fetch path; [`alt_withdrawal_service_contract_test.rb`](test/generator/alt_withdrawal_service_contract_test.rb): fetch/cancel/balance + Basic; [`real_provider_examples_test.rb`](test/real_providers/real_provider_examples_test.rb): точные запросы Adyen и Airwallex |
| **8 — обрабатывает ответы, статусы и ошибки** | Выбор response schema по фактическому status с приоритетом exact над `2XX`/`default`; JSON parsing; provider id/status/code/message/retry-after; стабильные platform error symbols; terminal statuses вызывают `approve_operation`/`reject_operation`; unknown/in-progress не меняют операцию | [`runtime_review_test.rb`](test/generator/runtime_review_test.rb): разные 2xx, exact/range/default, HTTP 400/401/402/422/429/500, malformed JSON; [`generated_service_contract_test.rb`](test/generator/generated_service_contract_test.rb): amount-limit failure и lifecycle; real-provider test: Adyen `booked -> approve`, Airwallex 201 id и 400 code/message |
| **7 — входящие уведомления и параметры подключения** | `process_callback` для уже аутентифицированного payload; `process_verified_callback` для HMAC-SHA256 по точному raw body, constant-time compare, hex/base64; payload id/status mapping; ENV для base URL, credentials и callback secret; отсутствие секрета/неподтверждённой схемы блокирует обработку | [`generated_service_contract_test.rb`](test/generator/generated_service_contract_test.rb): canonical hex signature, tamper/missing secret и callback status; [`alt_withdrawal_service_contract_test.rb`](test/generator/alt_withdrawal_service_contract_test.rb): base64 и nested payload; [`review_regressions_test.rb`](test/generator/review_regressions_test.rb): signed-body invariant и ambiguous callback fail-closed; [`runtime_review_test.rb`](test/generator/runtime_review_test.rb): Bearer и multi-scheme auth |

## Команды для проверки

Минимальная прицельная проверка критерия:

```powershell
bundle exec ruby -Itest test/generator/generated_service_contract_test.rb
bundle exec ruby -Itest test/generator/runtime_review_test.rb
bundle exec ruby -Itest test/generator/alt_withdrawal_service_contract_test.rb
bundle exec ruby -Itest test/generator/review_regressions_test.rb
bundle exec ruby -Itest test/real_providers/real_provider_examples_test.rb
```

Полная регрессия и короткое наблюдаемое доказательство на реальных спецификациях:

```powershell
bundle exec rake test
bundle exec ruby bin/real_provider_demo
```

## Как устроен test harness

Тестовый `Provider::BaseService` реализует только контракт хоста: `success`, `failure`, `approve_operation`, `reject_operation`. Recording client сохраняет полученный request и возвращает заданный response. Поэтому assertions видят обе стороны generated adapter:

```text
host operation -> generated mapping/auth/request -> provider_client.call
provider HTTP response -> generated normalization -> BaseService result/action
raw callback bytes -> generated signature verification -> BaseService action
```

Это unit/integration contract tests без внешней сети. Они детерминированы и проверяют именно generated code, но не подменяют live sandbox certification.

## Fail-closed свойства, которые тоже проверяются

- обязательное неизвестное поле нельзя отправить без явного override;
- необязательное неоднозначное поле пропускается, если значение не передано, но блокируется при попытке его отправить;
- неподтверждённый terminal status не вызывает platform action;
- callback с изменёнными байтами, без секрета или без однозначных id/status paths отклоняется;
- неподдержанная auth-схема и отсутствующий credential дают configuration error;
- generated bundle публикуется только после успешного внешнего `ruby -c`.

Граница: настоящий HTTP transport, retries, persistence и production-классы хоста внедряются платформой через документированный adapter boundary. Credentials в репозитории отсутствуют.
