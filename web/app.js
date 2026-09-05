"use strict";

const $ = (id) => document.getElementById(id);
const state = { examples: [], selected: null, result: null, generated: null, busy: false, file: null, overrideFilename: "overrides.yaml", revision: 0 };
const capabilities = {
  create_payout: ["Создание выплаты", "+"], fetch_status: ["Статус операции", "↗"],
  cancel_payout: ["Отмена выплаты", "×"], webhook: ["Входящие уведомления", "⌁"], balance: ["Баланс провайдера", "≋"]
};
const viewNames = { overview: "Обзор", source: "Спецификация", mappings: "Преобразования", webhook: "Подключение", artifacts: "Артефакты" };
const statusNames = { detected: "Обнаружено", requires_review: "Проверить", missing: "Не заявлено", ready: "READY", needs_review: "NEEDS REVIEW", unsupported: "UNSUPPORTED" };
const e = (value) => String(value ?? "—").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
const code = (value) => `<code>${e(value)}</code>`;
const pill = (status, text) => `<span class="pill ${["detected", "ready"].includes(status) ? "good" : ["missing", "unsupported"].includes(status) ? "missing" : "review"}">${e(text ?? statusNames[status] ?? status)}</span>`;
const table = (headers, rows) => `<div class="table-scroll"><table class="data-table"><thead><tr>${headers.map((h) => `<th scope="col">${e(h)}</th>`).join("")}</tr></thead><tbody>${rows.length ? rows.map((row) => `<tr>${row.map((cell) => `<td>${cell}</td>`).join("")}</tr>`).join("") : `<tr><td colspan="${headers.length}">Не заявлено в спецификации</td></tr>`}</tbody></table></div>`;
const panel = (title, body, label = "") => `<article class="panel"><div class="panel-heading"><h2>${e(title)}</h2>${label}</div>${body}</article>`;
const kv = (pairs) => `<dl class="kv-grid">${pairs.map(([key, value]) => `<div><dt>${e(key)}</dt><dd>${e(value)}</dd></div>`).join("")}</dl>`;

// Presentation only: readiness itself is supplied by the Ruby compatibility report.
function reviewSummary(result) {
  const manifest = result.manifest;
  const warnings = manifest.warnings;
  const changes = manifest.overrides?.applied_changes?.length ?? 0;
  const applied = manifest.overrides?.applied;
  const ready = result.overall_status === "ready";
  const prefix = applied ? `Override применён: ${changes} изменений. ` : "Сопоставления предложены анализатором. ";
  const onlySecret = warnings.length > 0 && warnings.every((w) => w.code === "CALLBACK_SECRET_NOT_DECLARED");
  const detail = ready
    ? "Контракт готов к генерации. Credentials и проверка в sandbox остаются задачей подключения."
    : onlySecret
      ? "Остаётся предупреждение о callback secret: задайте его в окружении host-приложения. Подробная готовность — в отчёте совместимости."
      : `Открытых предупреждений: ${warnings.length}. Проверьте решения и отчёт совместимости; генерация создаст заготовку с этими ограничениями.`;
  return { ready, text: prefix + detail };
}

