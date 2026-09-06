# Payout Studio — текст третьего чекпоинта

Это единый актуальный источник устного текста для третьего чекпоинта. Формат чекпоинта: команда включает заранее подготовленное экранное видео и на его фоне рассказывает этот текст; слайды не используются. Сценарий видеоряда находится в [DEMO_GUIDE.md](DEMO_GUIDE.md), проверяемые ссылки на код и тесты — в [JURY_GUIDE.md](JURY_GUIDE.md). Storyboard в конце относится только к возможной финальной защите и не входит в текущую подготовку.

Веса из задания используются только для полноты покрытия: разбор API — 20, generated service — 25, преобразования — 15, универсальность — 15, понятность и документация — 15, качество реализации — 10. Это не наша самооценка. Техническая таблица в локальных версиях задания содержит арифметическое расхождение 100/103, поэтому мы не пересчитываем и не нормализуем её самостоятельно.

## Основной текст

Сложность этого кейса не в том, чтобы отправить ещё один HTTP POST. OpenAPI уже описывает транспорт: endpoint, поля, схему ответа. Но приложению Space Payments нужен другой уровень — единый payout-контракт, в котором сумма, статусы, идентификаторы, ошибки и callbacks ведут себя предсказуемо независимо от конкретного провайдера.

Мы сделали автономный Ruby-инструмент, который принимает OpenAPI 3.x в YAML или JSON и создаёт заготовку provider adapter. На выходе не один сгенерированный файл, а согласованный пакет: Ruby service, инструкция интегратору, fixtures, финальный Integration Manifest и compatibility report. Все пять файлов строятся из одного final manifest. Runtime не использует LLM, внешние API или проприетарный сервис.

Главное решение проекта — не генерировать Ruby напрямую из YAML. Между ними есть два явных контракта. Сначала parser переводит OpenAPI в provider-neutral Generic IR. Затем детерминированные analyzers строят inferred Integration Manifest: назначают операциям payout-intents, находят auth, status values, errors, webhook и field mappings. Если вывод нельзя подтвердить структурой спецификации, он остаётся предложением с confidence и evidence. Интегратор может принять или исправить его общим YAML/JSON override. После этого final manifest становится единственным входом для generators.

Такой pipeline даёт человеку нормальную точку контроля. Мы не предлагаем поверить генератору на слово и не прячем сомнение за «успешной» генерацией. В manifest видно, что пришло из OpenAPI, что предложили правила, что подтвердил override и какие вопросы остались нерешёнными.

## Разбор API — E1.1–E1.3

### Методы, параметры, запросы и ответы — E1.1

Parser читает servers, paths, HTTP methods, `operationId`, tags, summary и description. Для каждой операции он сохраняет path/query/header parameters, request body, response variants, headers, examples, required fields и вложенные object/array schemas. Local `$ref` раскрываются до semantic analysis; path-level и operation-level parameters объединяются по правилам OpenAPI, причём operation-level значение имеет приоритет.

Это существенно шире списка endpoints. Generic IR содержит request/response contract, из которого позже можно вывести field mappings, fixtures и runtime normalization. Если рядом встречается конструкция вне заявленного subset, parser не должен делать вид, что понял её: unsupported schema/auth/callback elements становятся warnings, а broken, external или cyclic refs завершают разбор предметной ошибкой.

Canonical parser tests используют официальный `examples/provider_api.yaml` напрямую. Отдельные tests проверяют JSON-вход, OpenAPI 3.1 nullable union, constraints, parameter precedence, chained refs и отрицательные случаи. Граница здесь честная: весь OpenAPI и JSON Schema мы не заявляем. Advanced composition, remote refs, callbacks objects и полная transport-сериализация `style/explode` остаются вне текущего subset.

### Авторизация, статусы и ошибки — E1.2

