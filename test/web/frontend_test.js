"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { reviewSummary, renderWarnings, readableMarkdown } = require("../../web/app.js");

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
  assert.match(reviewSummary(result).text, /ограничениями/);
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