const warningHelp = {
  STATUS_MAPPING_DEFAULT_RULES_APPLIED: ["Проверьте смысл статусов", "Подтвердите сопоставления статусов в overrides.", "mappings"],
  CALLBACK_SECRET_NOT_DECLARED: ["Настройте секрет уведомлений", "Callback secret задаётся в окружении host-приложения при подключении.", "webhook"],
  WEBHOOK_SIGNATURE_ENCODING_UNKNOWN: ["Уточните формат подписи", "Подтвердите encoding в overrides по документации провайдера.", "webhook"],
  WEBHOOK_SIGNATURE_ALGORITHM_UNKNOWN: ["Уточните алгоритм подписи", "Выберите подтверждённый алгоритм в overrides.", "webhook"],
  IDEMPOTENCY_SOURCE_REQUIRES_REVIEW: ["Укажите источник ключа идемпотентности", "Свяжите header с явным полем внутренней операции через override.", "mappings"],
  CONDITIONAL_REQUIREMENT_INFERRED: ["Подтвердите условное требование", "Условие найдено в описании. Проверьте его и подтвердите через overrides.", "mappings"],
  MISSING_CAPABILITY: ["Возможность не найдена", "Проверьте состав API. Отсутствующие операции не генерируются как доступные.", "overview"],
  AMBIGUOUS_CAPABILITY: ["Нужно выбрать операцию", "Проверьте evidence и укажите intent операции в overrides.", "source"],
  REQUEST_PARAMETER_MAPPING_NOT_FOUND: ["Нужен источник параметра", "Укажите host source для параметра запроса в overrides.", "mappings"],
  AMOUNT_UNIT_AMBIGUOUS: ["Уточните единицы суммы", "Подтвердите unit и преобразование по контракту провайдера.", "mappings"],
  PROVIDER_ERROR_CODE_NOT_FOUND: ["Код ошибки не заявлен", "Доступен HTTP-ответ; проверьте error contract и настройку host-обработки.", "webhook"]
};

function renderWarnings(warnings) {
  return warnings.length ? warnings.map((warning) => {
    const [title, action, view] = warningHelp[warning.code] ?? ["Проверьте ограничение спецификации", "Сверьте исходные данные и описание диагностики ниже.", "source"];
    return `<div class="warning-row"><span class="warning-icon" aria-hidden="true">△</span><div><strong>${e(title)}</strong><p>${e(action)}</p><details><summary>${e(warning.code)}</summary><p>${e(warning.message)}</p><code>${e(warning.location)}</code></details><button class="text-button" data-view="${view}">Открыть раздел →</button></div></div>`;
  }).join("") : '<div class="empty-inline">Открытых предупреждений нет. Credentials задаются при подключении.</div>';
}

// Render a small, escaped Markdown subset used by our generated reports.
// The original file remains available; input HTML and links never execute.
function readableMarkdown(source) {
  const inline = (text) => e(text).replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  const lines = source.split("\n");
  let html = "";
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith("```")) {
      const block = [];
      while (++i < lines.length && !lines[i].startsWith("```")) block.push(lines[i]);
      html += `<pre>${e(block.join("\n"))}</pre>`;
    } else if (line.startsWith("|")) {
      const rows = [];
      do {
        if (!/^\|[\s|:\-]+\|\s*$/.test(lines[i])) rows.push(lines[i].trim().slice(1, -1).split("|").map((cell) => inline(cell.trim())));
        i++;
      } while (i < lines.length && lines[i].startsWith("|"));
      i--;
      html += `<div class="table-scroll"><table class="data-table"><thead><tr>${rows.shift().map((cell) => `<th>${cell}</th>`).join("")}</tr></thead><tbody>${rows.map((row) => `<tr>${row.map((cell) => `<td>${cell}</td>`).join("")}</tr>`).join("")}</tbody></table></div>`;
    } else if (/^#{1,3} /.test(line)) {
      html += `<h3>${inline(line.replace(/^#+ /, ""))}</h3>`;
    } else if (line.trim()) html += `<p>${inline(line)}</p>`;
  }
  return html;
}

function renderReviewData(manifest) {
  const audit = manifest.overrides;
  $("review-data").hidden = false;
  $("manifest-preview").textContent = JSON.stringify(manifest, null, 2);
  $("compatibility-preview").innerHTML = readableMarkdown(state.result.compatibility_report);
  $("audit-content").innerHTML = audit?.applied
    ? kv([["Источник решения", audit.source], ["Причина", audit.reason]]) + "<p>Первые изменения; все решения доступны в полном audit ниже.</p>" + table(["Изменение", "До", "После"], (audit.applied_changes ?? []).slice(0, 6).map((change) => [code(change.location ?? change.path ?? change.target ?? change.section), code(JSON.stringify(change.before)), code(JSON.stringify(change.after))])) + `<details><summary>Все изменения и разрешённые предупреждения — полный audit</summary><pre>${e(JSON.stringify(audit, null, 2))}</pre></details>`
    : '<p>Overrides ещё не применялись. Здесь появятся источник, причина и история изменений.</p>';
}

