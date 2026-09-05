# Payout Studio — guide для защиты

Актуально на 5 сентября 2026. Основной показ — локальный UI; CLI остаётся резервом. План рассчитан примерно на 5–6 минут, фактический регламент и длительность нужно уточнить на репетиции.

## Вводная: 20 секунд

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

| Шаг | Что показываем и делаем | Что говорим | Критерий и evidence |
|---|---|---|---|
| 1. OpenAPI, 30 сек | В «Обзоре» виден автоматически проанализированный canonical demo и имя `provider_api.yaml`. Нажать «Открыть OpenAPI» и показать `paths`, schemas, security. | «Вход — структурированная спецификация, не вручную заполненная анкета интеграции». | Разбор API: `examples/provider_api.yaml`, parser и Generic IR. |
| 2. Анализ, 40 сек | Вернуться в «Обзор», нажать «Проверить решения». Пять capabilities, endpoints, раскрыть одно «Почему выбрана эта операция». Показать шесть предупреждений. | «Структура извлекается автоматически. Назначение операций определяется правилами с evidence; неоднозначная семантика остаётся видимой». | Parsing / универсальность / UX: manifest, classifier, warnings с исходными code/message/location. Confidence — оценка правил, не вероятность корректности интеграции. |
| 3. Review, 50 сек | «Открыть overrides»: просмотреть подготовленный YAML. Включить «Применить overrides при следующем анализе», нажать «Анализировать». Возврат в обзор: 16 изменений, warnings 6 → 1. | «Открытие файла ничего не подтверждает. Повторный анализ применяет конкретные решения; оставшийся callback secret задаётся в окружении приложения». | Преобразования / качество: generic overrides, audit. NEEDS REVIEW остаётся честным; applied не означает полностью reviewed. |
| 4. Manifest и mappings, 50 сек | «Manifest, audit и готовность»: открыть текущий manifest, историю решений и отчёт совместимости. В «Преобразованиях» показать ×100, статусы и условные требования перед длинными таблицами. | «Один final manifest питает все генераторы. Здесь видно, что изменилось и почему. Сумма, статусы и обязательные поля становятся поведением адаптера». | Преобразования данных: `amount_unit`, status/field mappings, `required_if`, source/reason и before/after audit. |
| 5. Generated integration, 60 сек | «Сгенерировать пакет». В Ruby выбрать «Перейти к методу Ruby» → `create_request`, затем `process_callback`. Открыть `INTEGRATION.md`, `fixtures.json`, читаемый `compatibility_report.md`. Скачать файл и `.tar.gz`. | «Результат — реальные файлы. Запросы, auth, преобразования, ответы и callbacks реализованы в сервисе под документированный host-контракт». | Генерация сервиса / документация: пять файлов из одного manifest. Полный исходник доступен, выпадающий список ведёт к реальным методам. |
| 6. Универсальность, 50 сек | В обзоре выбрать transfer: JSON, Bearer, две обнаруженные возможности и три не заявленные. Затем withdrawal: YAML, Basic, nested payload; применить подготовленный JSON override и повторить анализ: 4 → 5 capabilities, 9 → 1 warnings. | «Другие имена, структуры и способы авторизации проходят тот же pipeline. Отсутствующие операции не выдумываются; неоднозначный status endpoint выбирается явно». | Универсальность: две самостоятельные альтернативные fixtures, один generic core. Transfer также сохраняет реальные mapping/amount/status вопросы; 2/5 не является оценкой качества. |
| 7. Validation и итог, 30 сек | Показать пояснение проверок на экране артефактов и успешный `bin/demo` в резервном терминале. | «До сохранения проверяем manifest, fixtures и Ruby-синтаксис. Тесты исполняют request/response/callback контракты. Для реального подключения остаются credentials, host boundary и sandbox». | Качество реализации: validators/writer, contract tests. `ruby -c` не доказывает связь с реальным провайдером. |

## Показ реальной загрузки файла

Кнопка **«Загрузить свою OpenAPI ↑» находится в «Обзоре», справа от заголовка «Входная спецификация»**. Она открывает системный выбор файла. Выбрать `examples/provider_api.yaml` из репозитория. Альтернатива: «Спецификация» → панель **OpenAPI** → «Загрузить файл ↑».

Загрузка открывает редактор и сбрасывает старые результаты, provider id и overrides. При желании задать «Идентификатор провайдера» = `novapay`, затем «Анализировать». Без id имя определяется из OpenAPI, поэтому имя Ruby-файла может отличаться от preset.

Для подтверждений: «Открыть overrides» → в панели **Overrides — подтверждения и правки** нажать «Загрузить файл ↑» → выбрать `examples/novapay_overrides.yaml`. Загрузка override включает checkbox; повторный анализ всё равно необходим. Не перепутать два file inputs: один принимает OpenAPI, другой — overrides.

