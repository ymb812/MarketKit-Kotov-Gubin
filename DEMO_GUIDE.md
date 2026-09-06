# Payout Studio — guide для защиты

Актуально на 6 сентября 2026. Для третьего чекпоинта этот сценарий записывается как экранное видео; команда рассказывает текст из `PRESENTATION_CONTENT.md` на его фоне. Slide deck не нужен. Основной видеоряд — локальный UI, CLI остаётся резервом.

> **Регламент: 8 минут.** Монтаж и текст заканчиваются к 7:35; оставшиеся 25 секунд — резерв на паузы и переходы. После записи один раз синхронно прочитать весь текст и при необходимости сокращать кадры вместе с репликами.

## Вводная — входит в 0:00–0:50

«При подключении платёжного провайдера разработчик вручную переводит его API в контракт своего приложения. По условию кейса такая работа занимает 2–5 дней. Мы принимаем OpenAPI YAML или JSON и создаём заготовку Ruby payout-интеграции: сервис, инструкцию, примеры и проверяемую историю решений. Сейчас покажем путь от входного файла до скачанного пакета».

Не обещать измеренное сокращение production-интеграции до нескольких секунд: измеряется генерация заготовки, а не подключение реального провайдера.

## Подготовка

```powershell
bundle check
bundle exec ruby bin/serve
```

Открыть http://127.0.0.1:9292. Сервер должен продолжать работать в терминале. При необходимости сначала выполнить `bundle install`. Runtime не требует Node, LLM, CDN или внешних API.

Резервный прогон в другом терминале:

```powershell
bundle exec ruby bin/demo
```

Он создаёт новый уникальный каталог в `output/`, генерирует три пакета и проверяет Ruby. Сохранить напечатанный путь для выступления. Повторные запуски не требуют удаления старых результатов.

## Основной demo flow

| Время | Шаг | Что показываем и делаем | Что говорим | Критерий и evidence |
|---|---|---|---|---|
| 0:00–0:50 | 1. OpenAPI | В «Обзоре» виден автоматически проанализированный canonical demo и имя `provider_api.yaml`. Нажать «Открыть OpenAPI» и показать `paths`, schemas, security. | «Вход — структурированная спецификация, не вручную заполненная анкета интеграции». | Разбор API: `examples/provider_api.yaml`, parser и Generic IR. |
| 0:50–1:45 | 2. Анализ | Вернуться в «Обзор», нажать «Проверить решения». Пять capabilities, endpoints, раскрыть одно «Почему выбрана эта операция». Показать восемь предупреждений и групповые счётчики. | «Структура извлекается автоматически. Reviewable решения, ручная настройка и ограничения получают разные действия». | Parsing / универсальность / UX: manifest, classifier и backend remediation metadata. Confidence — оценка правил, не вероятность production-корректности. |
| 1:45–2:45 | 3. Review | «Открыть overrides»: просмотреть подготовленный YAML. Включить «Применить overrides при следующем анализе», нажать «Анализировать». Возврат в обзор: 18 изменений, warnings 8 → 1. Оставшаяся кнопка ведёт в «Подключение», а не в overrides. | «Открытие файла ничего не подтверждает. Повторный анализ применяет конкретные решения; callback secret задаётся в окружении приложения». | Generic overrides, audit и честная remediation. NEEDS REVIEW остаётся; applied не означает полностью reviewed. |
| 2:45–3:45 | 4. Manifest и mappings | «Manifest, audit и готовность»: открыть текущий manifest, историю решений и отчёт совместимости. В «Преобразованиях» показать ×100, статусы и условные требования перед длинными таблицами. | «Один final manifest питает все генераторы. Здесь видно, что изменилось и почему. Сумма, статусы и обязательные поля становятся поведением адаптера». | Преобразования данных: `amount_unit`, status/field mappings, `required_if`, source/reason и before/after audit. |
| 3:45–5:15 | 5. Generated integration | «Сгенерировать пакет». В Ruby перейти к `create_request`, затем `process_callback`. Показать `success(result: { id: ... })`, `failure`, `approve_operation` / `reject_operation`. Открыть `INTEGRATION.md`, `fixtures.json`, report и скачать `.tar.gz`. | «Generated service следует платформенному контракту: id возвращается из create, terminal status меняют helpers». | Пять файлов из одного manifest; dropdown ведёт к реальным методам. |
| 5:15–6:30 | 6. Универсальность | Выбрать transfer: JSON, Bearer, две возможности и три не заявленные. Затем withdrawal: YAML, Basic, nested payload; применить JSON override: 4 → 5 capabilities, 11 → 1 warnings. | «Другие имена, структуры и auth проходят тот же pipeline. Отсутствующие операции не выдумываются». | Две самостоятельные alternative fixtures, один generic core. |
| 6:30–7:35 | 7. Validation и итог | Показать пояснение проверок на экране артефактов и успешный `bin/demo` в резервном терминале. | «До сохранения проверяем manifest, fixtures и Ruby-синтаксис. Тесты исполняют request/response/callback контракты. Для реального подключения остаются credentials, host boundary и sandbox». | Качество реализации: validators/writer, contract tests. `ruby -c` не доказывает связь с реальным провайдером. |
| 7:35–8:00 | Резерв | Остаться на финальном экране с пятью файлами; не начинать новую демонстрацию. | Только пауза или короткое завершение, если основной текст уже закончен. | Буфер, а не новый claim. |