function showView(view) {
  if (!viewNames[view]) return;
  document.querySelectorAll(".view").forEach((section) => { section.hidden = section.id !== `view-${view}`; });
  document.querySelectorAll(".nav-item").forEach((button) => {
    const active = button.dataset.view === view;
    button.classList.toggle("active", active);
    if (active) button.setAttribute("aria-current", "page"); else button.removeAttribute("aria-current");
  });
  $("breadcrumb").textContent = viewNames[view];
  $("main").focus({ preventScroll: true });
  window.scrollTo({ top: 0, behavior: "instant" });
}

function setBusy(busy, message) {
  state.busy = busy;
  $("activity").classList.toggle("busy", busy);
  if (message) $("activity").textContent = message;
  document.querySelectorAll("[data-mutate], input, textarea").forEach((element) => { element.disabled = busy; });
  document.querySelectorAll(".file-button").forEach((element) => element.classList.toggle("busy-disabled", busy));
  if (!busy) syncControls();
}

function syncControls() {
  $("generate").disabled = state.busy || !state.result;
  $("generate-empty").disabled = state.busy || !state.result;
  $("analyze").disabled = state.busy || !$("specification").value.trim();
  $("review-demo").disabled = state.busy;
  $("download-bundle").disabled = !state.generated?.archive;
  $("open-review-data").disabled = state.busy || !state.result;
}

function showError(error) {
  $("error-banner").hidden = false;
  const raw = `${error.code ?? "REQUEST_FAILED"}: ${error.message}${error.location ? ` · ${error.location}` : ""}`;
  const position = String(error.message).match(/line (\d+) column (\d+)/);
  const message = error.code === "PARSE_ERROR"
    ? `Не удалось прочитать YAML/JSON входа. Проверьте OpenAPI «${$("filename").value}» и применяемый override${position ? `; строка ${position[1]}, столбец ${position[2]}` : ""}.`
    : `${error.code ?? "REQUEST_FAILED"}: ${error.message}`;
  $("error-banner").innerHTML = `<p>${e(message)}</p><details><summary>Исходная диагностика</summary><pre>${e(raw)}</pre></details>`;
  $("activity").textContent = "Не удалось завершить операцию. Исправьте входные данные и повторите анализ.";
}

async function api(path, payload) {
  const response = await fetch(path, payload === undefined ? {} : {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload)
  });
  let result;
  try { result = await response.json(); } catch { throw new Error("Сервер вернул некорректный ответ. Проверьте локальный сервер."); }
  if (!response.ok) throw result.error ?? new Error(`HTTP ${response.status}`);
  return result;
}

function inputPayload() {
  return {
    filename: $("filename").value.trim() || "provider.yaml",
    provider: $("provider").value.trim(), specification: $("specification").value,
    overrides: $("use-overrides").checked ? $("overrides").value : "",
    override_filename: state.overrideFilename
  };
}

function clearGenerated() {
  state.generated = null;
  state.file = null;
  $("artifact-count").textContent = "0";
  $("artifact-workspace").hidden = true;
  $("artifact-empty").hidden = false;
  $("artifact-description").textContent = "Пакет появится после генерации и проверки Ruby-синтаксиса.";
  $("validation-summary").hidden = true;
}

function markDirty() {
  state.revision += 1;
  state.result = null;
  clearGenerated();
  renderResult();
  $("activity").textContent = "Есть изменения. Нажмите «Анализировать», чтобы обновить manifest.";
  syncControls();
}

