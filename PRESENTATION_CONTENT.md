# Payout Studio — содержание финальной презентации

Это основа для deck, без визуального оформления. Актуально на 5 сентября 2026. Передать вместе с [DEMO_GUIDE.md](DEMO_GUIDE.md) и [README.md](README.md). Главная логика: требование → реализация → проверяемое доказательство.

Веса сверены с локальным оригиналом `описание (1).docx`: разбор API — 20; сервис — 25; преобразования — 15; универсальность — 15; понятность/документация — 15; качество реализации — 10. Это веса, не заявленные полученные баллы. Отраслевой блок: дополнительные возможности — 6, выступление — 6, полнота — 8. В оригинальной технической таблице группы суммируются в 103, хотя строка «Итого» указывает 100; самостоятельно нормализовать её нельзя. `qa_сессия.txt` и `вступление.txt` также сверены: точный лимит и слот конкретной команды в них не указаны.

## Слайд 1. Проблема интегратора

- **Мысль:** разнородный API нужно перевести в доменный payout-контракт, а не просто получить HTTP-клиент.
- **Показать:** OpenAPI слева; request/auth/status/amount/webhook задачи справа. Число 2–5 дней пометить «по условию кейса», если подтверждено оригиналом.
- **Сказать:** «Спецификация описывает провайдера, а приложению нужен единый контракт выплаты. Мы автоматизируем извлечение и подготовку адаптера, оставляя неоднозначные решения проверяемыми».
- **Критерий:** понимание кейса и полнота постановки.
- **Evidence:** canonical `examples/provider_api.yaml`; различия входных полей и host-модели в generated mappings. Не использовать неподтверждённый ROI.

## Слайд 2. Вход и конкретный результат

- **Мысль:** из YAML/JSON создаются пять реальных integration artifacts.
- **Показать:** входной файл и список `<provider>_service.rb`, `INTEGRATION.md`, `fixtures.json`, `integration_manifest.yml`, `compatibility_report.md`.
- **Сказать:** «Ruby-сервис содержит request, auth, response и callback логику. Документация, примеры и отчёт создаются из того же manifest».
- **Критерий:** генерация сервиса — 25; понятность/документация — 15.
- **Evidence:** экран «Артефакты», скачанный пакет; `generator/artifact_bundle.rb` и четыре generators. Не обещать generated RSpec: его нет.

## Слайд 3. Pipeline и точка ответственности человека

- **Мысль:** структурное извлечение отделено от семантических решений и генерации.
- **Показать:** `OpenAPI → Parser/Normalizer → Generic IR → Semantic analysis → Manifest → Review/overrides → Generators → Validation`.
- **Сказать:** «Правила детерминированы. Evidence объясняет выбор. Overrides подтверждают отдельные решения и сохраняют источник, причину и audit. Генераторы читают final manifest».
- **Критерий:** разбор API — 20; качество — 10.
- **Evidence:** `openapi/`, `ir/`, `analyzer/`, `overrides/applier.rb`; CLI `generate --manifest`. UI отображает backend readiness и не вычисляет новую семантику.

## Слайд 4. Live demo: от OpenAPI до Ruby

- **Мысль:** показать рабочую цепочку, а не серию статичных скриншотов.
- **Показать:** canonical input → capabilities/evidence → override 6→1 warnings → manifest/audit → ×100/status/required_if → генерация → `create_request` и `process_callback` → скачивание.
- **Сказать:** «Не все значения следует угадывать. Здесь подтверждаем семантику, видим изменения и получаем исполняемый адаптер. Оставшийся secret задаётся при подключении».
- **Критерий:** сервис — 25; преобразования — 15; UX — 15.
- **Evidence:** пошаговый [DEMO_GUIDE.md](DEMO_GUIDE.md), методы настоящего generated service, полный audit, скачанный архив. NEEDS REVIEW не скрывать ради зелёной картинки.

## Слайд 5. Универсальность проверена на различающихся входах

- **Мысль:** один pipeline обрабатывает разные структуры; неизвестное не превращается в выдуманную поддержку.
- **Показать:** таблицу ниже и live withdrawal before/after.
- **Сказать:** «Это canonical кейс и две наши самостоятельные test fixtures. Они меняют не только название провайдера, но auth, endpoints, поля, вложенность и неоднозначности».
- **Критерий:** универсальность — 15.
- **Evidence:** `examples/` и три generated bundles из `bin/demo`; альтернативные contract tests.