Auth analyzer распознаёт API key, Bearer и Basic, сохраняет root- и operation-level security requirements и различает OR-варианты от AND-наборов. Для credentials формируются ENV placeholders. Если у операции два обязательных ключа одного типа, они получают разные имена; если security допускает несколько альтернатив, runtime выбирает первую полностью настроенную поддержанную группу, а не просто первую запись.

Status analyzer ищет lifecycle values в успешных responses и callback payload. Error responses не становятся статусами выплаты. Общие синонимы вроде `completed` или `failed` сохраняются как reviewable предложение, а не как подтверждённая семантика провайдера. До override generated runtime возвращает `unknown`. Для canonical кейса mapping из задания подтверждён явно: pending/processing → in_progress, completed → approved, failed/cancelled → rejected. Значение `accepted`, которого нет в найденной таблице, остаётся unknown.

Error analyzer сохраняет HTTP status, code/message paths, headers и examples. Codes из schema enum и из examples не смешиваются. Вложенные ответы поддерживаются, `Retry-After` не теряется. При обработке фактического ответа действует порядок exact status → range → default; это отдельно проверено на HTTP 400, 401, 402, 422, 429 и 500, malformed JSON и разных error shapes.

### Webhook и дополнительные условия — E1.3

Обычный `POST /webhooks/...` распознаётся как входящая операция. Analyzer ищет signature header, algorithm и encoding, а также event/status/id/error paths в payload. Из request contract извлекаются idempotency header и условные требования к полям.

Здесь особенно легко получить опасную ложную уверенность, поэтому неоднозначность блокирует автоматический выбор. Два signature-like headers, несколько payout id paths или текстовое условие без подтверждённого host source остаются warning. Override может выбрать только header или schema path, который действительно объявлен в контракте. OpenAPI callbacks и top-level `webhooks` keyword пока диагностируются как unsupported; стандартный webhook POST поддерживается.

## Generated service — E2.1–E2.3

### Формирование и отправка запросов — E2.1

Service generator создаёт класс вида `Provider::<Name>Service < Provider::BaseService`. `create_request` отправляет provider request, разбирает ответ и возвращает `success(result: { id: provider_id })`; `create_payout` оставлен совместимым alias. `check_conditions` использует `success`/`failure`, а `build_provider_request` отдельно позволяет проверить transport payload без сети. Наличие метода в шаблоне не означает выдуманную capability: вызов разрешён только для detected operation из final manifest.

Внутри service `build_request` формирует method, URL, headers, query и body, а `dispatch` передаёт их `provider_client.call(method:, url:, headers:, query:, body:)`. Платформа получает нормализованный id и сохраняет его в `provider_operation_key`; fetch/cancel читают именно это поле.

Generated runtime подставляет и URL-encode-ит path parameters, применяет подтверждённые host→provider mappings, добавляет idempotency и auth. Request behavior исполняется в contract tests с fake client, а не проверяется поиском строк в сгенерированном Ruby.

### Ответы, статусы и ошибки — E2.2

`normalize_response` выбирает response mapping по фактическому HTTP status. Это важно для API, где `204` описан раньше `201` или разные 2xx responses возвращают разные schemas: первый успешный ответ больше не считается универсальным. Exact response имеет приоритет над range даже при пустом body.

Внутренняя нормализация сохраняет HTTP/body/provider facts для выбора mapping. Наружу `create_request` отдаёт только платформенный payload с id, а provider errors переводит в фиксированные symbols: `bad_request`, `unauthorized`, `forbidden`, `unprocessable_entity`, `too_many_requests`, `internal_server_error`. Уникальные symbols по имени провайдера не создаются.

В задании HTTP 402 связан с `insufficient_balance` и действием `retry later`; generated adapter не отправляет выплату повторно сам. `amount_limit_exceeded` трактуется как лимит конкретной выплаты и возвращает `unprocessable_entity`, а не ручную обработку. Суточную policy нельзя выводить из этого кода без отдельного контракта.

### Callback и подключение — E2.3

Base URL приходит из `servers` и может быть переопределён через ENV. Credentials также читаются из ENV; реальные secrets не попадают в manifest, fixtures или generated source.