async function analyze() {
  if (state.busy) return;
  const revision = state.revision;
  clearGenerated();
  $("error-banner").hidden = true;
  setBusy(true, "OpenAPI → Generic IR → semantic analysis → Integration Manifest…");
  const started = performance.now();
  try {
    const result = await api("/api/analyze", inputPayload());
    if (revision !== state.revision) return;
    state.result = result;
    renderResult();
    $("activity").textContent = `Анализ завершён за ${((performance.now() - started) / 1000).toFixed(2)} с · ${result.manifest.operations.length} операций · manifest v${result.manifest.manifest_version}`;
    if (!$("view-source").hidden) showView("overview");
  } catch (error) {
    state.result = null;
    renderResult();
    showError(error);
  } finally { setBusy(false); }
}

function authLabel(scheme) {
  if (!scheme) return "Авторизация не заявлена";
  return scheme.type === "api_key" ? "API key" : scheme.scheme ? scheme.scheme[0].toUpperCase() + scheme.scheme.slice(1) : scheme.type;
}

function renderExamples() {
  $("examples").innerHTML = state.examples.map((example, index) => {
    const title = example.title ?? example.provider;
    return `<button class="example-card ${state.selected === example.id ? "selected" : ""}" data-example="${index}" data-mutate aria-pressed="${state.selected === example.id}"><span class="provider-avatar">${e(["N", "T", "W"][index] ?? title[0])}</span><div><strong>${e(title)}</strong><small>${e(example.auth ?? "OpenAPI")} · ${e(example.filename.split(".").pop().toUpperCase())}</small><small>${e(example.description ?? "")}</small></div><span class="selection-dot" aria-hidden="true"></span></button>`;
  }).join("");
}

async function selectExample(index) {
  if (state.busy) return;
  const example = state.examples[index];
  if (!example) return;
  state.selected = example.id;
  $("filename").value = example.filename;
  $("provider").value = example.provider;
  $("specification").value = example.specification;
  $("overrides").value = example.overrides ?? "";
  $("use-overrides").checked = false;
  state.overrideFilename = example.override_filename ?? "overrides.yaml";
  markDirty();
  renderExamples();
  await analyze();
}

