const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const core = require("../js/core.js");

function boot(initialLocalStorage = {}) {
  const store = new Map(Object.entries(initialLocalStorage).map(([key, value]) => ["l:" + key, String(value)]));
  const els = new Map();
  const make = id => {
    if (els.has(id)) return els.get(id);
    const item = {
      id, hidden: false, textContent: "", innerHTML: "", value: "", title: "",
      dataset: {}, listeners: {}, attrs: {},
      classList: { toggle() {}, add() {}, remove() {}, contains() { return false; } },
      addEventListener(name, fn) { this.listeners[name] = fn; },
      setAttribute(name, value) { this.attrs[name] = value; },
      removeAttribute(name) { delete this.attrs[name]; },
      querySelectorAll() { return []; },
      reset() {},
      focus() {},
      matches() { return true; }
    };
    els.set(id, item);
    return item;
  };
  const nav = ["home","board","exchange","auctions","activity"].map(page => {
    const item = make("nav-" + page);
    item.dataset.page = page;
    return item;
  });
  const document = {
    documentElement: { dataset: {} },
    getElementById: make,
    querySelectorAll(selector) { return selector === ".nav-tab" ? nav : []; }
  };
  const localStorage = {
    getItem(key) { return store.has("l:" + key) ? store.get("l:" + key) : null; },
    setItem(key, value) { store.set("l:" + key, String(value)); },
    removeItem(key) { store.delete("l:" + key); }
  };
  const session = new Map([["scrlSession", JSON.stringify({ id: "u0", name: "Гость", mail: "", token: "", guest: true })]]);
  const sessionStorage = {
    getItem(key) { return session.has(key) ? session.get(key) : null; },
    setItem(key, value) { session.set(key, String(value)); },
    removeItem(key) { session.delete(key); }
  };
  class FormData {
    constructor(form) { this.form = form; }
    get(name) { return this.form.fields?.[name] ?? null; }
  }
  const window = { cfg: {}, ScrlCore: core, __scrlTestMode: true };
  const context = {
    window, document, localStorage, sessionStorage, FormData, ScrlCore: core,
    console, Date, Math, JSON, Number, String, Array, Set, Map, RegExp,
    prompt: () => "9А", confirm: () => true,
    setTimeout: () => 1, clearTimeout() {},
    fetch: async () => { throw new Error("Network is disabled in tests."); }
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8"), context);
  return { api: window.scrlTest, els, sessionStorage, localStorage };
}

test("страницы приложения запускаются в гостевом режиме", () => {
  const { api, els } = boot();
  assert.equal(api.me().id, "u0");
  assert.match(api.boardPage(), /Доска/);
  assert.equal(api.marketPage, undefined);
  assert.match(api.exchangePage(), /ОГРАНИЧЕНИЕ ДОСТУПА/);
  assert.match(api.exchangePage(), /Допуск к бирже/);
  assert.doesNotMatch(api.exchangePage(), /Продать ScRl|Продать V-RUB|id="exchangeForm"/);
  assert.match(api.auctionsPage(), /Аукционы/);
  assert.equal(els.get("app").hidden, false);
});

test("вход сохраняется в localStorage после обновления, а явный выход очищает сессию", () => {
  const { api, localStorage, sessionStorage } = boot();
  const migrated = JSON.parse(localStorage.getItem("scrlSession") || "null");
  assert.equal(migrated?.id, "u0");
  assert.equal(migrated?.guest, true);
  assert.equal(sessionStorage.getItem("scrlSession"), null);

  api.enter("Тестовый ученик", "student@example.com", "access-token", false, "persist-test");
  const saved = JSON.parse(localStorage.getItem("scrlSession") || "null");
  assert.equal(saved?.id, "persist-test");
  assert.equal(saved?.token, "access-token");

  api.leave();
  assert.equal(localStorage.getItem("scrlSession"), null);
  assert.equal(sessionStorage.getItem("scrlSession"), null);
});

test("обе стороны биржи проводят расчёт и списывают резервы", () => {
  const { api } = boot();
  const user = api.me();
  const startScrl = user.scrl;
  const startVrub = user.vrub;

  api.buyExchangeOrder("x1");
  const afterScrlOffer = api.data.exchangeOrders.find(o => o.id === "x1");
  assert.equal(afterScrlOffer.status, "filled");
  assert.ok(user.scrl >= startScrl);
  assert.ok(user.vrub < startVrub);

  api.buyExchangeOrder("x2");
  const afterVrubOffer = api.data.exchangeOrders.find(o => o.id === "x2");
  assert.equal(afterVrubOffer.status, "filled");
  assert.equal(api.data.trades.length, 2);
  assert.ok(user.scrl < startScrl + 25);
  assert.ok(user.vrub > startVrub);
});

test("отмена предложения биржи возвращает резерв владельцу", () => {
  const { api } = boot();
  const user = api.me();
  const before = user.scrl;
  const offer = api.placeExchangeOrder("scrlSell", 10, 0.05);
  assert.equal(user.scrl, before - 10);
  assert.equal(user.holdScrl >= 10, true);
  api.cancelExchangeOrder(offer.id);
  assert.equal(offer.status, "cancelled");
  assert.equal(user.scrl, before);
});

test("сделка удерживает ScRl и выплачивает после завершения", () => {
  const { api } = boot();
  const buyer = api.me();
  const seller = api.getUser("u2");
  const beforeBuyer = buyer.scrl;
  const beforeSeller = seller.scrl;
  const deal = api.createDeal("Тестовая помощь", buyer.id, seller.id, 20, "test");
  assert.equal(buyer.scrl, beforeBuyer - 20);
  assert.equal(buyer.holdScrl >= 20, true);
  api.releaseDeal(deal, "pay");
  assert.equal(deal.status, "done");
  assert.equal(deal.escrow, 0);
  assert.ok(seller.scrl > beforeSeller);
  assert.equal(buyer.holdScrl, 0);
});

test("ставка аукциона возвращает предыдущую и победная ставка закрывается", () => {
  const { api } = boot();
  const auction = api.data.auctions.find(a => a.id === "a1");
  const user = api.me();
  const before = user.scrl;
  api.bid(auction.id, 70);
  assert.equal(auction.leader, user.id);
  assert.equal(auction.bid, 70);
  assert.ok(user.scrl < before);
  auction.ends = Date.now() - 1000;
  api.closeExpiredAuctions();
  assert.equal(auction.status, "done");
  assert.equal(api.data.bids.find(b => b.auction === auction.id && b.user === user.id && b.amount === 70).status, "won");
});

test("администратор может временно просматривать роли ученика и учителя без изменения роли в данных", () => {
  const { api } = boot();
  api.enter("Администратор", "admin@example.test", "", false, "u0");
  api.me().role = "admin";
  assert.equal(api.isAdminAccount(), true);

  api.setAdminPreviewRole("student");
  assert.equal(api.me().role, "student");
  assert.equal(api.getUser("u0").role, "admin");

  api.setAdminPreviewRole("teacher");
  assert.equal(api.me().role, "teacher");
  assert.equal(api.getUser("u0").role, "admin");

  api.resetAdminPreviewRole();
  api.enter("Администратор", "admin@example.test", "", false, "u0");
  assert.equal(api.me().role, "admin");
  assert.equal(api.getUser("u0").role, "admin");
});

test("ученик не видит форму создания аукциона", () => {
  const { api } = boot();
  assert.equal(api.auctionsPage().includes('id="auctionForm"'), false);
  api.me().role = "teacher";
  assert.equal(api.auctionsPage().includes('id="auctionForm"'), true);
});

test("локальный помощник администратора отвечает на отчёт экономики", () => {
  const { api } = boot();
  api.me().role = "admin";
  assert.match(api.assistantPage(), /AI Moderator/);
  api.askAssistant("Составь отчёт по экономике");
  assert.equal(api.data.aiMessages.length, 2);
  assert.equal(api.data.aiMessages[0].role, "user");
  assert.match(api.data.aiMessages[1].text, /Обеспеченный лимит/);
});

test("все разделы отрисовываются для нужных ролей", () => {
  const { api } = boot();
  assert.match(api.walletPage(), /Кошелёк/);
  assert.match(api.ordersPage(), /Мои заказы/);
  assert.match(api.activityPage(), /Активность/);
  assert.match(api.favoritesPage(), /Избранное/);
  assert.match(api.noticesPage(), /Уведомления/);
  assert.match(api.profilePage(), /Профиль/);

  api.me().role = "teacher";
  api.me().room = "9А";
  assert.match(api.staffPage(), /Кабинет учителя/);
  assert.match(api.pulsePage(), /Пульс лицея/);

  api.me().role = "admin";
  assert.match(api.adminPage(), /Администрирование/);
  assert.match(api.financePage(), /Платёжный модуль/);
  assert.match(api.assistantPage(), /AI Moderator/);
});

test("покупка услуги проходит через резерв, выполнение и подтверждение", () => {
  const { api } = boot();
  const buyer = api.me();
  const seller = api.getUser("u2");
  const before = buyer.scrl;
  api.action({ dataset: { id: "l1", do: "buy" } });
  const deal = api.data.deals[0];
  assert.equal(deal.status, "work");
  assert.equal(deal.escrow, 35);
  assert.equal(buyer.scrl, before - 35);
  assert.equal(api.data.listings.find(x => x.id === "l1").slots, 1);

  api.enter("Марк", "mark@example.test", "", false, "u2");
  api.action({ dataset: { id: deal.id, do: "delivered" } });
  assert.equal(deal.status, "ready");

  api.enter("Гость", "", "", true);
  api.action({ dataset: { id: deal.id, do: "confirm" } });
  assert.equal(deal.status, "done");
  assert.equal(deal.escrow, 0);
  assert.equal(buyer.holdScrl, 0);
  assert.ok(seller.scrl > 190);
});

test("публикации со ссылками отправляются на ручную проверку", async () => {
  const { api } = boot();
  await api.submit({
    id: "boardForm", dataset: {}, reset() {},
    fields: {
      type: "need", category: "Учёба", title: "Нужна помощь",
      desc: "Посмотрите https://example.com", price: "0"
    }
  });
  const post = api.data.posts[0];
  assert.equal(post.status, "review");
  api.me().role = "admin";
  assert.match(api.adminPage(), /Автопроверка/);
  const report = api.data.reports.find(r => r.target === post.id && r.status === "open");
  api.action({ dataset: { id: report.id, do: "keep" } });
  assert.equal(post.status, "active");
  assert.equal(report.status, "kept");
});

test("учитель начисляет ScRl только ученику своего класса и в пределах лимита", async () => {
  const { api } = boot();
  api.enter("Елена Сергеевна", "teacher@example.test", "", false, "t1");
  const target = api.getUser("u1");
  const before = target.scrl;
  await api.submit({
    id: "staffForm", dataset: {}, reset() {},
    fields: { student: "u1", amount: "10", reason: "Помощь однокласснику" }
  });
  assert.equal(target.scrl, before + 10);
  await assert.rejects(api.submit({
    id: "staffForm", dataset: {}, reset() {},
    fields: { student: "u3", amount: "10", reason: "Другое" }
  }), /своего класса/);
});

test("тёмная тема запускается по умолчанию и переключается на светлую и обратно", () => {
  const { api } = boot();
  assert.equal(api.activeTheme(), "dark");
  api.switchTheme();
  assert.equal(api.activeTheme(), "light");
  api.switchTheme();
  assert.equal(api.activeTheme(), "dark");
});
test("переключатель темы — двухпозиционный слайдер с доступным состоянием", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.match(html, /id="themeBtn"[^>]*role="switch"[^>]*aria-checked="true"/);
  assert.match(html, /id="authThemeBtn"[^>]*role="switch"[^>]*aria-checked="true"/);
  assert.equal((html.match(/class="theme-switch-track"/g) || []).length, 2);
  assert.ok(app.includes('button.setAttribute("aria-checked", String(normalized === "dark"))'));
  assert.ok(css.includes(".theme-switch-thumb"));
  assert.ok(css.includes("top: 50% !important"));
  assert.ok(css.includes("translate(32px,-50%) !important"));
  assert.ok(css.includes("translate(28px,-50%) !important"));
  assert.ok(css.includes("translate(26px,-50%) !important"));
  assert.ok(css.includes(".theme-switch-thumb::after"));
  assert.doesNotMatch(html, /id="themeTransition"/);
  assert.doesNotMatch(app, /themeTransition|transition\.classList/);
  assert.match(css, /html\[data-style="classic"\]\[data-theme="dark"\][\s\S]*?background-color/);
  assert.match(css, /html\[data-style="minecraft"\] body \.world-layer[\s\S]*?transition: opacity 1\.15s ease/);
  assert.match(css, /html\[data-theme="dark"\] body \.topbar-balance \.balance-group strong/);
});















