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

test("скрытые элементы не перекрываются display из дизайн-слоя", () => {
  const css = readDesign();
  assert.match(css, /\[hidden\] \{ display: none !important; \}/);
  assert.match(css, /\.notification-count\[hidden\] \{ display: none !important; \}/);
});

test("легаси-боксы вокруг текста сняты (абзацы, подписи, мелкий текст)", () => {
  const css = readDesign();
  assert.ok(css.includes("box-decoration-break: slice !important"));
  assert.match(css, /#page p, #page li, #page label, #page small,/);
  assert.ok(css.includes("background: transparent !important"));
});

test("заголовки и теги без пиксельных контуров и теней текста", () => {
  const css = readDesign();
  assert.ok(css.includes("clip-path: none !important"));
  assert.match(css, /#page, #page \*, #auth, #auth \*, #app \.topbar, #app \.topbar \* \{ text-shadow: none !important; \}/);
});

test("типографика едина: современный шрифт по умолчанию, пиксельный только в Minecraft", () => {
  const css = readDesign();
  assert.match(css, /body, body \* \{ font-family: var\(--scrl-font-ui\) !important; \}/);
  assert.match(css, /html\[data-style="minecraft"\] body \* \{ font-family: var\(--scrl-font-mc\) !important; \}/);
});

test("имя пользователя и бейдж уведомлений читаемы в обеих темах", () => {
  const css = readDesign();
  assert.match(css, /\.user-name \{[^}]*color: var\(--scrl-text\) !important/);
  assert.ok(css.includes("--scrl-danger-fill:"));
  assert.match(css, /\.notification-count \{[\s\S]*?background: var\(--scrl-danger-fill\) !important/);
});

test("шапка панели уведомлений на токенах, а не на легаси-золоте", () => {
  const css = readDesign();
  assert.match(css, /\.notification-panel-head \{[\s\S]*?background: var\(--scrl-surface-2\) !important/);
});

test("авторизационная книга без легаси-рамок и теней текста", () => {
  const css = readDesign();
  assert.ok(css.includes("#auth .book-subtitle, #auth .code-info, #auth .code-help, #auth .ban-appeal-info"));
  assert.ok(css.includes("#auth, #auth *"));
  assert.match(css, /\.book-inline-link \{[\s\S]*?border-radius: 0 !important/);
});

test("переключатели темы и стиля: фиксированная геометрия и видимый бегунок", () => {
  const css = readDesign();
  assert.match(css, /\.theme-switch \{[\s\S]*?min-width: 56px !important/);
  assert.match(css, /\.style-mode-toggle \{[\s\S]*?min-width: 56px !important/);
  assert.match(css, /\.theme-switch-thumb \{[\s\S]*?background: var\(--scrl-accent\) !important/);
  assert.match(css, /\.style-mode-toggle-thumb \{[\s\S]*?background: var\(--scrl-accent\) !important/);
});
