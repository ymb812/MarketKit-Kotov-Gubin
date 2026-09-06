# Payout Studio — текст третьего чекпоинта

Это текст устного доклада на фоне заранее записанного экранного видео. Слайды для третьего чекпоинта не используются. Реплики в блоках «На экране» не произносятся.

> **TIMING TODO:** получить у модератора точный лимит, затем один раз прочитать текст поверх готового видеоряда и сократить монтаж вместе с репликами. Не назначать длительность заранее.

## Основной текст

### 1. Задача и вход

_На экране: обзор Payout Studio, canonical `provider_api.yaml`, затем фрагменты `paths`, schemas и security._

При подключении платёжного провайдера разработчик вручную переводит его API в контракт платформы: находит нужные методы, сопоставляет поля и статусы, разбирает ошибки и webhook. По условию кейса это занимает от двух до пяти дней.

Мы сделали Payout Studio — автономный Ruby-инструмент для подготовки payout-интеграций. На вход он принимает OpenAPI 3.x в YAML или JSON. На выходе создаёт пять согласованных файлов: Ruby service под `Provider::BaseService`, инструкцию интегратору, fixtures, финальный Integration Manifest и compatibility report. Во время работы ему не нужны LLM, внешние API или проприетарные сервисы.

### 2. Что система понимает из OpenAPI

_На экране: вернуться в обзор, раскрыть evidence одной capability и показать восемь исходных diagnostics._

Сначала parser извлекает структурные факты: servers, HTTP-методы, параметры пути, query и headers, request и response schemas, required-поля, examples, security, статусы и ошибки. Локальные `$ref` раскрываются до анализа. Обычный `POST /webhooks/...` тоже распознаётся как входящее уведомление.

Затем OpenAPI превращается в provider-neutral Generic IR. Только после этого детерминированные правила определяют payout-смысл операций: создание, проверку статуса, отмену, webhook и баланс. У каждого такого решения есть confidence и evidence. Confidence здесь — оценка правил, а не вероятность того, что интеграция уже готова к production.

Следующий слой — Integration Manifest. В нём отдельно видны факты из OpenAPI, выводы анализатора и вопросы, которые нельзя решить безопасно. Broken, external и cyclic refs останавливают разбор с предметной ошибкой. Advanced composition, OpenAPI callbacks и другие конструкции вне поддержанного subset не маскируются: система показывает их как ограничения.

### 3. Review и overrides

_На экране: «Открыть overrides», включить применение, повторить анализ; показать 18 изменений и переход warnings 8 → 1. Открыть manifest, audit и compatibility report._

Главная идея проекта — не генерировать Ruby напрямую из YAML. Между анализом и генерацией есть проверяемая точка review. Если OpenAPI не говорит, что именно означает статус или откуда host должен взять поле, генератор не угадывает молча.

В canonical примере до review видно восемь diagnostics. Мы применяем обычный YAML override и повторяем анализ. Он фиксирует восемнадцать конкретных изменений, а число открытых diagnostics уменьшается с восьми до одного. В audit остаются source, reason и значения до и после изменения.

Оставшийся пункт — callback secret. Это не ошибка OpenAPI и не задача override: рабочий секрет должен прийти из окружения host-приложения. Поэтому итоговый report честно остаётся в состоянии `NEEDS REVIEW`, хотя все пять capabilities обнаружены.

### 4. Преобразования данных

_На экране: раздел «Преобразования» — сумма ×100, таблица статусов, conditional requirements и host→provider mappings._

Теперь решения из manifest становятся исполняемым поведением. Сумма из `operation.amount` переводится в копейки с коэффициентом сто. Расчёт точный: если значение нельзя представить целым числом minor units, service завершает операцию понятной ошибкой, а не округляет деньги.

Статусы подтверждены по канону задания: `pending` и `processing` переходят в `in_progress`, `completed` — в `approved`, `failed` и `cancelled` — в `rejected`. Неизвестное значение остаётся `unknown` и не вызывает terminal helper.

Host-модель тоже не угадывается. Для СБП реквизиты читаются из `payout_requisite.sbp`, номер карты — из плоского `payout_requisite.card_number`, а тип выплаты может прийти через логический `request_method`. Подтверждённые условия требуют `bank_code` для СБП и номер карты для карточной выплаты. Незнакомый IBAN, account или tax id остаётся явным TODO до согласования схемы host-приложения.

Перед отправкой составной объект проецируется на provider schema. Во внешний запрос не попадают внутренние поля, которых провайдер не объявил.

### 5. Generated service и пакет интеграции

