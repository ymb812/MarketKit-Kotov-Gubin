# Ревью перед третьим чекпоинтом

Дата: 2026-09-05. Основа — [CRITERIA_MATRIX.md](CRITERIA_MATRIX.md), новые Q&A и история установки коллеги. Проверяется заявленный OpenAPI subset и generated adapter; production-подключение к реальному провайдеру и весь стандарт OpenAPI не заявляются.

**Статус: этап 2 завершён для заявленного subset.** Исправлены и проверены R1–R10; новые блокеры в проверенных сценариях не обнаружены. Финальная suite: **123 tests / 749 assertions, 0 failures/errors/skips** (до изменений — 96/609). Можно переходить к этапу 3 — документации для жюри. Это не подтверждение полного OpenAPI или production-интеграции; оставшиеся границы перечислены ниже.

## Существенные находки и решения

| ID | Критерии | Проблема и доказательство | Исправление / проверка |
|---|---|---|---|
| R1 | E5.1, E6.2 | В Windows пути с кириллицей Ruby искажает script path/LOAD_PATH; исходные entrypoints не загружаются. Кириллическое имя загружаемого файла в UI — другой сценарий. | Точки запуска/bootstrap используют валидный путь к скрипту, а при его искажении — UTF-8 cwd корня проекта. Проверяется отдельно от SHA-256. [entrypoints tests](test/entrypoints_test.rb), подробности итоговой Windows-проверки ниже. |
| R2 | E5.1, E6.2 | `core.autocrlf=true` меняет байты canonical input и ломает его SHA-256. Это не сбой semantic analyzer. | Сохранено ранее добавленное правило `.gitattributes`: canonical YAML `text eol=lf`; содержимое official YAML и ожидаемый SHA не менялись. Проверяется candidate checkout без коммита. |
| R3 | E2.3, T2.1 | Q&A задаёт parsed JSON для `process_callback`, а старый публичный путь требует raw body даже для обычного mapping. | `process_callback(Hash)` возвращает `signature_verification: :host_required`. `process_verified_callback(raw_body, headers:)` проверяет HMAC и обрабатывает подписанное тело. Старый вызов с raw-body kwargs сохраняется. Это явная граница host authentication, не заявление о проверенной подписи parsed payload. [contract tests](test/generator/generated_service_contract_test.rb). |
| R4 | E2.2, E3.1 | `default`, объявленный раньше HTTP 402/4XX, выбирается первым и маскирует конкретную schema ошибки. | Выбор exact → range → default; [runtime tests](test/generator/runtime_review_test.rb) проверяют разные вложенные code/message paths, HTTP status, `Retry-After`, malformed JSON и HTTP 400/401/402/422/429/500. |
| R5 | E1.1, E2.2, E3.1 | Первый успешный response определяет все mappings; `204` перед JSON `201` теряет id/status, разные 2xx schemas смешиваются. | Analyzer сохраняет mappings всех exact/range success responses. Runtime выбирает schema по фактическому status, exact имеет приоритет над range даже без body. Fixtures согласованы с выбранным response; error fixture не получает expected success mapping. [runtime tests](test/generator/runtime_review_test.rb), [analyzer tests](test/analyzer/review_contracts_test.rb). |
| R6 | E1.2, E2.1, E4.1 | Два apiKey в AND получают один ENV; OR выбирает первый поддержанный вариант даже без его credentials. | Имена ENV различаются при коллизии типов, одиночные имена сохраняются. Выбирается первый поддержанный полностью настроенный OR-вариант; все элементы AND обязательны. Docs показывают группы по операциям. [runtime tests](test/generator/runtime_review_test.rb), [analyzer tests](test/analyzer/review_contracts_test.rb). |
| R7 | E3.2 | Required nullable field не отличает отсутствующий host key от явного nil; итоговый JSON null пропадает. | Сохраняется explicit nil только для nullable body mapping с существующим source; отсутствие required key блокируется, optional omission сохраняется. `false` не теряется. Точность amount и отдельная ошибка fractional minor unit проверены. [regressions](test/generator/review_regressions_test.rb), [runtime tests](test/generator/runtime_review_test.rb). |
| R8 | E1.1, E1.2, E3.2 | readOnly-поля требуют во входящем request; writeOnly-поля участвуют в response/status mappings. Error response status enum ошибочно становится payout lifecycle. | Направление учитывается в semantic traversal, request projection/required checks и schema-generated fixtures; lifecycle берётся из успешных responses и callback payload, error facts — отдельно. Generic IR сохраняет исходные flags. [analyzer tests](test/analyzer/review_contracts_test.rb), [runtime tests](test/generator/runtime_review_test.rb). |
| R9 | E2.1, E3.1, E4.1 | `merchant_id` и `payout_id` в scoped endpoint распознавались как один provider_operation_id с высокой confidence. | Только payout-like ID имеет автоматический источник; остальные параметры сохраняются как unmapped/review с общим override. Несколько payout-id кандидатов требуют review. [analyzer tests](test/analyzer/review_contracts_test.rb). |
| R10 | E2.1, E6.2 | Prebuilt manifest без auth entry операции проходит validation и генерирует запрос без auth; `[nil]` в операциях/mappings вызывает необработанное исключение. | Валидируются auth references/requirements, object shapes вложенных коллекций, webhook config и другие потребляемые shapes; loader возвращает `MANIFEST_INVALID`. [validation tests](test/provider_ir/runtime_validation_test.rb). |