function renderResult() {
  const manifest = state.result?.manifest;
  const inferred = state.result?.inferred_manifest;
  $("input-summary").textContent = `${state.selected ? "Demo OpenAPI" : "Свой / изменённый OpenAPI"}: ${$("filename").value}. ${manifest ? "Анализ выполнен — проверьте решения ниже." : "Откройте спецификацию и выполните анализ."}`;
  $("review-data").hidden = !manifest;
  $("open-review-data").disabled = !manifest;
  ["stage-analysis", "stage-review", "stage-artifacts"].forEach((id) => $(id).classList.remove("done", "current"));
  $("stage-source").classList.toggle("done", !!manifest);
  $("stage-source").classList.toggle("current", !manifest);
  if (!manifest) {
    $("capability-explanation").textContent = "";
    ["metric-capabilities", "metric-operations", "metric-warnings", "warning-count"].forEach((id) => { $(id).textContent = "—"; });
    $("spec-version").textContent = "OpenAPI";
    $("metric-auth").textContent = "Ожидание анализа";
    $("metric-audit").textContent = "Неоднозначности видны до генерации";
    $("readiness").innerHTML = '<span class="pill neutral">Ожидание анализа</span>';
    $("review-description").textContent = "Неоднозначные факты остаются видимыми в manifest.";
    $("review-delta").hidden = true;
    $("capabilities").innerHTML = '<div class="empty-inline">Проанализируйте спецификацию, чтобы увидеть возможности API.</div>';
    $("warnings").innerHTML = '<div class="empty-inline">Предупреждения появятся после анализа.</div>';
    ["mapping-content", "webhook-content"].forEach((id) => { $(id).innerHTML = '<div class="panel empty-inline">Сначала проанализируйте OpenAPI.</div>'; });
    $("source-hash").textContent = "OpenAPI → IR → Manifest → Ruby";
    return;
  }
  $("stage-analysis").classList.add("done");
  const summary = reviewSummary(state.result);
  $("stage-review").classList.add(summary.ready ? "done" : "current");
  if (state.generated) $("stage-review").classList.remove("current");
  $("stage-artifacts").classList.toggle("current", !!state.generated);
  const detected = Object.values(manifest.capabilities).filter((item) => item.status === "detected").length;
  $("metric-capabilities").textContent = detected;
  const missing = Object.values(manifest.capabilities).filter((item) => item.status === "missing").length;
  $("capability-explanation").textContent = `${detected} обнаружено · ${missing} не заявлено · ${5 - detected - missing} требуют выбора. Это состав API, не процент готовности.`;
  $("metric-operations").textContent = manifest.operations.length;
  $("metric-warnings").textContent = manifest.warnings.length;
  $("metric-auth").textContent = `${authLabel(manifest.auth.schemes[0])} · ${manifest.provider.slug}`;
  $("metric-audit").textContent = manifest.overrides?.applied ? `${manifest.overrides.resolved_warnings.length} предупреждений сохранено в audit` : "Ожидают проверки или настройки";
  $("spec-version").textContent = `OpenAPI ${manifest.source.openapi_version}`;
  $("readiness").innerHTML = pill(state.result.overall_status);
  $("review-description").textContent = summary.text;
  $("review-delta").hidden = !manifest.overrides?.applied;
  if (manifest.overrides?.applied) {
    const before = Object.values(inferred.capabilities).filter((item) => item.status === "detected").length;
    $("review-delta").textContent = `Capabilities: ${before} → ${detected} · предупреждения: ${inferred.warnings.length} → ${manifest.warnings.length}`;
  }
  $("review-demo").innerHTML = 'Открыть overrides <span>→</span>';
  $("source-hash").textContent = `SHA-256 ${manifest.source.sha256?.slice(0, 12) ?? "—"}…`;
  $("capabilities").innerHTML = Object.entries(capabilities).map(([intent, [title, icon]]) => {
    const capability = manifest.capabilities[intent];
    const operation = manifest.operations.find((item) => item.key === capability.operation_key);
    const evidence = operation?.evidence ?? [];
    return `<div class="capability"><span class="cap-icon">${icon}</span><div><strong>${title}</strong><div class="endpoint">${operation ? `<span class="method ${e(operation.method.toLowerCase())}">${e(operation.method)}</span><span>${e(operation.path)}</span>` : '<span>Нет выбранной операции</span>'}</div></div><div class="cap-status">${pill(capability.status)}${capability.status !== "missing" ? `<span class="confidence">${Math.round(capability.confidence * 100)}% confidence</span>` : ""}</div>${evidence.length ? `<details class="evidence"><summary>Почему выбрана эта операция</summary><ul>${evidence.map((item) => `<li>${e(typeof item === "string" ? item : item.detail ?? item.rule)}</li>`).join("")}</ul></details>` : ""}</div>`;
  }).join("");
  $("warning-count").textContent = `${manifest.warnings.length} открыто`;
  $("warnings").innerHTML = renderWarnings(manifest.warnings);
  renderReviewData(manifest);
  renderMappings(manifest);
  renderWebhook(manifest);
}