## Показ реальной загрузки файла

Кнопка **«Загрузить свою OpenAPI ↑» находится в «Обзоре», справа от заголовка «Входная спецификация»**. Она открывает системный выбор файла. Выбрать `examples/provider_api.yaml` из репозитория. Альтернатива: «Спецификация» → панель **OpenAPI** → «Загрузить файл ↑».

Загрузка открывает редактор и сбрасывает старые результаты, provider id и overrides. При желании задать «Идентификатор провайдера» = `novapay`, затем «Анализировать». Без id имя определяется из OpenAPI, поэтому имя Ruby-файла может отличаться от preset.

Для подтверждений: «Открыть overrides» → в панели **Overrides — подтверждения и правки** нажать «Загрузить файл ↑» → выбрать `examples/novapay_overrides.yaml`. Загрузка override включает checkbox; повторный анализ всё равно необходим. Не перепутать два file inputs: один принимает OpenAPI, другой — overrides.

После генерации «Скачать файл» сохраняет выбранный артефакт, «Скачать .tar.gz» — все пять. Копия находится в показанном `output/web-<id>/`. Ссылки скачивания действуют в текущем процессе сервера; после перезапуска нужно снова сгенерировать пакет. Уже сохранённые каталоги остаются на диске.

## Короткий показ навигации по unsupported warning

Для ответа на вопрос жюри про `oneOf` можно временно добавить ключ `oneOf` в одну schema canonical OpenAPI и повторить анализ. Карточка должна иметь тип «Ограничение», прямо сообщать, что override не добавит поддержку, показывать исходную строку и по кнопке выделять её в редакторе. Если одинаковый ключ встречается несколько раз и точное место нельзя определить безопасно, редактор откроется без ложной подсветки; полный location останется в карточке. После показа заново выберите canonical demo, чтобы восстановить исходный текст.

## Если жюри просит код