После нового Q&A callback-контракт разделён на два входа. `process_callback(payload)` принимает уже аутентифицированный и разобранный Hash. Подтверждённый terminal status вызывает `approve_operation(provider_id)` или `reject_operation(provider_id, reason)`; отдельный `success(result: { status: ... })` не нужен.

Когда интеграция передаёт исходные байты, используется `process_verified_callback(raw_body, headers:)`. Он проверяет HMAC-SHA256 в hex или base64, сравнивает подпись без раннего выхода и затем разбирает именно подписанное тело. Повторная сериализация Hash для восстановления raw body запрещена, потому что она может изменить байты. Tests покрывают корректную и повреждённую подпись, missing secret/header, неизвестный encoding, ambiguous mappings и nested callback payload.

## Преобразования данных — E3.1–E3.2

### Сопоставление полей и статусов — E3.1

Field mapping хранит не только пары имён. Для каждого поля известны host source, provider target, location, schema, confidence, evidence, provenance и необходимость review. Источник может быть гарантированным `operation.*`, логическим `request_method` либо явной scalar-константой. `source` и `value` взаимоисключающие.

Если lexical rule не может отличить `merchant_id` от `payout_id`, общий параметр не получает автоматически роль provider operation id. Несколько payout-like candidates тоже требуют review. После явного override mapping попадает в audit с before/after, source и reason.

Подтверждённая host-модель ограничена `operation.id`, `operation.amount`, JSONB `operation.payout_requisite` и служебным `provider_operation_key`. СБП читается из `payout_requisite.sbp.*`, card number — из плоского ключа. Для незнакомого IBAN, account или tax id генератор оставляет TODO: совпадение имени provider field не доказывает схему host requisites.

Composite host object перед отправкой проецируется на provider schema. Это не косметическая операция: внутренние поля host-модели не должны утечь во внешний payout request. Именованные properties разрешены, `additionalProperties` учитывается явно, а object без известной границы блокируется. Направление readOnly/writeOnly также сохраняется: readOnly response field не требуется во входящем request, writeOnly request field не используется как response status.

Status mapping исполняется только после подтверждения. Неизвестное runtime value остаётся `unknown`; event webhook возвращается отдельно и не подменяет payload status. Если конкретный провайдер задаёт другую event/status policy, её нужно подтвердить как часть host/provider contract.

### Форматы и обязательность — E3.2

Для денег analyzer отличает явно описанные копейки/центы от расплывчатого `minor units`. Canonical override задаёт major→minor и factor 100. Runtime использует точную Rational arithmetic: `10.25` превращается в 1025, а значение, которое даёт дробную minor unit, завершается понятной ошибкой вместо округления.

Required fields проверяются после всех mappings и composite projection. Это позволяет отличить отсутствующий key от explicit nullable `nil` и не потерять `false`. Подтверждённый `required_if` выполняется в service: например, `bank_code` становится обязательным только для нужного recipient type. Whole-array projection работает при известной items schema; per-item host mappings вроде `items[].field` пока не поддержаны.

Parser сохраняет enum, format, pattern, min/max и nullable, но мы не называем это полным runtime JSON Schema validator. Исполняются те constraints и transformations, для которых в generated adapter есть явный контракт и тест.

## Универсальность — E4.1–E4.3

### Разные структуры API — E4.1

Универсальность проверяется не копиями NovaPay с заменённым названием. `bin/demo` проводит через один pipeline три входа.

Canonical NovaPay — YAML/OpenAPI 3.0.3, API key, payout endpoints, top-level id/status и HMAC hex. Alternative transfer — JSON/OpenAPI 3.1, Bearer, `/transfers`, другие fields, server variables и только create/fetch capabilities. Cancel, webhook и balance там не создаются. Alternative withdrawal — YAML, Basic, withdrawal terminology, nested `data.transaction.*`, base64 webhook, conditional beneficiary fields и status endpoint без `operationId`. Generic JSON override переводит этот endpoint из `requires_review` в detected.

