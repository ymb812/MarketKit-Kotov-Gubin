# Проверка на OpenAPI реальных провайдеров

В репозитории есть два воспроизводимых примера на официальных публичных OpenAPI: **Adyen Transfers API v4** и **Airwallex Payouts / Transfers API**. Это не переименованные тестовые fixtures: каждый snapshot содержит точный repository, commit, путь исходного файла и SHA-256 полного источника в `x-hackgenesis-source`.

## Быстрая проверка

Из корня репозитория:

```powershell
bundle exec ruby bin/real_provider_demo
bundle exec ruby -Itest test/real_providers/real_provider_examples_test.rb
```

Первая команда для обоих провайдеров проходит полный путь `OpenAPI -> Generic IR -> Manifest -> overrides -> 5 artifacts -> ruby -c`, загружает generated class и выполняет его через recording fake client. Вторая команда утверждает provenance/hashes и точные request/response/status/error результаты.

Провайдерские HTTP endpoints намеренно не вызываются: в публичный Git не помещаются credentials, а сетевой sandbox без выданного merchant account не был бы воспроизводимым тестом. Проверяется не mock анализатора, а сгенерированный Ruby-класс на границе `provider_client.call(method:, url:, headers:, query:, body:)`; fake client заменяет только транспорт и возвращает заданный HTTP response.

## Adyen Transfers API v4

| Свойство | Значение |
|---|---|
| Официальный источник | [Adyen `TransferService-v4.yaml` на закреплённом commit](https://github.com/Adyen/adyen-openapi/blob/f82d1fe674e536cc2c6b0d7946e0e827873a4fbf/yaml/TransferService-v4.yaml) |
| Commit | `f82d1fe674e536cc2c6b0d7946e0e827873a4fbf` |
| Исходный файл | `yaml/TransferService-v4.yaml` |
| SHA-256 полного источника | `4d9803371cda6c5be7ca456e201cb287e7851830ba1d96506224d0542cec59a5` |
| Локальный snapshot | [`examples/real/adyen_transfer_v4.yaml`](examples/real/adyen_transfer_v4.yaml) |
| Review overrides | [`examples/real/adyen_transfer_v4_overrides.yaml`](examples/real/adyen_transfer_v4_overrides.yaml) |
| Сохранённые paths | `POST /transfers`, `GET /transfers/{id}`; list `GET /transfers` явно помечен `unknown` |
| После review | `create_payout`, `fetch_status`: 2 из 5 capabilities; отсутствующие методы не выдумываются |

Runtime-проверка доказывает API-key header, `Idempotency-Key`, major-to-minor `123.45 -> 12345`, body `amount/category/counterparty`, извлечение provider id, URL encoding path id и подтверждённое действие `booked -> approve_operation`.

## Airwallex Payouts / Transfers API

| Свойство | Значение |
|---|---|
| Официальный источник | [Airwallex client OpenAPI на закреплённом commit](https://github.com/airwallex/airwallex-openapi/blob/a8a09eb98ccf65e4a44481f768ac58cbd6540fa5/openapi/client-api/latest/airwallex-openapi-latest.json) |
| Commit | `a8a09eb98ccf65e4a44481f768ac58cbd6540fa5` |
| Исходный файл | `openapi/client-api/latest/airwallex-openapi-latest.json` |
| SHA-256 полного источника | `ee3add01d9e521467b023711f965dc5dba78ee9246f566295725e62fd13629a2` |
| Локальный snapshot | [`examples/real/airwallex_transfer.json`](examples/real/airwallex_transfer.json) |
| Review overrides | [`examples/real/airwallex_transfer_overrides.yaml`](examples/real/airwallex_transfer_overrides.yaml) |
| Сохранённые paths | `POST /api/v1/transfers/create`, `GET /api/v1/transfers/{id}`, `POST /api/v1/transfers/{id}/cancel` |
| После review | `create_payout`, `fetch_status`, `cancel_payout`: 3 из 5 capabilities; webhook/balance не заявляются |

Runtime-проверка доказывает Bearer auth, create body с beneficiary/amount/currency/reference/request id, нормализацию HTTP 201 и provider id, извлечение provider `code/message` из HTTP 400, отправку fetch/cancel и URL encoding path id. Значение `PENDING` без enum/status review не вызывает выдуманного terminal action.

## Почему snapshots сфокусированы

Полные upstream-файлы велики и содержат много несвязанных API. [`bin/refresh_real_examples`](bin/refresh_real_examples) скачивает источник на закреплённом commit, проверяет его SHA-256, оставляет только перечисленные payout paths и транзитивное замыкание их local `$ref`. Сохранённые OpenAPI nodes семантически не переписываются; добавляется только `x-hackgenesis-source` с provenance. Поэтому пример компактнее, но все реально используемые request/response schemas приходят из официального файла.

Повторное получение snapshots:

```powershell
bundle exec ruby bin/refresh_real_examples
```

Команда требует интернет. Обычные генерация, demo и тесты работают полностью локально с уже сохранёнными snapshots. Тексты лицензий upstream-репозиториев сохранены рядом как `LICENSE-ADYEN.txt` и `LICENSE-AIRWALLEX.txt`; встроенные license metadata самой OpenAPI также не изменены.

## Честная граница утверждения

Подтверждено: реальные официальные схемы парсятся тем же generic pipeline, из них генерируются все пять артефактов, generated Ruby синтаксически валиден и исполняет transport-independent request/response контракт.

Не подтверждено и не заявляется: авторизованный live-вызов production/sandbox аккаунта, provider-side бизнес-валидация конкретного merchant и сертификация интеграции провайдером.