Main agent самостоятельно проверил критичные участки service generation, contract tests, auth/manifest guards и analyzer changes после результатов subagents. Подробные reproduction scripts и временные Windows checkouts остаются в ignored `output/`; регрессии перенесены в обычные tests.

## Уточнения Q&A и инженерные границы

- Provider operation id возвращается в нормализованном ответе; сохранение — ответственность хоста. Запросы проходят через абстрактный client; реальная сеть и credentials провайдера для тестов не требуются.
- Маппинг из оригинального задания подтверждён: pending/processing→in_progress, completed→approved, failed/cancelled→rejected. `accepted` в найденной таблице отсутствует и остаётся unknown без явного решения.
- Payload status path задаёт status mapping; event возвращается отдельно. Противоречие event/status не разрешается выдуманным утверждением о правилах провайдера: текущее правило выбора явно документировано. Иная бизнес-политика остаётся настройкой host/provider contract.
- Пример задания HTTP 402→insufficient_balance/retry later не означает, что генератор должен самостоятельно повторно отправлять выплату. Он возвращает error facts; retry/block/alert — действия хоста. Эта граница описана в README/generated docs.
- Для HTTP response precedence, readOnly/writeOnly и AND/OR семантики сверена [официальная OpenAPI 3.0.3](https://spec.openapis.org/oas/v3.0.3.html). Это техническая проверка поддержанного стандарта, не новое требование организаторов.

## Q1–Q8 после ревью

| Вопрос | Результат |
|---|---|
| Q1 установка | R1/R2 проверены в отдельных ASCII и Unicode+spaces candidate checkouts; HTTP start/generation/download PASS. Один skip в Unicode suite — запуск скрипта из другого cwd; документирован запуск из корня проекта. Коммитов нет, передача должна включать `.gitattributes` и новые tests. |
| Q2 callback | R3, контракты разделены и проверены targeted tests; docs/fixtures/UI обновлены. |
| Q3 статусы/errors | R4/R5 и новые runtime tests; host policy и неизвестная семантика обозначены явно. |
| Q4 formats/required | R7/R8. Scalar enum/pattern/min/max/format остаются извлечёнными constraints; полного runtime JSON Schema validator нет. |
| Q5 validation/output | R10, syntax-before-publication и no-overwrite проверяются suite. Полная semantic validation любого hand-edited manifest и полное контекстное Markdown escaping не заявляются. |
| Q6 универсальность | Три demo-specs + мутации canonical input для scoped IDs, response variants, AND/OR, readOnly/writeOnly. Это больше независимых комбинаций, но не реальные публичные provider integrations. |
| Q7 docs | Исправлены противоречия callback/auth/error boundary и добавлены setup пояснения. Полный judge-facing guide/карта модулей — следующий этап 3. |
| Q8 архитектура | Manifest-only boundary сохранён; генератор не читает OpenAPI. Большие Applier/template не переписывались: исправления локальны, зависимые слои проверяются вместе. Руководство по расширению — этап 3. |

## Проверки

Проверено main agent после интеграции:

- `bundle exec rake test`: **123 runs, 749 assertions, 0 failures/errors/skips**, seed 36967. Включает canonical/alternate generator contracts, analyzer tests, CLI/web tests и негативные случаи. Перед исправлениями — 96/609.
- `bundle exec ruby bin/demo`: PASS, root `output/demo-20260905-13216-b6uy96`, по 5 файлов для novapay/alt_transfer/alt_withdrawal; `ruby -c` всех services PASS; capabilities 5/2/5, withdrawal fetch review transition сохранён. NEEDS REVIEW не скрыт.
- `generate --manifest` из final NovaPay manifest: PASS, `output/review-manifest-only-20260905`; SHA-256 всех 5 файлов совпал с исходным bundle. Ни входной YAML, ни override генератору не передавались.
- `node --check web/app.js`: PASS; `node --test test/web/frontend_test.js`: **4 pass**. Node использован только для development QA.
- `git diff --check`, `git diff --cached --check`: PASS. `rg -i novapay lib`: совпадений нет. Это дополнительная проверка к архитектурному анализу, не самостоятельное доказательство generic поведения.
- Новые fixtures/docs прочитаны: parsed callback/host_required и verified HTTP boundary согласованы; docs показывают per-operation AND/OR; canonical error table сохраняет `error.code` и пример `insufficient_balance`.

### Windows воспроизведение и результат

Ранее agent воспроизвёл на HEAD кириллический LoadError и SHA drift при CRLF. После доработки bootstrap main agent создал две отдельные копии: `output/review-ascii-20260905-231711` и `output/review-кириллица путь-20260905-231711`.

Это **candidate snapshots, не опубликованный коммит**: clone HEAD `723adf6`, `core.autocrlf=true`, копирование candidate `.gitattributes` **до** checkout и затем наложение текущих 85 source files. До наложения sources Git уже создал canonical YAML с `i/lf w/lf`, SHA-256 `415f50ee36fb331dfab49ceed0e8ed3b0ebe16053d7e00dbabd32282f4396551` в обеих копиях. Main index/история Git не менялись. Копии используют установленный Ruby/Bundler и уже доступные gems; установка Ruby с нуля или чистый gem cache не проверялись.

- ASCII: `bundle check`, `bin/integrate --help`, полный `bin/demo` PASS.
- Unicode+spaces: `bundle check`, `bundle exec rake test` **122 runs / 742 assertions, 0 failures/errors, 1 skip**, полный `bin/demo` PASS. Snapshot снят перед добавлением последнего scoped-path runtime test; product code совпадает с финальным. Skip явно относится к вызову Unicode-скрипта из постороннего cwd, а не запуску из корня. Финальная main suite с этим дополнительным тестом — 123/749 без skips.
- В обоих путях настоящий `bundle exec ruby bin/serve --port <свободный порт>` запущен скрытым процессом: `GET /` и `/api/examples` PASS, каталог из 3 примеров; POST canonical generation создал 5 файлов; GET Ruby download побайтово совпал с output. Созданные процессы остановлены.
- Технические записи: `output/review-candidate-proof.json`, `output/review-http-smoke.json`. HTTP bundles: ASCII `output/web-5188c1a574bf04fd`, Unicode `output/web-5bc5f9c465b21294` внутри соответствующих snapshots. SHA downloaded service в обоих случаях `92d3ef47ae50cccea1bc36aa746963335552f2e7ab34e66a01e95481724f3a8a`.

После включения исправлений пользователем в передаваемую версию полезен финальный clone smoke на фактической машине показа. Перенос проекта в ASCII больше не требуется для проверенного сценария запуска из корня.

## Оставшиеся ограничения

1. External/cyclic refs, advanced composition/discriminator, callbacks/top-level webhooks, OAuth execution и полный JSON Schema runtime validator остаются вне заявленного subset; обнаруживаются либо отклоняются явно.
2. Parameter serialization `style/explode`, произвольные media types и per-item host mappings не объявляются полностью поддержанными. Whole-array projection требует известной items schema.
3. Не выполнено реальное подключение к production BaseService/HTTP transport/sandbox; локальный harness проверяет документированный adapter boundary.
4. Authentication parsed callback выполняет хост; сам mapping не доказывает подпись. NEEDS REVIEW для callback secret сохранён и не маскируется под production-ready.
5. Generated RSpec, полный validator/escaping и дополнительный публичный provider example не удаляются из backlog. Следующий ближайший результат — документация для жюри, а не автоматическое расширение core.

## Subagents

- `review_parser`: parser/analyzers/overrides, response/auth/direction/scoped-ID correctness; GPT-5.6 Sol / high.
- `review_runtime`: runtime/fixtures/manifest review и bounded manifest validation; GPT-5.6 Sol / high.
- `review_windows`: Windows reproduction, entrypoint/bootstrap fixes и candidate checkout; GPT-5.6 Terra / high.

Model/effort заданы явно по AGENTS.md: Sol использован для сложного correctness-review, Terra — для отдельного Windows-прохода. Зоны записи разделены; архитектурные решения, интеграция и документы остаются у main agent. Subagents не создавали собственных subagents. Коммитов и изменений main index не делали.

Завершающий turn Windows subagent прервался из-за лимита usage; main agent самостоятельно завершил candidate checkout, suite и HTTP smoke. Оставшиеся analyzer edits, интеграционные tests и финальная верификация также закончены main agent; незавершённые ответы subagents не приняты за доказательство готовности.