Наблюдаемый результат — 5/2/5 detected capabilities. Transfer-вариант полезен именно тем, что остаётся неполным: generator не маскирует отсутствие метода stub-реализацией. Withdrawal проверяет совместную работу других auth, nesting, naming и review path. Обе альтернативы — наши structural fixtures, а не заявления о production-интеграции с публичными провайдерами.

### Отсутствие provider-specific core — E4.2

NovaPay-specific semantics находятся в canonical OpenAPI и data-only override. Parser не назначает payout intent; generators не читают OpenAPI. Можно взять сохранённый final manifest, выполнить `generate --manifest` без spec/override и получить те же пять файлов побайтово. В финальной проверке различий SHA-256 не было.

Это более сильная граница, чем отсутствие строки `novapay` в `lib/`, хотя такой scan тоже проходит. Manifest-only test специально делает parser недоступным и всё равно строит bundle. Alternative runtime tests затем проверяют, что за архитектурой действительно стоит другое поведение, а не один универсальный NovaPay-шаблон.

### Новые правила и unsupported elements — E4.3

Semantic rules разделены по предмету: operation classification, auth, statuses, errors, webhook и fields. Новое правило для существующей capability добавляется в профильный analyzer и обязано вернуть evidence и безопасное состояние review. Provider ambiguity можно закрыть versioned YAML/JSON override без ветки по имени провайдера.

Неизвестные операции сохраняются в `unsupported_operations`; missing и ambiguous capabilities видны в manifest, report и fixtures. Добавление новой доменной capability потребует согласованного изменения нескольких слоёв, потому что пять payout slots сейчас фиксированы. Это осознанная граница, а не plugin API, которого пока нет. Конкретный маршрут изменения parser, rules, overrides, capabilities и artifacts описан в `MODULE_MAP.md`.

## Использование и документация — E5.1–E5.3

### Последовательный запуск — E5.1

Основной CLI имеет три команды: `inspect` печатает Generic IR, `analyze` — inferred или reviewed manifest, `generate` — полный bundle. Для проверки всего результата одной командой есть `bundle exec ruby bin/demo`: он создаёт новый уникальный output root, прогоняет три providers и запускает `ruby -c` перед публикацией каждого service.

Локальный Payout Studio работает поверх того же Ruby pipeline. Backend делит diagnostics на `reviewable`, `manual_configuration`, `unsupported` и `invalid_spec`; JavaScript только отображает готовое действие. Поэтому `oneOf` ведёт к подсвеченной строке OpenAPI и прямо сообщает, что override не добавит поддержку, а callback secret ведёт в настройку подключения.

Windows-проблемы проверялись отдельно. Проект запускается из корня по пути с кириллицей и пробелами; canonical YAML сохраняет LF и исходный SHA при `core.autocrlf=true`. В ASCII- и Unicode-копиях прошли root launch, demo и реальная HTTP generation/download. Мы не включаем в это утверждение чистую установку Ruby с пустым gem cache и вызов Unicode-скрипта из постороннего cwd.

### Инструкция интегратору и fixtures — E5.2

Generated `INTEGRATION.md` содержит source/servers, review provenance, capabilities, per-operation auth, field mappings, transformations, statuses, error contract, callback policy и manual steps. Там явно указано, какие ENV нужны и какой client contract должен предоставить host.

`fixtures.json` предпочитает реальные examples из OpenAPI. Если example отсутствует, значение строится по schema и получает provenance `schema_generated`; такой fixture не выдаётся за подтверждённый бизнес-сценарий. Callback fixtures фиксируют ожидаемый `approve_operation`, `reject_operation` или отсутствие смены статуса.

Generated инструкция пока на английском. Отдельный generated RSpec отсутствует: fixtures и contract tests проекта не выдаются за него.

### Понятный результат и ошибки — E5.3

