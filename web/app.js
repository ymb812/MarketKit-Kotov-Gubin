"use strict";

const $ = (id) => document.getElementById(id);
const state = { examples: [], selected: null, result: null, generated: null, busy: false, file: null, overrideFilename: "overrides.yaml", revision: 0 };
const capabilities = {
  create_payout: ["Создание выплаты", "+"], fetch_status: ["Статус операции", "↗"],
  cancel_payout: ["Отмена выплаты", "×"], webhook: ["Входящие уведомления", "⌁"], balance: ["Баланс провайдера", "≋"]
};
const viewNames = { overview: "Обзор", source: "Спецификация", mappings: "Преобразования", webhook: "Auth и callbacks", artifacts: "Артефакты" };
const statusNames = { detected: "Обнаружено", requires_review: "Проверить", missing: "Не заявлено", ready: "READY", needs_review: "NEEDS REVIEW", unsupported: "UNSUPPORTED" };
const e = (value) => String(value ?? "—").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
const code = (value) => `<code>${e(value)}</code>`;
const pill = (status, text) => `<span class="pill ${["detected", "ready"].includes(status) ? "good" : ["missing", "unsupported"].includes(status) ? "missing" : "review"}">${e(text ?? statusNames[status] ?? status)}</span>`;
const table = (headers, rows) => `<div class="table-scroll"><table class="data-table"><thead><tr>${headers.map((h) => `<th scope="col">${e(h)}</th>`).join("")}</tr></thead><tbody>${rows.length ? rows.map((row) => `<tr>${row.map((cell) => `<td>${cell}</td>`).join("")}</tr>`).join("") : `<tr><td colspan="${headers.length}">Не заявлено в спецификации</td></tr>`}</tbody></table></div>`;
const panel = (title, body, label = "") => `<article class="panel"><div class="panel-heading"><h2>${e(title)}</h2>${label}</div>${body}</article>`;
const kv = (pairs) => `<dl class="kv-grid">${pairs.map(([key, value]) => `<div><dt>${e(key)}</dt><dd>${e(value)}</dd></div>`).join("")}</dl>`;

function showView(view) {
  if (!viewNames[view]) return;
  document.querySelectorAll(".view").forEach((section) => { section.hidden = section.id !== `view-${view}`; });
  document.querySelectorAll(".nav-item").forEach((button) => {
    const active = button.dataset.view === view;
    button.classList.toggle("active", active);
    if (active) button.setAttribute("aria-current", "page"); else button.removeAttribute("aria-current");
  });
  $("breadcrumb").textContent = viewNames[view];
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
  $("review-demo").disabled = state.busy || !$("overrides").value.trim();
  $("download-bundle").disabled = !state.generated?.archive;
}