test("обязательные согласия принимаются при регистрации и проверяются перед доступом", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const { api } = boot();

  assert.match(html, /id="loginAllConsents"[^>]*required/);
  assert.match(html, /id="regAllConsents"[^>]*required/);
  assert.match(html, /legal\/terms\.html/);
  assert.match(html, /legal\/privacy\.html/);
  assert.match(html, /legal\/ai-moderation\.html/);
  assert.match(html, /legal\/parent-exchange\.html/);
  assert.match(app, /name="allConsents"/);
  assert.match(app, /loginAllConsents/);
  assert.match(app, /Не удалось проверить сохранённые согласия/);
  assert.match(app, /consentStatusNeedsAcceptance\(data\.safety\)/);
  assert.equal(api.consentStatusNeedsAcceptance({
    needsOnboarding: false,
    hasPersonalDataConsent: true,
    hasAiConsent: true
  }), false);
  assert.equal(api.consentStatusNeedsAcceptance({
    needsOnboarding: false,
    hasPersonalDataConsent: true,
    hasAiConsent: false
  }), true);
  assert.equal(api.consentStatusNeedsAcceptance({
    needsOnboarding: true,
    hasPersonalDataConsent: true,
    hasAiConsent: true
  }), true);
  assert.equal(api.consentStatusNeedsAcceptance(null), true);
});

test("книга авторизации содержит только две страницы без промежуточного разворота", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.match(html, /Страница 1 \/ 2/);
  assert.match(html, /Страница 2 \/ 2/);
  assert.match(html, /id="loginPage"[^>]*aria-label="Страница 1 — вход"/);
  assert.match(html, /id="registrationPage"[^>]*aria-label="Страница 2 — регистрация"/);
  assert.doesNotMatch(html, /Page 3 of 3|book-spread|infoPage2|Как устроен ScRl/);
  assert.match(html, /id="regForm"/);
  assert.match(css, /\.auth-book\.is-spread #registrationPage/);
  assert.doesNotMatch(html, /book-bottom-mark/);
});