| Вход | Различия | Наблюдаемый результат |
|---|---|---|
| Canonical payout | YAML, API key, payout endpoints | 5 capabilities, подтверждения через YAML override, 6→1 warnings |
| Alternative transfer | OpenAPI 3.1 JSON, Bearer, `/transfers`, другие поля | 2 capabilities; cancel/webhook/balance не заявлены, mapping вопросы сохранены |
| Alternative withdrawal | YAML, Basic, nested payload, endpoint без operationId | JSON override: 4→5 capabilities, 9→1 warnings |

## Слайд 6. Качество: какие проверки действительно выполнены

- **Мысль:** разделять синтаксис артефактов, runtime contract tests и будущее подключение.
- **Показать:** 123 tests / 749 assertions после этапа 2; три demo providers + `ruby -c`; список тестируемого runtime поведения. Детали и границы Windows smoke — REVIEW_REPORT.md.
- **Сказать:** «Тесты проверяют запросы, преобразования, auth, статусы, ошибки и callbacks с host test double. Перед записью валидируются артефакты. Реальный sandbox требует окружения и credentials и не входит в доказанный результат».
- **Критерий:** качество реализации — 10; сервис/преобразования.
- **Evidence:** `test/generator/generated_service_contract_test.rb`, `alt_withdrawal_service_contract_test.rb`, `review_regressions_test.rb`, `output_writer_test.rb`; фактическая проверка browser upload/download описана в guide.

## Слайд 7. Дополнительная ценность для платёжных интеграций

- **Мысль:** адаптер сохраняет важные для выплат границы и объясняет решения.
- **Показать:** четыре конкретных примера: idempotency source, HMAC/raw body, schema projection host-полей, provenance/audit.
- **Сказать:** «Показываем не общие слова о надёжности, а поведение: явный источник ключа идемпотентности, проверку подписи, ограничение исходящего payload и историю подтверждений».
- **Критерий:** отраслевые дополнительные преимущества — 6; полнота — 8.
- **Evidence:** generated `process_verified_callback`, `verify_webhook_signature`, `secure_compare`, `project_to_provider_schema`, `validate_required_body!`; mappings и audit. Parsed `process_callback` возвращает `host_required`, не утверждает проверку подписи. Idempotency header не означает глобальную гарантию exactly-once; HMAC не означает security certification.

## Слайд 8. Итог и граница готовности

- **Мысль:** получена автономная, проверяемая заготовка интеграции с честно описанными ограничениями.
- **Показать:** «OpenAPI → проверяемые решения → Ruby + docs + fixtures», три providers, локальная работа без LLM/runtime внешних API.
- **Сказать:** «Обязательный путь реализован и демонстрируется. Для подключения конкретной production-системы остаются host boundary, credentials и sandbox. Новые форматы OpenAPI и generated RSpec — дальнейшее развитие».
- **Критерий:** полнота ответа кейсу и ясность защиты.
- **Evidence:** работающий UI/CLI, manifest-only generation, README supported subset, предыдущие live evidence.

## Что подготовить перед оформлением deck

1. Получить у модератора точный лимит и слот команды, состав жюри и актуальную инструкцию по передаче репозитория. Оригинальная рубрика/Q&A уже сверены локально; отдельный файл актуального регламента не найден.
2. Снять несколько кадров финального UI: вход + capabilities, audit, метод Ruby, три providers. Не заменять живую демонстрацию десятком скриншотов.
3. Отрепетировать на презентационном браузере/экране. Автоматизированная проверка отдельного Chrome пока не выполнена — он не подключён к управлению; встроенный браузер прошёл upload/download.
4. Оставить CLI demo и сгенерированный пакет как резерв. Новые product features перед защитой не требуются.

## Краткая матрица защиты

| Требование | Реализация | Демонстрация | Оставшаяся граница |
|---|---|---|---|
| Разбор API | Parser, refs, schemas, auth/responses/errors | Исходник → manifest/evidence | Поддерживаемый subset, не весь OpenAPI |
| Ruby service | Manifest-driven BaseService-style adapter | Реальные методы и download | Документированный host boundary, не подтверждённый production host |
| Data mappings | Amount/status/field/conditional transformations | ×100, статусы, required_if, tests | Полный JSON Schema runtime validator отсутствует |
| Универсальность | Generic rules + YAML/JSON overrides | Три структурно разных входа | Две альтернативы — собственные fixtures |
| UX/docs | UI, warnings, audit, пять файлов | Полный flow и читаемые docs | Репетиция в целевом Chrome/на проекторе |
| Качество | Contract tests, validation, no-overwrite output | Green suite, ruby -c, реальные скачивания | Нет sandbox certification/generated RSpec |