После генерации «Скачать файл» сохраняет выбранный артефакт, «Скачать .tar.gz» — все пять. Копия находится в показанном `output/web-<id>/`. Ссылки скачивания действуют в текущем процессе сервера; после перезапуска нужно снова сгенерировать пакет. Уже сохранённые каталоги остаются на диске.

## Если жюри просит код

| Вопрос | Куда перейти | Что это доказывает |
|---|---|---|
| Где разбор и local refs? | `lib/integration_generator/openapi/{parser,ref_resolver,schema_parser}.rb`; `test/openapi/` | Извлечение структуры и явные ошибки вне поддерживаемого subset. |
| Где семантика без AI? | `lib/integration_generator/analyzer/{operation_classifier,capability_resolver,manifest_builder}.rb` | Правила, evidence, confidence и отсутствие provider-specific сценария в generic core. |
| Что меняет override? | `lib/integration_generator/overrides/applier.rb`; текущий audit | Общий контракт YAML/JSON, source/reason, изменения и разрешённые warnings. |
| Сервис действительно выполняет преобразования? | Generated `build_request`, `transform_value`, `apply_auth`, `normalize_response`, `process_callback`; `test/generator/generated_service_contract_test.rb` | Request/response/auth/status/amount/callback поведение, проверенное с host test double. |
| Где nested payload и защита host-полей? | Generated `project_to_provider_schema`, `validate_required_body!`; `test/generator/alt_withdrawal_service_contract_test.rb`, `review_regressions_test.rb` | Schema projection и проверки итогового body. Это консервативная политика экспорта host-модели. |
| Генераторы зависят от YAML? | `lib/integration_generator/generator/artifact_bundle.rb`; CLI `generate --manifest` | Генерация из final manifest, без чтения OpenAPI генераторами. |
| Где проверка перед записью? | `lib/integration_generator/generator/output_writer.rb`; `test/generator/output_writer_test.rb` | Валидация, `ruby -c`, новый каталог без перезаписи результата. |

## Границы обещаний

Уточнение после review 2026-09-05: `process_callback(payload)` принимает parsed Hash и возвращает `signature_verification: :host_required` — аутентификация остаётся хосту. Для показа HMAC открывайте `process_verified_callback(raw_body, headers:)`. Актуальные проверки: 123 tests/749 assertions, три bundles и ASCII/Unicode Windows HTTP flow — [REVIEW_REPORT.md](REVIEW_REPORT.md). Сценарий ниже/выше сохранён как исходный материал; тайминг и видео отложены по текущему плану.

Поддерживается заявленный в README subset OpenAPI 3.x с local refs. Не заявляем весь OpenAPI/JSON Schema, remote refs, OAuth runtime, OpenAPI callbacks keyword, production certification или точное совпадение с недоступным production host. Обычный webhook POST поддержан. Generated RSpec-файл пока не создаётся; runtime contract tests самого проекта есть. Полный JSON Schema validator в generated runtime не реализован.

## Исторические проверки финального polish до ревью

- Ruby suite: **96 tests, 609 assertions**, без failures/errors/skips.
- `bin/demo`: три providers с пятью артефактами каждый, `ruby -c` успешен; прогон `output/demo-20260905-18768-blhtfb/`.
- Browser: canonical file upload + override upload → анализ → генерация; реальные скачивания Ruby и tar.gz сохранены в Downloads. Все пять членов архива побайтово совпали с `output/web-2bc7d4b2dde6eb0a/`; отдельный Ruby совпал тоже.
- Browser: partial withdrawal override сохраняет 4 → 4 и 9 → 9, без ложного «проверено»; full override — 4 → 5 и 9 → 1. Оба alternative providers сгенерированы через UI.
- Malformed input блокирует generation; переход к реальному Ruby-методу работает. Осмотр 1366×768, 1024×768 и 390×844; на проверенных узких экранах нет горизонтального overflow страницы, ×100 не разваливается.
- Автоматизация доступна во встроенном браузере Codex. **Отдельный Chrome не подключён и не считается проверенным.** Осталась короткая репетиция на фактическом браузере и проекторе перед выступлением.

Оригиналы кейса и Q&A найдены локально у команды и сверены 5 сентября: `описание (1).docx`, `qa_сессия.txt`, `вступление.txt`, `Важно_проектирование_инфраструктуры.docx`. В репозиторий они не входят. Описание подтверждает веса и арифметическую нестыковку технической таблицы: строки дают 103, хотя итог указан как 100. Вступление подтверждает общее окно защит 8 сентября 17:00–19:00, но не длительность и слот конкретной команды. Перед финальным deck обязательно получить у модератора точный лимит/слот и актуальную инструкцию по передаче репозитория; отдельный файл регламента в проверенных локальных папках не найден. Содержательная структура защиты — в [PRESENTATION_CONTENT.md](PRESENTATION_CONTENT.md).
