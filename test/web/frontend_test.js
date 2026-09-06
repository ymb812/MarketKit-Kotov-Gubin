"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { reviewSummary, renderWarnings, readableMarkdown, locateSourceRange } = require("../../web/app.js");

test("applying a partial override never completes review, including readiness without warnings", () => {
  const result = {
    overall_status: "needs_review",
    manifest: { overrides: { applied: true, applied_changes: [{ before: "SUCCESS", after: "approved" }] }, warnings: Array.from({ length: 9 }, () => ({ code: "AMBIGUOUS_CAPABILITY" })) }
  };
  assert.equal(reviewSummary(result).ready, false);
  assert.match(reviewSummary(result).text, /1 изменений/);
  assert.match(reviewSummary(result).text, /предупреждений: 9/);
  result.manifest.warnings = [];
  assert.equal(reviewSummary(result).ready, false);
  assert.match(reviewSummary(result).text, /отчёт совместимости/);
});

test("secret-only configuration stays distinct from other unresolved decisions", () => {
  const result = { overall_status: "needs_review", manifest: { warnings: [{ code: "CALLBACK_SECRET_NOT_DECLARED" }] } };
  assert.match(reviewSummary(result).text, /задайте его в окружении/);
  result.manifest.warnings.push({ code: "AMOUNT_UNIT_AMBIGUOUS" });
  assert.doesNotMatch(reviewSummary(result).text, /Остаётся предупреждение о callback secret/);
  assert.equal(reviewSummary(result).ready, false);
  result.overall_status = "ready";
  result.manifest.warnings = [];
  assert.equal(reviewSummary(result).ready, true);
});

test("unknown diagnostics retain code/message/location and escape uploaded text", () => {
  const html = renderWarnings([{ code: "NEW_WARNING", message: '<img src=x onerror="alert(1)">', location: "#/new/field" }]);
  assert.match(html, /NEW_WARNING/);
  assert.match(html, /#\/new\/field/);
  assert.match(html, /&lt;img/);
  assert.doesNotMatch(html, /<img/);
  assert.doesNotMatch(html, /data-diagnostic-view/);
});

test("unsupported oneOf explains the limitation and points to its unique source line", () => {
  const source = "components:\n  schemas:\n    Recipient:\n      oneOf:\n        - type: object\n";
  const html = renderWarnings([{
    code: "UNSUPPORTED_SCHEMA_KEYWORD", message: "oneOf is not normalized", kind: "unsupported",
    title: "Конструкция схемы пока не поддерживается", guidance: "Override не добавит поддержку.",
    location: "#/components/schemas/Recipient/oneOf", source_location: "#/components/schemas/Recipient/oneOf",
    target: { view: "source", focus: "specification", label: "Показать в OpenAPI" }
  }], source);

  assert.match(html, /Строка 4/);
  assert.match(html, /oneOf:/);
  assert.match(html, /Показать в OpenAPI/);
  assert.doesNotMatch(html, /Открыть overrides/);
});

test("source locator refuses an ambiguous token and accepts explicit line positions", () => {
  assert.equal(locateSourceRange("oneOf:\n  oneOf:\n", "#/oneOf"), null);
  assert.equal(locateSourceRange("first\nsecond\n", "line 2 column 1").text, "second");
});

test("source locator finds a unique broken ref by its exact target", () => {
  const source = "schema:\n  $ref: '#/components/schemas/MissingRequest'\n";
  const range = locateSourceRange(source, "#/components/schemas/MissingRequest");
  assert.equal(range.line, 2);
  assert.equal(range.text, "  $ref: '#/components/schemas/MissingRequest'");
});

test("readable reports show tables and code without executing provider-supplied HTML", () => {
  const html = readableMarkdown('# Report\n| Field | Value |\n|---|---|\n| `amount` | **100** |\n<script>alert(1)</script>\n```ruby\n<svg onload=x>\n```');
  assert.match(html, /<table/);
  assert.match(html, /<code>amount<\/code>/);
  assert.match(html, /<strong>100<\/strong>/);
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /&lt;svg/);
  assert.doesNotMatch(html, /<script|<svg/);
});