Ошибки имеют code, message и location. CLI пишет результат в stdout, ошибки — в stderr и возвращает различимые exit codes. Invalid spec, override или manifest не превращаются в stack trace без контекста.

Compatibility report использует три состояния: READY, NEEDS REVIEW и UNSUPPORTED. Синтетического процента готовности нет. Resolved warnings сохраняются в audit; remediation не делает вид, что каждый warning исправляется override. Canonical report после полного override всё ещё показывает NEEDS REVIEW для webhook secret: secret должен прийти из окружения host-приложения.

## Качество реализации — E6.1–E6.2

### Разделение компонентов — E6.1

Ruby-код разделён на `openapi`, `ir`, `analyzer`, `provider_ir`, `overrides`, `generator` и `web`. Это не просто структура папок. Между слоями есть проверяемые контракты: analyzer читает Generic IR; overrides меняют manifest; generators читают final manifest; `ArtifactBundle` создаёт содержимое; `OutputWriter` публикует его.

Один manifest питает service, docs, fixtures и report, поэтому они не расходятся из-за четырёх независимых интерпретаций YAML. Source SHA, evidence и override audit позволяют восстановить происхождение решения. Большие `Overrides::Applier` и inline service template мы оставляем видимым техническим долгом. Переписывать их перед показом без подтверждённой проблемы было бы рискованнее, чем документировать стоимость расширения и держать contract tests.

Основная логика и backend написаны на Ruby. Web UI — тонкий слой над тем же pipeline; LLM и proprietary dependencies в runtime нет.

### Ошибки и безопасная публикация — E6.2

Validation идёт на нескольких границах. Loader безопасно читает YAML/JSON, document validator проверяет OpenAPI 3.x, ref resolver ловит broken/external/cyclic refs, manifest проверяет required sections, object shapes, capability links и auth requirements. Artifact bundle компилирует Ruby в памяти и повторно читает generated JSON/YAML.

Output writer не записывает результат прямо в целевой каталог. Он создаёт lock и staging directory, проверяет безопасные filenames, записывает все файлы, запускает внешний `ruby -c` и только после успеха переименовывает staging в final output. Существующий target не перезаписывается. Tests проверяют, что при invalid filename, syntax error или malformed manifest частичный результат не публикуется.

Полная semantic validation любого вручную изменённого manifest и полное context-aware Markdown escaping остаются в backlog. Эти ограничения не влияют на проверенный путь через generated final manifest, но мы не выдаём bounded validator за универсальный.

## Что усиливает решение для платёжного домена

Дополнительная ценность здесь не в количестве экранов. Она в пяти поведениях, которые обычно приходится проверять вручную.

Первое — источник idempotency key. Header не считается готовым только потому, что найден в OpenAPI: canonical mapping явно использует стабильный `operation.id`. Это не обещание exactly-once, но это проверяемый контракт передачи ключа.

Второе — подпись callback. Parsed payload и raw signed bytes не смешиваются. Host-required mapping и verified HTTP entrypoint имеют разные гарантии.

Третье — schema-bounded projection. В payout request уходят только разрешённые provider fields, а не весь внутренний объект получателя.

Четвёртое — provenance. Для intent, mapping, amount, status и webhook можно увидеть исходное предложение, override и нерешённые вопросы. Compatibility report собирает эту информацию без выдуманного score.

Пятое — честная remediation. Reviewable ambiguity, runtime configuration, unsupported construct и invalid spec получают разные действия. Ограничение parser не маскируется кнопкой «исправить override».

Локальный UI делает review доступным без ручного чтения большого YAML, но не создаёт отдельную логику. Если UI и CLI дают разный результат, это ошибка; architecture не допускает две версии semantic pipeline.

## Проверенный результат и граница обещаний

После contract/remediation review проходит 134 tests и 792 assertions без failures, errors и skips; отдельно проходят 7 frontend tests. `bin/demo` создаёт три полных bundle; все generated services проходят `ruby -c`. Повторная генерация canonical bundle только из final manifest даёт те же пять файлов по SHA-256. В Windows повторно проверены Unicode-путь с пробелами, запуск локального HTTP server, generation и скачивание.