function renderMappings(manifest) {
  const amount = manifest.transformations.amount;
  const factor = amount.factor == null ? "?" : amount.factor;
  const amountPanel = panel("Единицы суммы", `<div class="transform-visual"><div><strong>operation.amount</strong><span>Сумма в host-модели</span></div><div class="transform-arrow">→</div><div><strong>${amount.direction === "major_to_minor" ? `× ${e(factor)}` : amount.direction === "none" ? "× 1" : "?"}</strong><span>${e(amount.provider_unit)} units</span></div></div>${kv([["Поле провайдера", amount.provider_field], ["Правило", amount.direction]])}`, pill(amount.requires_review ? "requires_review" : "ready"));
  const statuses = Object.entries(manifest.status_mapping.mappings).map(([value, mapping]) => [code(value), code(mapping.normalized), pill(mapping.requires_review || mapping.provenance === "default_rule" ? "requires_review" : "ready", mapping.requires_review || mapping.provenance === "default_rule" ? "Предложение" : "Подтверждено")]);
  let html = `<div class="mapping-cards">${amountPanel}${panel("Статусы операций", table(["Provider", "Внутренний статус", "Проверка"], statuses))}</div>`;
  const conditions = manifest.transformations.conditional_requirements;
  if (conditions.length) html += panel("Условные требования", table(["Поле", "Обязательно, когда", "Проверка"], conditions.map((rule) => [code(rule.field), code(`${rule.required_if.field} = ${rule.required_if.equals}`), pill(rule.requires_review ? "requires_review" : "ready")])));
  Object.entries(manifest.field_mappings).forEach(([intent, mapping]) => {
    if (!mapping.request.length && !mapping.response.length) return;
    const rows = mapping.request.map((field) => [code(field.source_candidate ?? "нужен mapping"), `${code(field.target)}<small>${e(field.location ?? "body")}</small>`, field.required ? "Обязательное" : "Опциональное", pill(field.requires_review || !field.source_candidate ? "requires_review" : "ready", field.requires_review || !field.source_candidate ? "Проверить" : "Определено")]);
    html += panel(`${capabilities[intent]?.[0] ?? intent}: поля запроса`, table(["Источник в host", "Поле провайдера", "Обязательность", "Проверка"], rows));
    if (mapping.response.length) html += panel(`${capabilities[intent]?.[0] ?? intent}: поля ответа`, table(["Источник провайдера", "Внутренняя роль", "HTTP"], mapping.response.map((field) => [code(field.source), code(field.role), e(field.http_status)])));
  });
  $("mapping-content").innerHTML = html;
}

function renderWebhook(manifest) {
  let html = panel("Авторизация", table(["Схема", "Тип", "Размещение", "Переменная окружения"], manifest.auth.schemes.map((scheme) => [code(scheme.name), e(authLabel(scheme)), code([scheme.location, scheme.parameter_name].filter(Boolean).join(" · ") || "Authorization"), code(scheme.config_env)])));
  const webhook = manifest.webhook;
  if (webhook.status === "detected") {
    html += panel("Проверка подписи", kv([["Операция", webhook.operation_key], ["Signature header", webhook.signature?.header ?? "Нужен выбор"], ["Алгоритм", webhook.signature?.algorithm ?? "Нужен override"], ["Encoding", webhook.signature?.encoding ?? "Нужен override"]]));
    html += panel("Payload mappings", kv(Object.entries(webhook.payload ?? {}).map(([key, value]) => [key, value ?? "Не определено"])));
    html += '<div class="hint-box">process_callback(payload) обрабатывает разобранный JSON; подлинность уведомления должен проверить HTTP-слой хоста. process_verified_callback(raw_body, headers:) проверяет подпись по исходным байтам, заголовку и callback secret, затем обрабатывает подписанный body. Отсутствующие или неоднозначные status/id paths блокируют callback.</div>';
  } else html += panel("Входящие уведомления", `<div class="empty-inline">${webhook.status === "missing" ? "Webhook не заявлен или не распознан в этой спецификации." : "Выбор webhook-операции требует review."}</div>`, pill(webhook.status));
  html += panel("Ошибки провайдера", table(["Операция", "HTTP", "Коды", "Headers"], manifest.errors.map((error) => [code(error.operation_key), code(error.http_status), code((error.possible_provider_codes ?? []).join(", ") || "Не заявлены"), code((error.headers ?? []).join(", ") || "—")])));
  $("webhook-content").innerHTML = html;
}

