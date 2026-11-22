const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

function readDesign() {
  return fs.readFileSync(path.join(__dirname, "../css/design.css"), "utf8");
}

test("дизайн-слой использует каскадные слои и токены темы", () => {
  const css = readDesign();
  assert.ok(css.includes("@layer scrl-design"));
  assert.ok(css.includes("--scrl-accent:"));
  assert.ok(css.includes("--scrl-surface:"));
  assert.ok(css.includes("--scrl-font-ui:"));
  assert.ok(css.includes("--scrl-radius-xl:"));
  assert.ok(css.includes("--scrl-dur-2:"));
});

test("навигация использует пилюлю вместо объёмной кнопки", () => {
  const css = readDesign();
  assert.ok(css.includes("border-radius: var(--scrl-radius-pill) !important"));
  assert.ok(css.includes(".nav-tab.is-active"));
});

test("кнопки и карточки дизайн-слоя имеют единые токены", () => {
  const css = readDesign();
  assert.ok(css.includes(".button-primary"));
  assert.ok(css.includes(".demo-card"));
  assert.ok(css.includes(".demo-stat"));
  assert.ok(css.includes(".home-overview-card"));
});

test("темы задаются через токены, а не инлайн-значения", () => {
  const css = readDesign();
  assert.ok(css.includes('html[data-theme="dark"]'));
  assert.ok(css.includes("--scrl-bg:"));
});

test("авторизационный блок использует карточку поверх токенов", () => {
  const css = readDesign();
  assert.ok(css.includes(".auth-book"));
  assert.ok(css.includes(".book-page"));
});

test("адаптивная сетка и анимации подключены", () => {
  const css = readDesign();
  assert.ok(css.includes("@media (max-width: 900px)"));
  assert.ok(css.includes("prefers-reduced-motion"));
});