Тесты исполняют request construction, auth, amount conversion, schema projection, required/nullable behavior, response selection, status/error normalization и callbacks с host/client test doubles. Они не заменяют sandbox конкретного провайдера.

Готовый результат — автономная, reviewable заготовка payout-интеграции для заявленного OpenAPI subset. Для production-подключения остаются credentials, адаптация к фактическому host-приложению, HTTP transport и sandbox verification. Не поддержаны remote/cyclic refs, advanced composition/discriminator, OAuth execution, OpenAPI callbacks keyword, полный runtime JSON Schema validator и per-array-element host mappings. Две alternative specs доказывают структурную универсальность внутри этого scope, но не называются production integrations.

Если сформулировать результат одной фразой: мы переводим OpenAPI не в очередной низкоуровневый SDK, а в проверяемый Ruby payout adapter, где автоматические выводы, решения человека и оставшиеся риски видны до подключения к провайдеру.

## Короткая версия для устного ответа

«Payout Studio принимает OpenAPI YAML или JSON и создаёт пять согласованных файлов: Ruby adapter под `Provider::BaseService`, инструкцию, fixtures, final manifest и compatibility report. Parser сначала строит provider-neutral Generic IR, затем детерминированные rules находят payout operations, auth, statuses, errors, mappings и webhook. Неоднозначные решения не угадываются: они остаются warnings и подтверждаются generic override с audit.

Generated service формирует и отправляет запрос, применяет API key, Bearer или Basic auth, преобразует сумму, проверяет required fields и возвращает provider id в контракте платформы. Fetch/callback меняют terminal status через BaseService-хелперы. Parsed callback аутентифицирует host; отдельный raw-body entrypoint проверяет HMAC. Retry policy и transport остаются границами host-приложения.

Один pipeline проверен на canonical payout API и двух structurally different fixtures: JSON transfer с Bearer и YAML withdrawal с Basic, nested responses и base64 webhook. Результат — 5/2/5 capabilities без выдумывания отсутствующих методов. Финальная suite — 134 tests и 792 assertions плюс 7 frontend tests; три bundles проходят `ruby -c`, а manifest-only generation побайтово совпадает с исходной. Мы заявляем рабочую заготовку для поддержанного subset, а не весь OpenAPI или production certification».

## Отдельно: будущий storyboard финала

Этот блок — только основа будущего deck. Он не задаёт тайминг, монтаж или порядок live demo и не должен попадать в текст третьего чекпоинта без сокращения.

| Слайд | Один тезис | Что показать |
|---|---|---|
| 1. Ручной разрыв | OpenAPI описывает transport, приложению нужен payout contract | spec рядом с host fields/statuses |
| 2. Результат | Один запуск создаёт service, docs, fixtures, manifest и report | список пяти реальных файлов |
| 3. Контроль решений | Structure, inference и human review — разные состояния | pipeline и before/after audit |
| 4. Исполняемый adapter | Request/auth/response/callback работают через host boundary | методы generated Ruby и test double |
| 5. Преобразования | Amount, fields, statuses и required rules становятся runtime behavior | ×100, status table, `required_if`, projection |
| 6. Универсальность | YAML/JSON, API key/Bearer/Basic и разные schemas проходят один core | таблица трёх specs и 5/2/5 |
| 7. Проверки | Contract tests и safe publication отделены от sandbox promise | 123/749, `ruby -c`, manifest byte match |
| 8. Граница готовности | Получена проверяемая заготовка; production требует host/credentials/sandbox | READY/NEEDS REVIEW и короткий список границ |

К этому storyboard возвращаться только после третьего чекпоинта, если команда выйдет на финальную защиту. Тогда перед оформлением deck нужно получить у модератора точный лимит и слот, проверить local UI в фактическом presentation browser и оставить `bin/demo` с готовым bundle как резерв.