test("светлая тема использует серую пиксельную рамку достижения для всех полей", () => {
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.match(css, /--stone-frame-fill: #c4c4c4/);
  assert.match(css, /--stone-frame-outline: #111111/);
  assert.match(css, /--stone-frame-light: #f2f2f2/);
  assert.match(css, /--stone-frame-shadow: #5a5a5a/);
  assert.match(css, /:root:not\(\[data-theme="dark"\]\) input/);
  assert.match(css, /:root:not\(\[data-theme="dark"\]\) select/);
  assert.match(css, /:root:not\(\[data-theme="dark"\]\) textarea/);
  assert.match(css, /clip-path: polygon\(/);
  assert.match(css, /:root:not\(\[data-theme="dark"\]\) \.demo-form/);
});




test("светлые поля привязаны напрямую к data-theme=light", () => {
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  assert.ok(css.includes('html[data-theme="light"] body input'));
  assert.ok(css.includes('html[data-theme="light"] body select'));
  assert.ok(css.includes('html[data-theme="light"] body textarea'));
  assert.ok(css.includes('border: 4px solid #111111 !important'));
  assert.ok(css.includes('background-color: #c4c4c4 !important'));
  assert.ok(/<link rel="stylesheet" href="css\/style\.css\?v=\d+">/.test(html));
});



test("в светлой теме текстовые блоки всегда имеют светлую подложку", () => {
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.ok(css.includes('html[data-theme="light"] body #page p,'));
  assert.ok(css.includes("background-color:#f7f9f1 !important"));
  assert.ok(css.includes('html[data-theme="light"] body #auth .book-subtitle'));
  assert.ok(css.includes("background-color:#f8f8ee !important"));
});

test("вход и регистрация занимают страницы 1 и 2 на всех размерах", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.match(html, /id="loginPage"[^>]*aria-label="Страница 1 — вход"/);
  assert.match(html, /id="registrationPage"[^>]*aria-label="Страница 2 — регистрация"/);
  assert.doesNotMatch(html, /infoPage2|book-spread|Page 3 of 3/);
  assert.match(app, /book\.classList\.toggle\("is-spread", isSpread\)/);
  assert.match(app, /registrationPage\.inert = !isRegistration/);
  assert.match(css, /#auth \.auth-book\.is-spread #registrationPage/);
  assert.match(css, /@media \(max-width:620px\)/);
});

test("курсор underscore следует за реальной кареткой во всех полях авторизации", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.equal((html.match(/С Возвращением,/g) || []).length, 1);
  assert.match(html, /id="regForm"/);
  assert.match(html, /id="codeForm"/);
  assert.match(app, /function installMinecraftBookCursors\(\)/);
  assert.ok(app.includes('document.querySelectorAll("#authBook .mc-input-shell input")'));
  assert.ok(app.includes('cursor.textContent = "_"'));
  assert.ok(app.includes("marker.getBoundingClientRect()"));
  assert.ok(app.includes("document.body.append(mirror, cursor)"));
  assert.ok(app.includes('document.addEventListener("selectionchange", updateSelection)'));
  assert.ok(css.includes(".mc-writing-cursor"));
  assert.ok(css.includes(".mc-caret-measure"));
  assert.ok(css.includes("caret-color:transparent !important"));
});
test("восстановление пароля проходит через письмо Supabase и recovery token", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(html, /id="forgotPassword"/);
  assert.match(html, /id="resetPasswordForm"/);
  assert.match(app, /recover\?redirect_to=/);
  assert.match(app, /params\.get\("type"\) !== "recovery"/);
  assert.match(app, /\/auth\/v1\/user/);
  assert.match(app, /method: "PUT"/);
  assert.match(app, /passwordRecoveryToken/);
});

test("вход только по email и паролю доступен после регистрации", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(app, /token\?grant_type=password/);
  assert.match(html, /id="regPass"[^>]*minlength="8"/);
  assert.match(html, /id="regAgain"[^>]*minlength="8"/);
  assert.match(app, /pass\.length < 8/);
  assert.doesNotMatch(html, /loginByEmail|Войти по коду из письма/);
  assert.doesNotMatch(html, /id="bookDone"/);
  assert.doesNotMatch(app, /requestEmailLoginCode|ask\("otp"/);
  assert.doesNotMatch(app, /enter\("Гость"/);
  assert.match(app, /Если аккаунт ещё не создан, сначала зарегистрируйся/);
  assert.match(app, /База аккаунтов пока не подключена/);
});

test("регистрация подтверждает почту, затем требует отдельный вход по паролю", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(app, /ask\("signup\?redirect_to=" \+ encodeURIComponent\(APP_REDIRECT_URL\), \{ email: mail, password: pass \}\)/);
  assert.match(app, /claimInitialAdminForEmail\(\)/);
  assert.doesNotMatch(app, /prompt\("Первый вход в ScRl/);
  assert.match(app, /ask\("verify", \{ email: mail, token, type: "email" \}\)/);
  assert.match(app, /await saveProfile\(result\.user\.id, name, result\.access_token, null, \{/);
  assert.match(app, /el\("logMail"\)\.value = mail/);
  assert.match(app, /setMode\("login"\)/);
  assert.match(app, /Почта подтверждена, согласия сохранены\. Теперь войди по email и паролю/);
  assert.doesNotMatch(app, /enter\(name, result\.user\?\.email \|\| mail/);
  assert.doesNotMatch(app, /pending\.purpose === "email-login"/);
});

test("повторный код отправляется только для подтверждения регистрации", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(app, /ask\("resend", \{ type: "signup", email: pending\.mail \}\)/);
  assert.doesNotMatch(app, /ask\("otp"/);
  assert.match(app, /Начни регистрацию заново/);
});








test("дневной и ночной фон — цельные изображения поверхности без руки и 3D-слоёв", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const day = fs.readFileSync(path.join(__dirname, "../assets/backgrounds/day.png"));
  const night = fs.readFileSync(path.join(__dirname, "../assets/backgrounds/night.png"));
  for (const image of [day, night]) {
    assert.equal(image.toString("ascii", 1, 4), "PNG", "Фон должен быть настоящим PNG-файлом");
    assert.equal(image.readUInt32BE(16), 1919);
    assert.equal(image.readUInt32BE(20), 1079);
    assert.ok(image.length > 1000);
  }
  assert.match(css, /assets\/backgrounds\/day\.png/);
  assert.match(css, /assets\/backgrounds\/night\.png/);
  assert.match(html, /world-layer--surface/);
  assert.match(html, /world-layer--cave/);
  assert.doesNotMatch(html, /mcCaveCanvas|mcExplosionCanvas|worldTransition|world-torch-glow/);
  assert.doesNotMatch(app, /startCaveAssembly|startMinecraftExplosion|torch-pixel\.png|stone-flat\.png/);
  assert.match(app, /function switchTheme\(\)[\s\S]*?paintWorldTheme\(current === "dark" \? "light" : "dark"\)/);
  assert.doesNotMatch(app, /themeTransition|transition\.classList/);
});


test("фон дня и ночи берётся из отдельной папки assets/backgrounds", () => {
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const guide = fs.readFileSync(path.join(__dirname, "../assets/backgrounds/README.md"), "utf8");
  assert.match(css, /assets\/backgrounds\/day\.png/);
  assert.match(css, /assets\/backgrounds\/night\.png/);
  assert.match(guide, /day\.png/);
  assert.match(guide, /night\.png/);
});


test("uploaded day/night photos are rendered smoothly, not pixelated", () => {
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const tail = css.slice(css.lastIndexOf("/* Uploaded photographs are normal-resolution backgrounds"));
  assert.match(tail, /html body \.world-layer--cave[\s\S]*?image-rendering: auto !important/);
  assert.match(tail, /transform: none !important/);
  assert.match(tail, /background-size: cover !important/);
  assert.match(tail, /transition: opacity 1\.15s ease !important/);
  assert.ok(/<link rel="stylesheet" href="css\/style\.css\?v=\d+">/.test(html));
});


test("страницы входа и регистрации имеют свои кнопки и увеличенные рамки ссылок", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(html, /id="bookSign"[^>]*>Войти<\/button>/);
  assert.match(app, /isPasswordReset\s*\?\s*"Сохранить пароль"/);
  assert.match(app, /:\s*!isRegistration\s*\?\s*"Войти"/);
  assert.match(app, /:\s*isCode\s*\?\s*"Подтвердить"/);
  assert.match(app, /"Зарегистрироваться"/);
  assert.match(css, /button#forgotPassword/);
  assert.match(css, /button#returnToPage2/);
  assert.match(css, /min-height:40px !important/);
  assert.doesNotMatch(html, />Готово<\/button>/);
  assert.doesNotMatch(app, /sign\.textContent = "Готово"/);
  assert.match(html, /id="openRegistration"[\s\S]*?id="bookSign"/);
  assert.doesNotMatch(html, /class="book-actions"/);
  assert.match(app, /targetPage\.appendChild\(sign\)/);
  assert.ok(css.includes("right: max(16px, calc((100vw - 550px) / 2 - 78px)) !important"));
  assert.ok(css.includes("left: 50% !important"));
});
test("toolbar and bell notifications have one consistent control height", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(html, /id="notificationBell"/);
  assert.match(html, /id="notificationPanel"/);
  assert.match(html, /id="notificationCount"/);
  assert.doesNotMatch(html, /data-page="notices"/);
  assert.match(css, /--scrl-toolbar-control:38px/);
  assert.match(css, /\.notification-panel[\s\S]*?position:absolute/);
  assert.match(app, /function updateNotificationBell\(\)/);
  assert.match(app, /markNotificationsRead\(\)/);
  assert.ok(app.includes('if (document.body?.classList) document.body.classList.add("app-active")'));
  assert.ok(app.includes('if (document.body?.classList) document.body.classList.remove("app-active")'));
  assert.match(css, /body\.app-active \.world-scenery[\s\S]*?blur\(7px\)/);
});

test("bell counter only shows unread notices for the current user", () => {
  const { api, els } = boot();
  api.notify("u0", "Твоя сделка создана.");
  api.notify("u1", "Это уведомление другого участника.");
  api.updateNotificationBell();
  assert.equal(els.get("notificationCount").textContent, "1");
  assert.equal(els.get("notificationCount").hidden, false);
  assert.match(els.get("notificationList").innerHTML, /Твоя сделка создана/);
  assert.doesNotMatch(els.get("notificationList").innerHTML, /другого участника/);
  api.action({ dataset: { do: "readall" } });
  api.updateNotificationBell();
  assert.equal(els.get("notificationCount").hidden, true);
  assert.equal(els.get("notificationSummary").textContent, "Всё прочитано");
});


test("верхняя панель показывает доступный баланс и главная не дублирует навигацию кнопками", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.match(html, /id="topbarBalance"/);
  assert.match(html, /id="topbarScrlBalance"/);
  assert.match(html, /id="topbarVrubBalance"/);
  assert.match(app, /function updateTopbarBalance\(\)/);
  assert.match(app, /el\("topbarBalance"\)\.addEventListener\("click"/);
  const home = app.slice(app.indexOf("function homePage()"), app.indexOf("function roleName(role)"));
  assert.doesNotMatch(home, /data-page=|link\(/);
  assert.match(css, /--scrl-toolbar-height: 76px/);
});

test("страницы книги используют читаемый текст и крестик не перекрывает номер страницы", () => {
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.match(css, /#auth \.book-page \.book-form--registration input[\s\S]*?font-size: 11\.5px !important/);
  assert.match(css, /#auth \.book-page #backToLogin[\s\S]*?top: 37px !important/);
  assert.match(css, /scrl-book-page-right/);
});


test("signup opens the eight-digit code step immediately and uses the published app redirect", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  assert.ok(app.includes('const APP_REDIRECT_URL = "https://www.scrl.site/";'));
  assert.match(app, /ask\("signup\?redirect_to=" \+ encodeURIComponent\(APP_REDIRECT_URL\)/);
  assert.match(app, /setCodePage\(\);/);
  assert.match(app, /type: "email"/);
  assert.doesNotMatch(html, /openRegistrationFromPage2|Перейти к регистрации/);
});

test("переключение входа и регистрации перелистывает страницу без изменения размеров книги", () => {
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  assert.match(css, /#auth \.auth-book\.is-spread #registrationPage/);
  assert.match(css, /#auth \.auth-book\.is-spread #loginPage/);
  assert.doesNotMatch(html, /book-spread|infoPage2|Страница 3/);
  assert.match(css, /#auth \.book-page::before[\s\S]*?display:none !important/);
});

test("underscore отображается и в форме регистрации, и в поле восьмизначного кода", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  assert.ok(app.includes('document.querySelectorAll("#authBook .mc-input-shell input")'));
  assert.ok(app.includes('input.type === "password"'));
  assert.ok(app.includes('"•".repeat(input.value.length)'));
  assert.ok(app.includes('cursor.textContent = "_"'));
  assert.ok(css.includes("html body #auth #codeForm input#code"));
  assert.ok(css.includes("html body .mc-writing-cursor[hidden]"));
  assert.match(app, /Этот код уже использован, заменён новым или истёк/);
  assert.ok(app.includes('el("code").value = ""'));
  assert.match(html, /id="regForm"/);
  assert.match(html, /id="codeForm"/);
});
test("email confirmation accepts the eight-digit OTP configured in Supabase", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  assert.match(app, /Введи восемь цифр из письма/);
  assert.match(app, /\[0-9\]\{8\}/);
  assert.match(html, /id="code"[^>]*maxlength="8" pattern="\[0-9\]\{8\}"/);
  assert.match(html, /восьмизначный код/);
  assert.ok(/<script src="js\/app\.js\?v=\d+" defer><\/script>/.test(html));
});


test("AI moderation has appeal screens, an admin case queue and clear external-processing disclosure", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.match(app, /function showBanAppeal\(\)/);
  assert.match(app, /backend\.submitAppeal\(ban\.id, reason\)/);
  assert.match(app, /backend\.adminReviewAppeal/);
  assert.match(app, /mod-case-restore/);
  assert.match(html, /id="banAppealForm"/);
  assert.match(html, /сообщения по сделкам/);
  assert.match(html, /id="moderationNotice"/);
  assert.match(css, /\.moderation-admin/);
});


test("new posts, listings and auctions show a distinct message when AI hides them", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(app, /Публикация скрыта ИИ до решения модератора/);
  assert.match(app, /Услуга скрыта ИИ до решения модератора/);
  assert.match(app, /Аукцион скрыт ИИ до решения модератора/);
});


test("market is removed from navigation and routing, auth no longer includes an onboarding spread", () => {
  const { api } = boot();
  assert.equal(api.marketPage, undefined);
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  assert.doesNotMatch(html, /Маркет и биржа/);
  assert.doesNotMatch(html, /Биржа ScRl/);
  assert.doesNotMatch(html, /book-spread|infoPage2|Как устроен ScRl/);
  assert.match(html, /Страница 1 \/ 2/);
  assert.match(html, /Страница 2 \/ 2/);
});


test("автор видит метку скрытия на своей публикации и счётчик совпадает со списком", () => {
  const { api } = boot();
  const owner = api.me();
  api.data.posts.unshift({
    id: "held-post-test", user: owner.id, type: "need", title: "Проверка",
    desc: "Тестовый материал", category: "Другое", price: 0,
    status: "hidden", date: Date.now()
  });
  const page = api.boardPage();
  assert.match(page, /Скрыта модерацией/);
  assert.match(page, /<span class="muted small">\d+ записей/);
});


test("profile name edits remain AI-moderated before PATCH", () => {
  const backend = fs.readFileSync(path.join(__dirname, "../js/backend.js"), "utf8");
  const start = backend.indexOf("async saveProfile");
  const end = backend.indexOf("async createPost", start);
  assert.ok(start >= 0 && end > start);
  const handler = backend.slice(start, end);
  assert.ok(handler.indexOf('moderationCheck("profile"') < handler.indexOf('request("/rest/v1/profiles'));
});

test("account deletion requires typed confirmation and demo mode cannot invoke it", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  assert.match(app, /id === "deleteAccountForm"/);
  assert.match(app, /confirmation !== "УДАЛИТЬ"/);
  assert.match(app, /remoteReady && !sess\(\)\?\.guest/);
  assert.match(html, /id="logout"[^>]*>Выйти<\/button>/);
  assert.match(app, /window\.confirm\("Выйти из аккаунта ScRl\?"\)/);
});

test("tablet and phone breakpoints prevent horizontal overflow", () => {
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.match(css, /@media \(max-width:1100px\)[\s\S]*?grid-template-columns:repeat\(5,minmax\(0,1fr\)\)/);
  assert.match(css, /@media \(max-width:620px\)[\s\S]*?grid-template-columns:minmax\(0,1fr\)/);
  assert.match(css, /overflow-x:clip/);
  assert.match(css, /\.logout-button[\s\S]*?transform:none !important/);
  assert.match(css, /\.account-danger/);
});

test("sign-in no longer waits for the dark book transition", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const localStart = app.indexOf("function enterLocal");
  const localEnd = app.indexOf("function showBanAppeal", localStart);
  const remoteStart = app.indexOf("async function enterRemote");
  const remoteEnd = app.indexOf("function enter(name", remoteStart);
  assert.doesNotMatch(app.slice(localStart, localEnd), /setTimeout\(revealApp, 420\)/);
  assert.doesNotMatch(app.slice(remoteStart, remoteEnd), /setTimeout\(revealApp, 420\)/);
});


test("логотип ScRl использует исправленное изображение без дублирующей надписи", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(html, /assets\/crb,blb\.png/);
  assert.match(html, /class="brand-logo"/);
  assert.doesNotMatch(html, /<span>ScRl<\/span>/);
  assert.match(css, /html body \.brand-logo[\s\S]*?transform:none !important/);
  assert.match(css, /object-fit:contain !important/);
  assert.match(html, /assets\/coinn\.png/);
  assert.match(app, /currency-coin-icon--inline/);
});


function promoteBootUserToAdmin(api, localStorage) {
  const user = api.data.users.find(item => item.id === "u0");
  user.role = "admin";
  localStorage.setItem("scrlSession", JSON.stringify({
    id: "u0", name: user.name, mail: user.mail || "", token: "unit-test", guest: false
  }));
  assert.equal(api.isAdminAccount(), true);
}

test("ученик видит обычные разделы, но не может открыть кабинет учителя и администратора", () => {
  const { api, els } = boot();
  assert.equal(api.me().role, "student");
  api.setPage("staff");
  assert.match(els.get("page").innerHTML, /Привет/);
  assert.match(api.staffPage(), /Нет доступа/);
  api.setPage("admin");
  assert.match(els.get("page").innerHTML, /Привет/);
  assert.match(api.adminPage(), /Нет доступа/);
  assert.match(api.financePage(), /Нет доступа/);
  assert.match(api.assistantPage(), /Нет доступа/);
});

test("учитель открывает свой кабинет и пульс, но не финансовые и административные разделы", () => {
  const { api, els } = boot();
  api.data.users.find(item => item.id === "u0").role = "teacher";
  api.setPage("staff");
  assert.match(els.get("page").innerHTML, /Кабинет учителя/);
  api.setPage("pulse");
  assert.match(els.get("page").innerHTML, /Пульс лицея/);
  assert.match(api.staffPage(), /Начислить ученику/);
  api.setPage("admin");
  assert.match(els.get("page").innerHTML, /Привет/);
  assert.match(api.adminPage(), /Нет доступа/);
  assert.match(api.financePage(), /Нет доступа/);
  assert.match(api.assistantPage(), /Нет доступа/);
});

test("администратор открывает кабинеты учителя, администратора, финансов и AI-помощника", () => {
  const { api, els, localStorage } = boot();
  promoteBootUserToAdmin(api, localStorage);
  api.setPage("staff");
  assert.match(els.get("page").innerHTML, /Кабинет учителя/);
  api.setPage("pulse");
  assert.match(els.get("page").innerHTML, /Пульс лицея/);
  api.setPage("admin");
  assert.match(els.get("page").innerHTML, /Администрирование/);
  api.setPage("finance");
  assert.match(els.get("page").innerHTML, /Платежи/);
  api.setPage("assistant");
  assert.match(els.get("page").innerHTML, /AI Moderator/);
});


test("админ-панель сохраняет инструменты в компактных разделах и отделяет удаление от блокировки", () => {
  const { api, localStorage } = boot();
  promoteBootUserToAdmin(api, localStorage);
  const page = api.adminPage();
  assert.match(page, /<details class="admin-section admin-section--members" open>/);
  assert.match(page, /Экономика ScRl/);
  assert.match(page, /ИИ-модерация/);
  assert.match(page, /Жалобы и споры/);
  assert.match(page, /Журнал действий/);
  assert.match(page, /data-do="block"/);
  assert.match(page, /data-do="removeuser"/);
  assert.match(page, /data-do="deleteuser"/);
  assert.match(page, /data-do="promote"/);
  assert.match(page, /data-do="set-room"/);
});

test("роль родителя доступна только как временный предпросмотр администратора", () => {
  const { api, els, localStorage } = boot();
  promoteBootUserToAdmin(api, localStorage);
  const storedUser = api.data.users.find(item => item.id === "u0");
  api.setAdminPreviewRole("parent");
  assert.equal(api.me().role, "parent");
  assert.equal(storedUser.role, "admin");
  assert.match(api.parentPage(), /Кабинет родителя/);
  assert.match(api.parentPage(), /не показываются данные учеников/);
  api.setPage("admin");
  assert.match(els.get("page").innerHTML, /Кабинет родителя/);
  assert.match(api.adminPage(), /Нет доступа/);
  assert.match(api.staffPage(), /Нет доступа/);
  assert.equal(els.get("topbarBalance").hidden, true);
  assert.equal(els.get("notificationWrap").hidden, true);
  assert.equal(els.get("nav-home").hidden, true);
  api.action({ dataset: { do: "exit-parent-preview" } });
  assert.equal(api.me().role, "admin");
  assert.match(els.get("page").innerHTML, /Привет/);
});

test("студент и учитель не могут включить тестовую роль родителя", () => {
  const { api } = boot();
  assert.throws(() => api.setAdminPreviewRole("parent"), /только аккаунту администратора/);
  api.data.users.find(item => item.id === "u0").role = "teacher";
  assert.throws(() => api.setAdminPreviewRole("parent"), /только аккаунту администратора/);
});

test("логотип и монета показываются в контрастных окнах, прозрачный рисунок увеличен", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.match(html, /brand-logo-frame[\s\S]*?assets\/crb,blb\.png/);
  assert.match(html, /currency-coin-frame[\s\S]*?assets\/coinn\.png/);
  assert.match(app, /currency-coin-frame--inline/);
  assert.match(css, /\.brand-logo-frame[\s\S]*?overflow:hidden/);
  assert.match(css, /\.currency-coin-frame[\s\S]*?border-radius:50%/);
  assert.match(css, /html\[data-theme="light"\] body #page \.muted[\s\S]*?color:#596b61/);
});


test("удаление своей публикации работает в демо и доступно для публикаций на проверке", () => {
  const { api } = boot();
  const own = {
    id: "own-post-delete-test", user: api.me().id, type: "need", title: "Удалить",
    desc: "Тестовая запись", category: "Другое", price: 0, status: "review", date: Date.now()
  };
  api.data.posts.unshift(own);
  assert.match(api.boardPage(), /data-do="remove-post"[^>]*>Удалить<\/button>/);
  api.action({ dataset: { do: "remove-post", id: own.id } });
  assert.equal(api.data.posts.some(post => post.id === own.id), false);
});

test("удаление поста не обходит защиту активных сделок", () => {
  const { api } = boot();
  const own = {
    id: "own-post-with-deal", user: api.me().id, type: "need", title: "В работе",
    desc: "Не удалять при активной сделке", category: "Другое", price: 0, status: "active", date: Date.now()
  };
  api.data.posts.unshift(own);
  api.data.deals.unshift({ id: "active-post-deal", buyer: "u1", seller: "u0", source: "board", sourceId: own.id, status: "work" });
  assert.throws(() => api.action({ dataset: { do: "remove-post", id: own.id } }), /активную сделку/);
  assert.equal(api.data.posts.some(post => post.id === own.id), true);
});

test("фоновая сцена кэшируется service worker для повторных посещений", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const worker = fs.readFileSync(path.join(__dirname, "../sw.js"), "utf8");
  assert.match(app, /new URL\("\.\.\/sw\.js", appScriptUrl\)\.href/);
  assert.match(app, /не удалось зарегистрировать кэш фона/);
  assert.match(worker, /scrl-world-backgrounds-v5/);
  assert.match(worker, /night\.png/);
  assert.match(worker, /day\.png/);
  assert.match(worker, /cache\.match\(cacheUrl, \{ ignoreSearch: true \}\)/);
  assert.match(worker, /cache\.put\(url, response\.clone\(\)\)/);
  assert.match(worker, /await self\.skipWaiting\(\)/);
});

test("small metadata text and logo/coin alignment overrides are present", () => {
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.match(css, /#page \.small[\s\S]*?font-size:14px !important/);
  assert.match(css, /\.brand-logo-frame[\s\S]*?place-items:center !important/);
  assert.match(css, /\.currency-coin-frame[\s\S]*?align-self:center !important/);
});


test("mobile flex bases match the smaller logo and coin frames", () => {
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const tail = css.slice(css.lastIndexOf("Keep flex bases in sync"));
  assert.match(tail, /brand-logo-frame[\s\S]*?flex-basis:40px !important/);
  assert.match(tail, /currency-coin-frame[\s\S]*?flex-basis:24px !important/);
});


test("ученик не может редактировать класс в профиле, администратор может", () => {
  const { api } = boot();
  assert.match(api.profilePage(), /name="room"[^>]*readonly aria-readonly="true"/);
  api.enter("Администратор", "admin@example.test", "", false, "u0");
  api.data.users.find(user => user.id === api.me().id).role = "admin";
  const adminProfile = api.profilePage();
  assert.match(adminProfile, /id="profileRole"/);
  assert.doesNotMatch(adminProfile, /name="room"[^>]*readonly aria-readonly="true"/);
  assert.match(api.adminPage(), /data-do="set-room"/);
});

test("недельный лимит начислений использует понедельник по часовому поясу Варшавы", () => {
  const { api } = boot();
  assert.equal(api.weekKey(new Date("2026-11-15T21:30:00.000Z")), "2026-11-09");
  assert.equal(api.weekKey(new Date("2026-11-15T23:30:00.000Z")), "2026-11-16");
});

test("неудачная ставка не возвращает и не портит резерв предыдущего лидера", () => {
  const { api } = boot();
  const auction = api.data.auctions.find(item => item.id === "a1");
  const bidder = api.me();
  const previousLeader = api.getUser("u2");
  auction.bid = 70;
  auction.leader = previousLeader.id;
  previousLeader.holdScrl = 70;
  previousLeader.scrl = 12;
  bidder.scrl = 2;
  api.data.bids = api.data.bids.filter(bid => bid.auction !== auction.id);
  const previousBid = { id: "previous-bid-test", auction: auction.id, user: previousLeader.id, amount: 70, status: "active", date: Date.now() };
  api.data.bids.push(previousBid);

  assert.throws(() => api.bid(auction.id, 100), /Недостаточно ScRl/);
  assert.equal(previousLeader.holdScrl, 70);
  assert.equal(previousLeader.scrl, 12);
  assert.equal(previousBid.status, "active");
  assert.equal(auction.leader, previousLeader.id);
  assert.equal(auction.bid, 70);
});

test("повышение собственной ставки сначала освобождает предыдущий резерв", () => {
  const { api } = boot();
  const auction = api.data.auctions.find(item => item.id === "a1");
  const bidder = api.me();
  auction.bid = 70;
  auction.leader = bidder.id;
  bidder.holdScrl = 70;
  bidder.scrl = 50;
  api.data.bids = api.data.bids.filter(bid => bid.auction !== auction.id);
  api.data.bids.push({ id: "own-old-bid", auction: auction.id, user: bidder.id, amount: 70, status: "active", date: Date.now() });

  api.bid(auction.id, 90);
  assert.equal(auction.bid, 90);
  assert.equal(auction.leader, bidder.id);
  assert.equal(bidder.holdScrl, 90);
  assert.equal(bidder.scrl, 30);
  assert.equal(api.data.bids.find(bid => bid.id === "own-old-bid").status, "raised");
});

test("профиль заблокированного или удалённого аккаунта нельзя менять в админке", () => {
  const { api } = boot();
  const admin = api.me();
  admin.role = "admin";
  const deleted = api.getUser("u2");
  deleted.deleted = true;
  const page = api.adminPage();
  assert.match(page, /Удалённый профиль/);
  assert.doesNotMatch(page, /data-do="set-room" data-id="u2"/);
});


test("администратор не может блокировать участника с незавершённой сделкой", () => {
  const { api } = boot();
  api.enter("Администратор", "admin@example.test", "", false, "u0");
  api.data.users.find(user => user.id === "u0").role = "admin";
  const target = api.getUser("u2");
  api.data.deals.unshift({ id: "block-active-deal", buyer: target.id, seller: "u1", status: "work" });
  assert.throws(() => api.action({ dataset: { do: "block", id: target.id } }), /активные сделки/);
  assert.equal(target.blocked, false);
});

test("удаление аккаунта списывает остатки и уменьшает активную денежную массу", () => {
  const fs = require("node:fs");
  const migration = fs.readFileSync(path.join(__dirname, "../supabase/migrations/20261116130440_remove_deleted_wallet_balances_from_supply.sql"), "utf8");
  assert.match(migration, /SET scrl = 0,\s*vrub = 0,\s*hold_scrl = 0,\s*hold_vrub = 0/);
  assert.match(migration, /burned_scrl = burned_scrl \+ v_wallet\.scrl/);
  assert.match(migration, /'V-RUB', -v_wallet\.vrub/);
  assert.match(migration, /UPDATE public\.ledger[\s\S]*note = 'Операция удалённого участника'/);
});


test("перелистывание авторизации сохраняет габариты и использует новый домен ScRl", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const readme = fs.readFileSync(path.join(__dirname, "../README.md"), "utf8");
  assert.match(html, /rel="canonical" href="https:\/\/www\.scrl\.site\//);
  assert.match(html, /property="og:url" content="https:\/\/www\.scrl\.site\//);
  assert.ok(app.includes('const APP_REDIRECT_URL = "https://www.scrl.site/";'));
  assert.match(readme, /https:\/\/scrl\.site\//);
  assert.match(css, /#auth \.auth-book\.is-spread,[\s\S]*?width: min\(100%,520px\) !important;[\s\S]*?height: min\(700px,calc\(100svh - 150px\)\) !important;/);
  assert.match(css, /#auth \.auth-book\.is-spread #loginPage[\s\S]*?transform: rotateY\(-180deg\) !important/);
  assert.match(css, /backface-visibility: hidden !important/);
});


test("Supabase Edge Functions default to canonical www and allow apex and legacy origins", () => {
  const root = path.join(__dirname, "../supabase/functions");
  const account = fs.readFileSync(path.join(root, "scrl-account/index.ts"), "utf8");
  const ai = fs.readFileSync(path.join(root, "scrl-ai/index.ts"), "utf8");
  const moderation = fs.readFileSync(path.join(root, "scrl-moderation/index.ts"), "utf8");
  for (const source of [account, ai, moderation]) {
    assert.match(source, /DEFAULT_ORIGIN\s*=\s*"https:\/\/www\.scrl\.site"/);
    assert.match(source, /WWW_ORIGIN\s*=\s*DEFAULT_ORIGIN/);
    assert.match(source, /APEX_ORIGIN\s*=\s*"https:\/\/scrl\.site"/);
    assert.match(source, /LEGACY_ORIGIN\s*=\s*"https:\/\/smisha2\.github\.io"/);
    assert.match(source, /new Set\(\[DEFAULT_ORIGIN, WWW_ORIGIN, APEX_ORIGIN, LEGACY_ORIGIN/);
  }
  assert.match(ai, /HTTP-Referer": "https:\/\/www\.scrl\.site\//);
});
test("вход сразу показывает проверку и подключение без декоративного ожидания", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const loginStart = app.indexOf("const loginFormConfigs");
  const loginEnd = app.indexOf("if (forgotPasswordButton)", loginStart);
  const loginHandler = app.slice(loginStart, loginEnd);
  const remoteStart = app.indexOf("async function enterRemote");
  const remoteEnd = app.indexOf("function enter(name", remoteStart);
  const remoteHandler = app.slice(remoteStart, remoteEnd);
  assert.ok(loginStart >= 0 && loginEnd > loginStart);
  assert.ok(loginHandler.indexOf('signButton.textContent = "Проверяем…"') >= 0);
  assert.ok(loginHandler.indexOf('signButton.textContent = "Проверяем…"') < loginHandler.indexOf('await ask("token?grant_type=password"'));
  assert.doesNotMatch(loginHandler, /setTimeout|setInterval/);
  assert.ok(remoteHandler.indexOf('showAppLoading(name || "Участник")') < remoteHandler.indexOf('await backend.load(token, id, mail)'));
  assert.doesNotMatch(remoteHandler, /setTimeout\s*\(/);
  assert.ok(html.includes('id="appLoading" class="app-loading" role="status" aria-live="polite" hidden'));
  assert.ok(html.includes('id="appLoadingText"'));
  assert.ok(css.includes(".app-loading-card"));
  assert.ok(css.includes(".app-loading-spinner"));
});
test("светлая и тёмная темы используют одинаковые текстовые подложки в своих цветах", () => {
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.ok(css.includes('html[data-theme="light"] body #page p,'));
  assert.ok(css.includes("background-color:#f7f9f1 !important"));
  assert.ok(css.includes('html[data-theme="dark"] body #page p,'));
  assert.ok(css.includes("background-color:#17231b !important"));
  assert.ok(css.includes('html[data-theme="light"] body #auth .book-subtitle'));
  assert.ok(css.includes('html[data-theme="dark"] body #auth .book-subtitle,'));
  assert.ok(css.includes("background-color:#f8f8ee !important"));
  assert.ok(css.includes("border:1px solid #334a38 !important"));
});
test("курсор использует нативный underscore без вертикальной полосы в поддерживаемых браузерах", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const nativeStart = css.lastIndexOf("@supports (caret-shape: underscore)");
  const fallbackRule = css.lastIndexOf("html body #auth #authBook .mc-input-shell input", nativeStart - 1);
  assert.ok(nativeStart > fallbackRule);
  assert.ok(css.slice(nativeStart).includes("caret-shape:underscore !important"));
  assert.ok(css.slice(nativeStart).includes("caret-color:#344b36 !important"));
  assert.ok(css.slice(nativeStart).includes("caret-color:#edf4e9 !important"));
  assert.ok(css.slice(nativeStart).includes(".mc-writing-cursor"));
  assert.ok(css.slice(nativeStart).includes("display:none !important"));
  assert.ok(css.includes("caret-color:transparent !important"));
  assert.ok(app.includes('window.CSS.supports("caret-shape", "underscore")'));
  assert.ok(app.includes('cursor.textContent = "_"'));
  assert.ok(app.includes('document.querySelectorAll("#authBook .mc-input-shell input")'));
});
test("кнопка выхода имеет ширину под подпись на десктопе и мобильных экранах", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.ok(html.includes('id="logout" class="logout-button" type="button" aria-label="Выйти из аккаунта" title="Выйти из аккаунта">Выйти</button>'));
  assert.ok(css.includes("html body #app .topbar .logout-button"));
  assert.ok(css.includes("flex:0 0 88px !important"));
  assert.ok(css.includes("flex-basis:78px !important"));
  assert.ok(css.includes("flex-basis:74px !important"));
  assert.ok(css.includes("white-space:nowrap !important"));
  assert.ok(css.includes("flex-basis:82px !important"));
});

test("workflow syntax-checks every browser JavaScript file and verifies both public domains", () => {
  const workflow = fs.readFileSync(path.join(__dirname, "../.github/workflows/deploy-pages.yml"), "utf8");
  assert.ok(workflow.includes("node --check js/backend.js"));
  assert.ok(workflow.includes("node --check sw.js"));
  assert.ok(workflow.includes("Verify production domains"));
  assert.ok(workflow.includes("https://www.scrl.site/"));
  assert.ok(workflow.includes('check_domain "www.scrl.site"'));
});


test("мобильная навигация показывает все разделы, а меню Ещё остаётся внутри навигации", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  for (const page of ["home", "board", "exchange", "auctions", "activity", "wallet", "orders", "favorites", "profile"]) {
    assert.ok(html.includes('data-page="' + page + '"'), "missing page " + page);
  }
  assert.match(css, /grid-template-columns:repeat\(3,minmax\(0,1fr\)\) !important/);
  assert.match(css, /overflow:visible !important/);
  assert.match(app, /function closeExtraMenu\(\)/);
  assert.doesNotMatch(app, /document\.body\.appendChild\(menu\)/);
  assert.match(app, /extraMenu\.addEventListener\("click"/);
});

test("кнопка регистрации остаётся в потоке, а ФИО сгруппировано в одну строку на ПК", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.match(html, /class="reg-name-grid"[\s\S]*id="regLast"[\s\S]*id="regFirst"[\s\S]*id="regPat"/);
  assert.match(css, /#auth #regForm \.reg-name-grid[\s\S]*grid-template-columns:repeat\(3,minmax\(0,1fr\)\)/);
  assert.match(css, /#bookSign\.book-action-button[\s\S]*position:static !important/);
});


test("desktop More popover uses fixed viewport positioning to escape nav overflow clipping", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(app, /extraMenu\.style\.setProperty\("position", "fixed", "important"\)/);
  assert.match(app, /moreButton\.getBoundingClientRect\(\)/);
  assert.match(app, /extraMenu\.style\.setProperty\("left"/);
  assert.match(app, /extraMenu\.style\.setProperty\("top"/);
  assert.match(app, /menu\.removeAttribute\("style"\)/);
});


test("toolbar uses a uniform grey achievement frame and the profile shortcut opens profile", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(html, /id="profileShortcut"[\s\S]*id="avatar"[\s\S]*id="userName"/);
  assert.ok(app.includes('if (el("profileShortcut")) el("profileShortcut").addEventListener("click", () => setPage("profile"));'));
  assert.match(css, /--scrl-achievement-fill:#c6c6c6/);
  assert.match(css, /topbar \.main-nav \.nav-tab\.is-active/);
  assert.match(css, /topbar \.topbar-profile/);
  assert.match(css, /theme-btn\.theme-switch[\s\S]*border-radius:999px !important/);
  assert.match(css, /auth-theme-btn[\s\S]*left:min\(calc\(50% \+ 286px\),calc\(100vw - 78px\)\) !important/);
});


test("переключатель темы авторизации поднят выше, а размеры боксов панели зафиксированы", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.ok(/<link rel="stylesheet" href="css\/style\.css\?v=\d+">/.test(html));
  assert.match(css, /auth-theme-btn\s*\{\s*top:clamp\(16px,calc\(50% - 285px\),220px\) !important/);
  assert.match(css, /\[data-page="home"\][\s\S]*flex:0 0 96px !important/);
  assert.match(css, /\[data-page="board"\][\s\S]*flex:0 0 78px !important/);
  assert.match(css, /topbar \.topbar-balance\s*\{\s*flex:0 0 154px !important/);
  assert.match(css, /topbar \.topbar-profile\s*\{\s*flex:0 0 180px !important/);
  assert.match(css, /border-width:3px !important/);
  assert.match(css, /letter-spacing:0 !important/);
});


test("board post prices are uncapped from publication through checkout", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const boardPage = app.slice(app.indexOf("function boardPage()"), app.indexOf("function marketPage()"));
  assert.match(boardPage, /name="price" type="number" min="0" step="any"/);
  assert.doesNotMatch(boardPage, /max="500"/);

  const remoteStart = app.indexOf('if (form.id === "boardForm")');
  const remoteEnd = app.indexOf('if (form.id === "marketForm")', remoteStart);
  assert.ok(remoteStart >= 0 && remoteEnd > remoteStart);
  assert.doesNotMatch(app.slice(remoteStart, remoteEnd), /price > 500/);

  const localSubmit = app.indexOf("async function submit(form)");
  const localStart = app.indexOf('if (form.id === "boardForm")', localSubmit);
  const localEnd = app.indexOf('if (form.id === "marketForm")', localStart);
  assert.ok(localStart >= 0 && localEnd > localStart);
  assert.doesNotMatch(app.slice(localStart, localEnd), /price > 500/);

  const dealStart = app.indexOf("function createDeal(");
  const dealEnd = app.indexOf("function refreshFee(", dealStart);
  assert.doesNotMatch(app.slice(dealStart, dealEnd), /price > 500/);
});

test("password recovery uses the hidden zero page and leaves normal auth on pages 1 and 2", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(html, /id="forgotPasswordForm"/);
  assert.match(html, /id="authPageCounter"[^>]*>Страница 1 \/ 2/);
  assert.match(html, /<span class="page-counter">Страница 2 \/ 2<\/span>/);
  assert.match(app, /forgotPasswordButton\.addEventListener\("click", openPasswordRecoveryPage\)/);
  assert.match(app, /book\.dataset\.activePage = "0"/);
  assert.match(app, /404\/\?\?\?/);
  assert.match(app, /params\.get\("type"\) !== "recovery"/);
});

test("recovery link keeps its token and form ahead of any saved session", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(app, /let passwordRecoveryRequested = false;/);
  assert.match(app, /passwordRecoveryRequested = true;/);
  assert.match(app, /if \(oldSess && !passwordRecoveryRequested\)/);
  assert.match(app, /if \(!passwordRecoveryRequested\) setMode\("login"\);/);
  assert.match(app, /setPasswordRecoveryPage\(accessToken\)/);
  assert.match(app, /clearSession\(\);[\s\S]*sessionStorage\.removeItem\("scrlRecoveryEmail"\)/);
});

test("visible profile names use surname and initials without changing stored full names", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  assert.match(app, /function shortProfileName\(value\)/);
  assert.match(app, /return \[parts\[0\], initial\(parts\[1\]\), parts\[2\] \? initial\(parts\[2\]\) : ""\]/);
  assert.match(app, /shortProfileName\(me\(\)\.name/);
  assert.match(app, /shortProfileName\(user\.name\)/);
});

test("obfuscation-aware moderation combines fields and routes manual review to admins only", () => {
  const moderation = fs.readFileSync(path.join(__dirname, "../supabase/functions/scrl-moderation/index.ts"), "utf8");
  assert.match(moderation, /fields_joined_in_original_order/);
  assert.match(moderation, /visual_confusables_folded/);
  assert.match(moderation, /punctuation_and_spacing_removed/);
  assert.match(moderation, /mixed_script_tokens/);
  assert.match(moderation, /result\.confidence<0\.74/);
  assert.match(moderation, /role=eq\.admin/);
  assert.match(moderation, /Новое объявление ожидает ручной проверки администратора/);
  assert.match(moderation, /Получена новая жалоба; требуется ручная проверка администратора/);
});

test("administrator deletion accepts other admin accounts but validates the acting admin in SQL", () => {
  const account = fs.readFileSync(path.join(__dirname, "../supabase/functions/scrl-account/index.ts"), "utf8");
  const migration = fs.readFileSync(path.join(__dirname, "../supabase/migrations/20261117023621_board_pricing_and_admin_account_permissions.sql"), "utf8");
  assert.match(account, /\["student", "teacher", "admin"\]/);
  assert.match(account, /userClient\.rpc\("scrl_delete_account"/);
  assert.match(account, /auth\.admin\.deleteUser\(targetId\)/);
  assert.match(migration, /AND NOT public\.scrl_is_admin\(\)/);
  assert.match(migration, /Сначала назначь другого администратора/);
});

test("администратор может снять обычную и ИИ-блокировку отдельным действием", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const backend = fs.readFileSync(path.join(__dirname, "../js/backend.js"), "utf8");
  const migration = fs.readFileSync(path.join(__dirname, "../supabase/migrations/20261117025403_admin_unblock_users_and_lift_ai_bans.sql"), "utf8");

  assert.match(app, /if \(wasBlocked\) \{\s*await backend\.adminUnblockUser\(id\);/);
  assert.match(backend, /adminUnblockUser\(id\)\s*\{\s*return rpc\("scrl_admin_unblock_user",\s*\{\s*p_target:\s*id\s*\}\);\s*\}/);
  assert.match(migration, /public\.scrl_is_admin\(\)/);
  assert.match(migration, /UPDATE public\.scrl_moderation_bans[\s\S]*?active = false/);
  assert.match(migration, /UPDATE public\.profiles[\s\S]*?blocked = false/);
});

test("владелец может удалить собственную публикацию", () => {
  const { api } = boot();
  const own = {
    id: "own-delete-test", user: api.me().id, type: "offer",
    title: "Моя тестовая публикация", desc: "Тест", category: "Другое",
    price: 0, status: "active", date: Date.now()
  };
  api.data.posts.unshift(own);
  api.action({ dataset: { do: "remove-post", id: own.id } });
  assert.equal(api.data.posts.some(item => item.id === own.id), false);
});

test("администратор видит скрытые публикации и кнопку удаления", () => {
  const { api } = boot();
  api.me().role = "admin";
  api.data.posts.unshift({
    id: "foreign-hidden-post", user: "u2", type: "need",
    title: "Чужая скрытая публикация", desc: "Тест", category: "Другое",
    price: 0, status: "hidden", date: Date.now()
  });
  const page = api.adminPage();
  assert.match(page, /Публикации/);
  assert.match(page, /Чужая скрытая публикация/);
  assert.match(page, /data-do="admin-delete-publication" data-kind="post" data-id="foreign-hidden-post"/);
});

test("администратор может удалить чужую публикацию в локальном режиме", () => {
  const { api } = boot();
  api.me().role = "admin";
  const foreign = {
    id: "admin-delete-test", user: "u2", type: "need",
    title: "Публикация другого участника", desc: "Тест", category: "Другое",
    price: 0, status: "active", date: Date.now()
  };
  api.data.posts.unshift(foreign);
  api.action({ dataset: { do: "admin-delete-publication", id: foreign.id, kind: "post" } });
  assert.equal(api.data.posts.some(item => item.id === foreign.id), false);
});

test("владелец может удалить собственную услугу", () => {
  const { api } = boot();
  const own = {
    id: "own-listing-test", user: api.me().id, title: "Моя услуга",
    desc: "Тест", category: "Учёба", price: 1, slots: 1,
    status: "active", date: Date.now()
  };
  api.data.listings.unshift(own);
  api.action({ dataset: { do: "remove-listing", id: own.id } });
  assert.equal(api.data.listings.some(item => item.id === own.id), false);
});

test("удаление публикаций использует защищённую RPC с проверкой владельца и администратора", () => {
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const backend = fs.readFileSync(path.join(__dirname, "../js/backend.js"), "utf8");
  const migration = fs.readFileSync(path.join(__dirname, "../supabase/migrations/20261117030819_delete_publications_owner_or_admin.sql"), "utf8");
  assert.match(app, /await backend\.deletePublication\("post", id\)/);
  assert.match(app, /data-do="admin-delete-publication"/);
  assert.match(backend, /rpc\("scrl_delete_publication",\s*\{\s*p_kind:\s*String\(kind\),\s*p_id:\s*String\(id\)\s*\}\)/);
  assert.match(migration, /public\.scrl_is_admin\(\)/);
  assert.match(migration, /v_owner <> auth\.uid\(\)/);
  assert.match(migration, /public\.posts/);
  assert.match(migration, /public\.listings/);
});


test("обычный стиль устанавливается по умолчанию даже при старом сохранённом Minecraft", () => {
  const migrated = boot({ scrlStyle: "minecraft" });
  assert.equal(migrated.api.activeStyle(), "classic");
  assert.equal(migrated.localStorage.getItem("scrlStyle"), "classic");
  assert.equal(migrated.localStorage.getItem("scrlStyleDefaultVersion"), "2");

  const savedPreference = boot({ scrlStyle: "minecraft", scrlStyleDefaultVersion: "2" });
  assert.equal(savedPreference.api.activeStyle(), "minecraft");
});

test("обычный тёмный стиль включён по умолчанию, а тема и стиль сохраняются независимо", () => {
  const { api, localStorage } = boot();
  assert.equal(api.activeTheme(), "dark");
  assert.equal(api.activeStyle(), "classic");
  assert.match(api.settingsPage(), /Стиль сайта/);
  assert.match(api.settingsPage(), /Обычный/);
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.ok(!html.includes('id="authStyleBtn"'));
  assert.ok(css.includes('html[data-style="classic"] body #worldScenery'));
  assert.ok(css.includes('html[data-style="minecraft"] body #worldScenery'));
  assert.ok(css.includes('input[type="checkbox"]:checked::after'));

  api.applyStyle("minecraft");
  assert.equal(api.activeStyle(), "minecraft");
  assert.equal(api.activeTheme(), "dark");
  assert.equal(localStorage.getItem("scrlStyle"), "minecraft");

  api.switchTheme();
  assert.equal(api.activeTheme(), "light");
  assert.equal(api.activeStyle(), "minecraft");

  api.switchStyle();
  assert.equal(api.activeStyle(), "classic");
  assert.equal(api.activeTheme(), "light");
  assert.equal(localStorage.getItem("scrlStyle"), "classic");
});


test("счётчик публикаций считает карточки, а не длину HTML-разметки", () => {
  const { api } = boot();
  const owner = api.me().id;
  api.data.posts = [
    { id: "count-post-1", user: owner, type: "offer", title: "Первый тест", desc: "Описание", category: "Учёба", price: 0, status: "active", date: 2 },
    { id: "count-post-2", user: owner, type: "need", title: "Второй тест", desc: "Описание", category: "Математика", price: 0, status: "active", date: 1 }
  ];
  const page = api.boardPage();
  assert.match(page, /<span class="muted small">2 записей<\/span>/);
  assert.doesNotMatch(page, /1688 записей/);
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const board = app.slice(app.indexOf("function boardPage()"), app.indexOf("function marketPage()"));
  assert.ok(board.includes("visiblePosts.length"));
  assert.ok(!board.includes("rows.length"));
});

test("переход темы ограничен фоном и учитывает стиль оформления", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const app = fs.readFileSync(path.join(__dirname, "../js/app.js"), "utf8");
  const css = fs.readFileSync(path.join(__dirname, "../css/style.css"), "utf8");
  assert.ok(!html.includes('id="themeTransition"'));
  assert.ok(!app.includes("themeTransition"));
  assert.match(css, /html\[data-style="classic"\]\[data-theme="light"\][\s\S]*?background-color/);
  assert.match(css, /html\[data-style="classic"\]\[data-theme="dark"\][\s\S]*?background-color/);
  assert.match(css, /html\[data-style="minecraft"\] body \.world-layer[\s\S]*?transition: opacity 1\.15s ease/);
  assert.ok(!html.includes('id="authStyleBtn"'));
  assert.ok(!html.includes('id="styleModeToggle"'));
  assert.match(html, /id="authThemeBtn"/);
});

test("страница «Данные и согласия» возвращает весь контент и форму", () => {
  const { api } = boot();
  const page = api.privacyPage();
  assert.match(page, /Какие данные обрабатываются/);
  assert.match(page, /ScRl использует ФИО/);
  assert.match(page, /privacyConsentForm/);
  assert.match(page, /privacyBirthDate/);
  assert.match(page, /name="allConsents"/);
  assert.match(page, /Сохранить согласия/);
  assert.match(page, /legal\/privacy\.html/);
});