_На экране: «Сгенерировать пакет», затем быстрые переходы к `create_request` и `process_callback`; открыть `INTEGRATION.md`, `fixtures.json`, report и скачать `.tar.gz`._

Из final manifest генерируется класс `Provider::NovapayService < Provider::BaseService`. `create_request` собирает URL, headers, query и body, добавляет API key и idempotency key, вызывает абстрактный `provider_client`, разбирает ответ и возвращает `success(result: { id: provider_id })`. Платформа сохраняет этот id в `provider_operation_key`; `fetch_status` и отмена используют именно его.

HTTP- и provider-ошибки переводятся в стандартные symbols платформы. Retry scheduler, persistence и реальный HTTP transport остаются на стороне host-приложения — generated adapter не выдаёт их за готовые части интеграции.

Для callback есть два входа. `process_callback(payload)` работает с уже разобранным и аутентифицированным Hash. Terminal status вызывает `approve_operation` или `reject_operation`. Если у HTTP-слоя есть исходные байты, `process_verified_callback(raw_body, headers:)` проверяет HMAC-SHA256 в hex или base64 и разбирает именно подписанное тело. Повторная сериализация Hash не используется как замена raw body.

Рядом с service создаются `INTEGRATION.md`, `fixtures.json`, manifest и compatibility report. Fixtures предпочитают examples из OpenAPI, а сгенерированные по schema значения помечают provenance. Отсутствующая capability не получает выдуманный fixture.

### 6. Универсальность

_На экране: alternative transfer, затем alternative withdrawal до и после JSON override._

Тот же pipeline работает не только на canonical API. Transfer-вариант — это OpenAPI 3.1 в JSON, Bearer auth, пути `/transfers` и другие имена полей. В нём есть только создание и получение статуса. Поэтому интерфейс показывает две обнаруженные и три не заявленные capabilities, а не создаёт фиктивные методы отмены, webhook и баланса.

Withdrawal-вариант использует YAML, Basic auth, вложенные ответы `data.transaction`, webhook `/notifications` и base64-подпись. Endpoint статуса не имеет `operationId`, поэтому сначала он требует решения. Тот же generic override переводит результат с четырёх до пяти capabilities и сокращает diagnostics с одиннадцати до одного — снова остаётся только runtime secret.

Provider-specific данные находятся в specs и overrides, не в Ruby-core. Генераторы читают только final manifest. Мы отдельно повторили canonical generation без OpenAPI и override: все пять файлов совпали с исходным bundle по SHA-256.

### 7. Проверки, границы и результат

_На экране: validation summary в Payout Studio и завершённый `bin/demo`; закончить на списке пяти файлов без красных ошибок._

Перед публикацией bundle проверяются Ruby-синтаксис, JSON fixtures и структура manifest. Output writer использует staging и lock, не перезаписывает существующий каталог и публикует результат только после успешного `ruby -c`.

На текущей версии проходят 134 Ruby tests и 792 assertions без failures, errors и skips. Отдельно проходят семь frontend tests. Новый demo-прогон создал три bundle по пять файлов; все три services прошли `ruby -c`, а скачанный из Payout Studio архив побайтово совпал с созданными артефактами.

Мы не заявляем поддержку всего OpenAPI или готовность к production без проверки. В текущий subset не входят remote и cyclic refs, advanced schema composition, OAuth execution, OpenAPI callbacks keyword, полный runtime JSON Schema validator и per-item array mappings. Для реального подключения ещё нужны credentials, адаптация к фактическому host-приложению, HTTP transport и sandbox.

Результат проекта — не ещё один низкоуровневый SDK. Это проверяемая заготовка Ruby payout adapter, где автоматические выводы, решения интегратора и оставшиеся риски видны до подключения провайдера.

## Монтажная карта — не произносить

| Блок текста | Кадр из `DEMO_GUIDE.md` | Что закрывает |
|---|---|---|
| 1. Задача и вход | Шаг 1 | проблема, формат входа, E5.1 |
| 2. Что система понимает | Шаг 2 | E1.1–E1.3, Generic IR, diagnostics |
| 3. Review и overrides | Шаг 3 | manifest-first, audit, E4.3, E5.3 |
| 4. Преобразования | Шаг 4 | E3.1–E3.2 |
| 5. Generated service | Шаг 5 | E2.1–E2.3, E5.2 |
| 6. Универсальность | Шаг 6 | E4.1–E4.2 |
| 7. Проверки и границы | Шаг 7 | E6.1–E6.2, итог и ограничения |

Если лимит окажется короче текста, сначала убрать из основного видеоряда подробности schema projection, callback verification и negative cases, но не вырезать проблему, manifest-first review, generated service, преобразования, три specs, реальные проверки и границы обещаний.