async function generate() {
  if (state.busy || !state.result) return;
  $("error-banner").hidden = true;
  setBusy(true, "Генерация пяти артефактов и проверка ruby -c…");
  try {
    const result = await api("/api/generate", inputPayload());
    state.generated = result;
    state.result = result;
    renderResult();
    const names = Object.keys(result.artifacts).sort((a, b) => Number(b.endsWith("_service.rb")) - Number(a.endsWith("_service.rb")) || a.localeCompare(b));
    $("artifact-count").textContent = names.length;
    $("artifact-description").textContent = `${names.length} файлов · Ruby syntax проверен · ${result.output_directory}`;
    $("validation-summary").hidden = false;
    $("artifact-files").innerHTML = names.map((name, index) => `<button class="file-row" data-file="${index}"><span class="file-icon">${name.endsWith(".rb") ? "◇" : "▤"}</span><div><code>${e(name)}</code><small>${(new Blob([result.artifacts[name]]).size / 1024).toFixed(1)} КБ</small></div></button>`).join("");
    state.files = names;
    $("artifact-empty").hidden = true;
    $("artifact-workspace").hidden = false;
    previewFile(0);
    showView("artifacts");
    $("activity").textContent = "Пакет готов. Каждый файл создан из final manifest; ruby -c выполнен до публикации.";
  } catch (error) { showError(error); } finally { setBusy(false); }
}

function previewFile(index) {
  const name = state.files?.[index];
  if (!name || !state.generated) return;
  state.file = name;
  $("preview-filename").textContent = name;
  $("artifact-preview").textContent = state.generated.artifacts[name];
  $("artifact-preview").scrollTop = 0;
  $("artifact-preview").scrollLeft = 0;
  $("artifact-readable").hidden = !name.endsWith(".md");
  $("artifact-readable").innerHTML = name.endsWith(".md") ? readableMarkdown(state.generated.artifacts[name]) : "";
  $("artifact-readable").scrollTop = 0;
  $("artifact-preview").hidden = name.endsWith(".md");
  $("raw-preview-toggle").hidden = !name.endsWith(".md");
  $("raw-preview-toggle").textContent = "Показать исходный файл";
  const methods = [...state.generated.artifacts[name].matchAll(/^\s*def ([a-zA-Z_]\w*[!?=]?)/gm)].map((match) => match[1]);
  $("service-navigation").hidden = !name.endsWith(".rb");
  $("service-method").innerHTML = '<option value="">Начало файла</option>' + methods.map((method) => `<option value="${e(method)}">${e(method)}</option>`).join("");
  document.querySelectorAll("[data-file]").forEach((button) => { button.classList.toggle("active", Number(button.dataset.file) === index); });
}

function download(blob, name) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url; link.download = name; document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}

function downloadGenerated(url, name) {
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  document.body.append(link);
  link.click();
  link.remove();
}

async function loadFile(file, type) {
  if (!file || state.busy) return;
  try {
    if (!/\.(ya?ml|json)$/i.test(file.name)) throw new Error("Поддерживаются файлы .yaml, .yml и .json.");
    if (file.size > 1024 * 1024) throw new Error("Для локального demo выберите файл не больше 1 МБ.");
    setBusy(true, "Чтение файла…");
    const content = await file.text();
    $(type === "spec" ? "specification" : "overrides").value = content;
    if (type === "spec") {
      $("filename").value = file.name;
      $("provider").value = "";
      $("overrides").value = "";
      $("use-overrides").checked = false;
      state.selected = null;
      renderExamples();
    } else {
      state.overrideFilename = file.name;
      $("use-overrides").checked = true;
    }
    $("error-banner").hidden = true;
    markDirty();
    showView("source");
  } catch (error) { showError(error); } finally { setBusy(false); }
}