| Вопрос | Куда перейти | Что это доказывает |
|---|---|---|
| Где разбор и local refs? | `lib/integration_generator/openapi/{parser,ref_resolver,schema_parser}.rb`; `test/openapi/` | Извлечение структуры и явные ошибки вне поддерживаемого subset. |
| Где семантика без AI? | `lib/integration_generator/analyzer/{operation_classifier,capability_resolver,manifest_builder}.rb` | Правила, evidence, confidence и отсутствие provider-specific сценария в generic core. |
| Что меняет override? | `lib/integration_generator/overrides/applier.rb`; текущий audit | `operation.*`, `request_method` или scalar `value`, source/reason, изменения и разрешённые warnings. |
| Почему не каждый warning ведёт в override? | `lib/integration_generator/diagnostic_remediation.rb`; warning cards; `test/diagnostic_remediation_test.rb` | Четыре класса remediation и безопасный source jump для unsupported/invalid spec. |
| Сервис действительно выполняет преобразования? | Generated `build_request`, `transform_value`, `apply_auth`, `normalize_response`, `process_callback`; `test/generator/generated_service_contract_test.rb` | Request/response/auth/status/amount/callback поведение, проверенное с host test double. |
| Где nested payload и защита host-полей? | Generated `project_to_provider_schema`, `validate_required_body!`; `test/generator/alt_withdrawal_service_contract_test.rb`, `review_regressions_test.rb` | Schema projection и проверки итогового body. Это консервативная политика экспорта host-модели. |
| Генераторы зависят от YAML? | `lib/integration_generator/generator/artifact_bundle.rb`; CLI `generate --manifest` | Генерация из final manifest, без чтения OpenAPI генераторами. |
| Где проверка перед записью? | `lib/integration_generator/generator/output_writer.rb`; `test/generator/output_writer_test.rb` | Валидация, `ruby -c`, новый каталог без перезаписи результата. |

## Границы обещаний

`create_request` возвращает `success(result: { id: provider_id })`. `fetch_status` и `process_callback` применяют terminal status через BaseService helpers; parsed callback должен быть аутентифицирован хостом. Для показа HMAC открывайте `process_verified_callback(raw_body, headers:)`. Актуальные числа проверок находятся в [JURY_GUIDE.md](JURY_GUIDE.md). После итогового readiness-review остаётся записать видеоряд и один раз синхронизировать его с устным текстом.

Поддерживается заявленный в README subset OpenAPI 3.x с local refs. Не заявляем весь OpenAPI/JSON Schema, remote refs, OAuth runtime, OpenAPI callbacks keyword, production certification или точное совпадение с недоступным production host. Обычный webhook POST поддержан. Generated RSpec-файл пока не создаётся; runtime contract tests самого проекта есть. Полный JSON Schema validator в generated runtime не реализован.

## Последняя проверка текущей версии

- Ruby suite: **134 tests, 792 assertions**, без failures/errors/skips; frontend logic: **7/7**, `node --check` — PASS.
- `bin/demo`: три providers с пятью артефактами каждый, `ruby -c` успешен; предфинальный прогон `output/prefinal-20260906-105139/`.
- Manifest-only replay: все пять файлов NovaPay побайтово совпали по SHA-256 с bundle из OpenAPI.
- Browser: canonical override оставляет только callback-secret настройку; generation/download совпали по пяти файлам; `oneOf` показывается как ограничение без CTA в Overrides, а broken `$ref` ведёт к точному исходному фрагменту.
- Windows: из корня `HackGenesis проверка 20260906-1010` запущен локальный HTTP server; сгенерированы пять файлов, Ruby и tar.gz скачаны с HTTP 200, байты Ruby совпали с API artifact.
- Автоматизация проверена во встроенном браузере Codex. **Отдельный Chrome не подключён и не считается проверенным.** Для третьего чекпоинта достаточно проверить фактический браузер записи и итоговый видеофайл; проектор и slide deck относятся к возможной финальной защите.

Оригиналы кейса и Q&A найдены локально у команды и сверены 5 сентября: `описание (1).docx`, `qa_сессия.txt`, `вступление.txt`, `Важно_проектирование_инфраструктуры.docx`. В репозиторий они не входят. Описание подтверждает веса и арифметическую нестыковку технической таблицы: строки дают 103, хотя итог указан как 100. Вступление подтверждает общее окно защит 8 сентября 17:00–19:00; лимит текущего выступления позднее уточнён пользователем как 8 минут. Перед финальным deck нужно отдельно уточнить его регламент и актуальную инструкцию по передаче репозитория. Содержательная структура текущего выступления — в [PRESENTATION_CONTENT.md](PRESENTATION_CONTENT.md).