function showError(error) {
  $("error-banner").hidden = false;
  $("error-banner").textContent = `${error.code ?? "REQUEST_FAILED"}: ${error.message}${error.location ? ` · ${error.location}` : ""}`;
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
    return `<button class="example-card ${state.selected === example.id ? "selected" : ""}" data-example="${index}" data-mutate aria-pressed="${state.selected === example.id}"><span class="provider-avatar">${e(["N", "T", "W"][index] ?? title[0])}</span><div><strong>${e(title)}</strong><small>${e(example.auth ?? "OpenAPI")} · ${e(example.filename.split(".").pop().toUpperCase())}</small></div><span class="selection-dot" aria-hidden="true"></span></button>`;
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
  ["stage-analysis", "stage-review", "stage-artifacts"].forEach((id) => $(id).classList.remove("done", "current"));
  $("stage-source").classList.toggle("done", !!manifest);
  $("stage-source").classList.toggle("current", !manifest);
  if (!manifest) {
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
  $("stage-review").classList.add(manifest.overrides?.applied ? "done" : "current");
  $("stage-artifacts").classList.toggle("current", !!state.generated);
  const detected = Object.values(manifest.capabilities).filter((item) => item.status === "detected").length;
  $("metric-capabilities").textContent = detected;
  $("metric-operations").textContent = manifest.operations.length;
  $("metric-warnings").textContent = manifest.warnings.length;
  $("metric-auth").textContent = `${authLabel(manifest.auth.schemes[0])} · ${manifest.provider.slug}`;
  $("metric-audit").textContent = manifest.overrides?.applied ? `${manifest.overrides.resolved_warnings.length} предупреждений сохранено в audit` : "Ожидают проверки или настройки";
  $("spec-version").textContent = `OpenAPI ${manifest.source.openapi_version}`;
  $("readiness").innerHTML = pill(state.result.overall_status);
  $("review-description").textContent = manifest.overrides?.applied
    ? "Решения подтверждены override. Оставшиеся требования, включая callback secret, нужно настроить в host-приложении."
    : "Имена полей и статусов не всегда описывают бизнес-смысл. Проверьте предложенные решения перед использованием сервиса.";
  $("review-delta").hidden = !manifest.overrides?.applied;
  if (manifest.overrides?.applied) {
    const before = Object.values(inferred.capabilities).filter((item) => item.status === "detected").length;
    $("review-delta").textContent = `Capabilities: ${before} → ${detected} · предупреждения: ${inferred.warnings.length} → ${manifest.warnings.length}`;
  }
  $("review-demo").innerHTML = `${manifest.overrides?.applied ? "Посмотреть применённый override" : "Проверить demo override"} <span>→</span>`;
  $("source-hash").textContent = `SHA-256 ${manifest.source.sha256?.slice(0, 12) ?? "—"}…`;
  $("capabilities").innerHTML = Object.entries(capabilities).map(([intent, [title, icon]]) => {
    const capability = manifest.capabilities[intent];
    const operation = manifest.operations.find((item) => item.key === capability.operation_key);
    const evidence = operation?.evidence ?? [];
    return `<div class="capability"><span class="cap-icon">${icon}</span><div><strong>${title}</strong><div class="endpoint">${operation ? `<span class="method ${e(operation.method.toLowerCase())}">${e(operation.method)}</span><span>${e(operation.path)}</span>` : '<span>Нет выбранной операции</span>'}</div></div><div class="cap-status">${pill(capability.status)}${capability.status !== "missing" ? `<span class="confidence">${Math.round(capability.confidence * 100)}% confidence</span>` : ""}</div>${evidence.length ? `<details class="evidence"><summary>Почему выбрана эта операция</summary><ul>${evidence.map((item) => `<li>${e(typeof item === "string" ? item : item.detail ?? item.rule)}</li>`).join("")}</ul></details>` : ""}</div>`;
  }).join("");
  $("warning-count").textContent = `${manifest.warnings.length} открыто`;
  $("warnings").innerHTML = manifest.warnings.length ? manifest.warnings.map((warning) => `<div class="warning-row"><span class="warning-icon">△</span><div><strong>${e(warning.code)}</strong><p>${e(warning.message)}</p><small>${e(warning.location)}</small></div></div>`).join("") : '<div class="empty-inline">Все предупреждения разрешены. Runtime credentials задаются отдельно.</div>';
  renderMappings(manifest);
  renderWebhook(manifest);
}

function renderMappings(manifest) {
  const amount = manifest.transformations.amount;
  const factor = amount.factor == null ? "?" : amount.factor;
  const amountPanel = panel("Единицы суммы", `<div class="transform-visual"><div><strong>operation.amount</strong><span>Host value</span></div><div class="transform-arrow">→</div><div><strong>${amount.direction === "major_to_minor" ? `× ${e(factor)}` : amount.direction === "none" ? "× 1" : "?"}</strong><span>${e(amount.provider_unit)} units</span></div></div>${kv([["Provider field", amount.provider_field], ["Правило", amount.direction]])}`, pill(amount.requires_review ? "requires_review" : "ready"));
  const statuses = Object.entries(manifest.status_mapping.mappings).map(([value, mapping]) => [code(value), code(mapping.normalized), pill(mapping.requires_review || mapping.provenance === "default_rule" ? "requires_review" : "ready", mapping.requires_review || mapping.provenance === "default_rule" ? "Предложение" : "Подтверждено")]);
  let html = `<div class="mapping-cards">${amountPanel}${panel("Статусы операций", table(["Provider", "Normalized", "Review"], statuses))}</div>`;
  Object.entries(manifest.field_mappings).forEach(([intent, mapping]) => {
    if (!mapping.request.length && !mapping.response.length) return;
    const rows = mapping.request.map((field) => [code(field.source_candidate ?? "нужен mapping"), `${code(field.target)}<small>${e(field.location ?? "body")}</small>`, field.required ? "Обязательное" : "Опциональное", pill(field.requires_review || !field.source_candidate ? "requires_review" : "ready", field.requires_review || !field.source_candidate ? "Проверить" : "Определено")]);
    html += panel(`${capabilities[intent]?.[0] ?? intent}: request mappings`, table(["Host source", "Provider field", "Required", "Review"], rows));
    if (mapping.response.length) html += panel(`${capabilities[intent]?.[0] ?? intent}: response mappings`, table(["Provider source", "Host role", "HTTP"], mapping.response.map((field) => [code(field.source), code(field.role), e(field.http_status)])));
  });
  const conditions = manifest.transformations.conditional_requirements;
  if (conditions.length) html += panel("Условные требования", table(["Поле", "Обязательно, когда", "Review"], conditions.map((rule) => [code(rule.field), code(`${rule.required_if.field} = ${rule.required_if.equals}`), pill(rule.requires_review ? "requires_review" : "ready")])));
  $("mapping-content").innerHTML = html;
}

function renderWebhook(manifest) {
  let html = panel("Авторизация", table(["Схема", "Тип", "Размещение", "ENV placeholder"], manifest.auth.schemes.map((scheme) => [code(scheme.name), e(authLabel(scheme)), code([scheme.location, scheme.parameter_name].filter(Boolean).join(" · ") || "Authorization"), code(scheme.config_env)])));
  const webhook = manifest.webhook;
  if (webhook.status === "detected") {
    html += panel("Проверка подписи", kv([["Операция", webhook.operation_key], ["Signature header", webhook.signature?.header ?? "Нужен выбор"], ["Алгоритм", webhook.signature?.algorithm ?? "Нужен override"], ["Encoding", webhook.signature?.encoding ?? "Нужен override"]]));
    html += panel("Payload mappings", kv(Object.entries(webhook.payload ?? {}).map(([key, value]) => [key, value ?? "Не определено"])));
    html += '<div class="hint-box">Проверка подписи требует точный raw body, signature header и callback secret. После проверки обрабатывается подписанный body. Отсутствующие или неоднозначные status/id paths блокируют callback.</div>';
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
  document.querySelectorAll("[data-file]").forEach((button) => { button.classList.toggle("active", Number(button.dataset.file) === index); });
}

function download(blob, name) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url; link.download = name; document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
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

document.addEventListener("click", (event) => {
  const view = event.target.closest("[data-view]");
  if (view) showView(view.dataset.view);
  const example = event.target.closest("[data-example]");
  if (example) selectExample(Number(example.dataset.example));
  const file = event.target.closest("[data-file]");
  if (file) previewFile(Number(file.dataset.file));
});
$("analyze").addEventListener("click", analyze);
$("generate").addEventListener("click", generate);
$("generate-empty").addEventListener("click", generate);
$("upload-shortcut").addEventListener("click", () => $("spec-file").click());
$("review-demo").addEventListener("click", () => {
  showView("source");
  if (!$("use-overrides").checked) { $("use-overrides").checked = true; markDirty(); }
  $("overrides").focus();
});
["filename", "provider", "specification", "overrides"].forEach((id) => $(id).addEventListener("input", markDirty));
$("use-overrides").addEventListener("change", markDirty);
$("spec-file").addEventListener("change", (event) => loadFile(event.target.files[0], "spec"));
$("override-file").addEventListener("change", (event) => loadFile(event.target.files[0], "override"));
$("specification").addEventListener("dragover", (event) => { event.preventDefault(); if (!state.busy) $("specification").classList.add("drag-over"); });
$("specification").addEventListener("dragleave", () => $("specification").classList.remove("drag-over"));
$("specification").addEventListener("drop", (event) => { event.preventDefault(); $("specification").classList.remove("drag-over"); loadFile(event.dataTransfer.files[0], "spec"); });
$("download-file").addEventListener("click", () => { if (state.file) download(new Blob([state.generated.artifacts[state.file]], { type: "text/plain;charset=utf-8" }), state.file); });
$("download-bundle").addEventListener("click", () => {
  const archive = state.generated?.archive;
  if (!archive) return;
  download(new Blob([Uint8Array.from(atob(archive.base64), (char) => char.charCodeAt(0))], { type: "application/gzip" }), archive.filename);
});

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
init();