function bindControls() {
document.addEventListener("click", (event) => {
  const view = event.target.closest("[data-view]");
  if (view) showView(view.dataset.view);
  const example = event.target.closest("[data-example]");
  if (example) selectExample(Number(example.dataset.example));
  const file = event.target.closest("[data-file]");
  if (file) previewFile(Number(file.dataset.file));
});
$("jump-review").addEventListener("click", () => {
  $("review-panel").scrollIntoView({ block: "start" });
  $("review-demo").focus({ preventScroll: true });
});
$("analyze").addEventListener("click", analyze);
$("generate").addEventListener("click", generate);
$("generate-empty").addEventListener("click", generate);
$("upload-shortcut").addEventListener("click", () => $("spec-file").click());
$("review-demo").addEventListener("click", () => {
  showView("source");
  $("overrides").focus();
});
["filename", "provider", "specification", "overrides"].forEach((id) => $(id).addEventListener("input", () => {
  if (id !== "overrides") { state.selected = null; renderExamples(); }
  markDirty();
}));
$("use-overrides").addEventListener("change", markDirty);
$("spec-file").addEventListener("change", (event) => loadFile(event.target.files[0], "spec"));
$("override-file").addEventListener("change", (event) => loadFile(event.target.files[0], "override"));
$("specification").addEventListener("dragover", (event) => { event.preventDefault(); if (!state.busy) $("specification").classList.add("drag-over"); });
$("specification").addEventListener("dragleave", () => $("specification").classList.remove("drag-over"));
$("specification").addEventListener("drop", (event) => { event.preventDefault(); $("specification").classList.remove("drag-over"); loadFile(event.dataTransfer.files[0], "spec"); });
$("download-file").addEventListener("click", () => { if (state.file) downloadGenerated(state.generated.downloads[state.file], state.file); });
$("download-bundle").addEventListener("click", () => {
  const archive = state.generated?.archive;
  if (!archive) return;
  downloadGenerated(archive.download_url, archive.filename);
});
$("download-manifest").addEventListener("click", () => {
  if (state.result) download(new Blob([JSON.stringify(state.result.manifest, null, 2)], { type: "application/json" }), "integration_manifest.json");
});
$("open-review-data").addEventListener("click", () => {
  $("manifest-details").open = true;
  $("review-data").scrollIntoView({ block: "start" });
  $("manifest-details").querySelector("summary").focus({ preventScroll: true });
});
$("raw-preview-toggle").addEventListener("click", () => {
  const showRaw = $("artifact-preview").hidden;
  $("artifact-preview").hidden = !showRaw;
  $("artifact-readable").hidden = showRaw;
  $("raw-preview-toggle").textContent = showRaw ? "Показать читаемый вид" : "Показать исходный файл";
});
$("service-method").addEventListener("change", () => {
  if (!state.file || !state.generated) return;
  const lines = state.generated.artifacts[state.file].split("\n");
  const method = $("service-method").value;
  const index = method ? lines.findIndex((line) => line.trim().startsWith(`def ${method}(`) || line.trim() === `def ${method}`) : 0;
  $("artifact-preview").innerHTML = lines.map((line, i) => i === index && method ? `<mark>${e(line)}</mark>` : e(line)).join("\n");
  $("artifact-preview").scrollTop = Math.max(0, index * parseFloat(getComputedStyle($("artifact-preview")).lineHeight) - 20);
});
}

async function init() {
  setBusy(true);
  try {
    const result = await api("/api/examples");
    state.examples = result.examples;
    renderExamples();
    setBusy(false);
    if (state.examples.length) await selectExample(0);
    else $("activity").textContent = "Загрузите OpenAPI через раздел «Спецификация».";
  } catch (error) { showError(error); setBusy(false); }
}
if (typeof module !== "undefined" && module.exports) {
  module.exports = { reviewSummary, renderWarnings, readableMarkdown };
} else {
  bindControls();
  init();
}
