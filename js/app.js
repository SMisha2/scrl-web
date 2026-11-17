const el = id => document.getElementById(id);
const cfg = window.cfg || {};
const APP_REDIRECT_URL = window.location?.origin && window.location?.pathname
  ? window.location.origin + window.location.pathname
  : "https://smisha2.github.io/scrl-web/";
const backend = window.ScrlBackend;
let remoteReady = false;
let closingAuctions = false;
const core = window.ScrlCore;
const auth = el("auth");
const app = el("app");
const login = el("loginForm");
const reg = el("regForm");
const codeForm = el("codeForm");
const toast = el("toast");
const key = "scrlDemo3";
let pending = null;
let filter = { term: "", type: "all" };
let adminFilter = { term: "", role: "all", locked: "all" };
let marketFilter = { term: "", category: "all", sort: "new" };
let adminPreviewRole = "";

function msg(text) {
  toast.textContent = text;
  toast.classList.add("is-visible");
  clearTimeout(msg.timer);
  msg.timer = setTimeout(() => toast.classList.remove("is-visible"), 2600);
}

function installMinecraftBookCursors() {
  if (window.__scrlTestMode || !document.querySelectorAll) return;
  const measureCanvas = document.createElement("canvas");
  const measureContext = measureCanvas.getContext && measureCanvas.getContext("2d");
  document.querySelectorAll("#authBook .mc-input-shell input").forEach(input => {
    if (input.id === "code") return; // OTP uses the browser caret so it cannot drift.
    const shell = input.parentElement;
    if (!shell || shell.querySelector(".mc-writing-cursor")) return;
    const cursor = document.createElement("span");
    cursor.className = "mc-writing-cursor";
    cursor.textContent = "_";
    cursor.setAttribute("aria-hidden", "true");
    shell.appendChild(cursor);

    const positionCursor = () => {
      if (document.activeElement !== input) return;
      const style = window.getComputedStyle(input);
      const text = input.type === "password" ? "•".repeat(input.value.length) : input.value;
      const caret = typeof input.selectionStart === "number" ? input.selectionStart : text.length;
      const letterSpacing = Number.parseFloat(style.letterSpacing) || 0;

      if (measureContext) {
        measureContext.font = style.font || (style.fontWeight + " " + style.fontSize + " " + style.fontFamily);
      }
      const measure = value => {
        if (!value) return 0;
        const glyphWidth = measureContext ? measureContext.measureText(value).width : value.length * 8;
        return glyphWidth + Math.max(0, value.length - 1) * letterSpacing;
      };

      const prefix = text.slice(0, caret);
      let prefixWidth = measure(prefix);
      if (caret > 0 && caret < text.length) prefixWidth += letterSpacing;

      const leftPad = parseFloat(style.paddingLeft) || 0;
      const rightPad = parseFloat(style.paddingRight) || 0;
      const contentWidth = Math.max(0, input.clientWidth - leftPad - rightPad);
      const fullTextWidth = measure(text);
      let textStart = leftPad;
      if (style.textAlign === "center") {
        textStart += (contentWidth - fullTextWidth) / 2;
      } else if (style.textAlign === "right" || style.textAlign === "end") {
        textStart += contentWidth - fullTextWidth;
      }

      const shellRect = shell.getBoundingClientRect();
      const inputRect = input.getBoundingClientRect();
      const inputLeft = inputRect.left - shellRect.left + input.clientLeft;
      const minLeft = inputLeft + leftPad;
      const maxLeft = Math.max(minLeft, inputLeft + input.clientWidth - rightPad);
      const caretLeft = inputLeft + textStart + prefixWidth - input.scrollLeft;
      cursor.style.left = Math.max(minLeft, Math.min(maxLeft, caretLeft)) + "px";
      if (style.font) cursor.style.font = style.font;
      cursor.style.letterSpacing = "0";
    };

    input.addEventListener("focus", () => {
      shell.classList.add("is-typing");
      positionCursor();
    });
    input.addEventListener("blur", () => shell.classList.remove("is-typing"));
    ["input", "keyup", "click", "select", "scroll"].forEach(name => input.addEventListener(name, positionCursor));
  });
}

function updateBookControls() {
  const book = el("authBook");
  if (!book) return;
  const isSpread = book.classList.contains("is-spread");
  const activePage = book.dataset.activePage || (isSpread ? "3" : "1");
  const isCode = !codeForm.hidden;
  const sign = el("bookSign");
  if (sign) {
    const target = !isSpread ? "loginForm" : isCode ? "codeForm" : "regForm";
    sign.setAttribute("form", target);
    sign.textContent = "Готово";
  }
  const single = el("loginPage");
  const spread = el("bookSpread");
  const page2 = el("infoPage2");
  const page3 = el("registrationPage");
  if (single) single.inert = isSpread;
  if (spread) {
    spread.setAttribute("aria-hidden", String(!isSpread));
    spread.inert = !isSpread;
  }
  if (page2) page2.inert = !isSpread;
  if (page3) page3.inert = !isSpread;
  const bookDone = el("bookDone");
  if (bookDone) bookDone.textContent = isSpread ? "Назад" : "Готово";
}

function setMode(mode) {
  const book = el("authBook");
  const isSpread = mode === "reg";
  const activePage = isSpread ? "3" : "1";
  if (book) {
    book.classList.toggle("is-spread", isSpread);
    book.classList.remove("is-page-2");
    book.dataset.activePage = activePage;
  }

  login.hidden = false;
  reg.hidden = !isSpread;
  codeForm.hidden = true;
  if (el("banAppealPanel")) el("banAppealPanel").hidden = true;
  if (el("returnToPage2")) el("returnToPage2").hidden = false;
  if (el("bookSign")) el("bookSign").hidden = false;

  if (el("loginTab")) el("loginTab").classList.toggle("is-active", activePage === "2");
  if (el("regTab")) el("regTab").classList.toggle("is-active", activePage === "3");
  if (el("authTitle")) el("authTitle").textContent = "Регистрация";
  if (el("authDesc")) el("authDesc").textContent = "Создайте новую запись в книге.";
  if (el("logErr")) el("logErr").textContent = "";
  if (el("regErr")) el("regErr").textContent = "";
  updateBookControls();
}
function safe(value) {
  return String(value ?? "").replace(/[&<>"']/g, char => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  })[char]);
}

function money(value) {
  return Number(value || 0).toLocaleString("ru-RU", { maximumFractionDigits: 2 });
}

function rateMoney(value) {
  return Number(value || 0).toLocaleString("ru-RU", { minimumFractionDigits: 3, maximumFractionDigits: 4 });
}

function uid() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
}

function seed() {
  const now = Date.now();
  return {
    users: [
      { id: "u0", name: "Гость", mail: "", role: "student", room: "9А", scrl: 420, vrub: 1250, holdScrl: 0, holdVrub: 0, blocked: false },
      { id: "u1", name: "Алина", mail: "alina@example.test", role: "student", room: "9А", scrl: 70, vrub: 700, holdScrl: 50, holdVrub: 0, blocked: false },
      { id: "u2", name: "Марк", mail: "mark@example.test", role: "student", room: "9А", scrl: 190, vrub: 290, holdScrl: 60, holdVrub: 10, blocked: false },
      { id: "u3", name: "София", mail: "sofia@example.test", role: "student", room: "9Б", scrl: 180, vrub: 450, holdScrl: 0, holdVrub: 0, blocked: false },
      { id: "t1", name: "Елена Сергеевна", mail: "teacher@example.test", role: "teacher", room: "9А", scrl: 0, vrub: 0, holdScrl: 0, holdVrub: 0, blocked: false },
      { id: "ad1", name: "Администратор", mail: "admin@example.test", role: "admin", room: "", scrl: 0, vrub: 0, holdScrl: 0, holdVrub: 0, blocked: false }
    ],
    posts: [
      { id: "p1", type: "need", title: "Нужна помощь с алгеброй", desc: "Хочу разобраться с квадратными уравнениями.", category: "Математика", price: 20, user: "u1", status: "active", date: now - 3600000 },
      { id: "p2", type: "offer", title: "Помогу с английским", desc: "Можем вместе разобрать времена и упражнения.", category: "Языки", price: 15, user: "u2", status: "active", date: now - 7200000 },
      { id: "p3", type: "offer", title: "Сделаю презентацию", desc: "Помогу с оформлением школьного проекта.", category: "Дизайн", price: 30, user: "u3", status: "active", date: now - 10800000 }
    ],
    listings: [
      { id: "l1", title: "Дизайн презентации", desc: "Аккуратное оформление до 10 слайдов.", category: "Дизайн", price: 35, user: "u2", slots: 2, status: "active", date: now - 3600000 },
      { id: "l2", title: "Помощь с английским", desc: "Разберём сложную тему вместе.", category: "Учёба", price: 20, user: "u3", slots: 3, status: "active", date: now - 7200000 }
    ],
    deals: [],
    book: [],
    exchangeOrders: [
      { id: "x1", side: "scrlSell", user: "u1", amount: 20, price: 0.052, status: "active", date: now - 60000 },
      { id: "x2", side: "vrubSell", user: "u2", amount: 10, price: 20, status: "active", date: now - 30000 }
    ],
    trades: [],
    auctions: [
      { id: "a1", title: "Набор для творчества", prize: "Скетчбук и маркеры", startPrice: 30, step: 10, bid: 60, leader: "u2", owner: "u3", ends: now + 86400000, status: "active" },
      { id: "a2", title: "Музыкальная перемена", prize: "Выбор музыки на один день", startPrice: 15, step: 5, bid: 30, leader: "u1", owner: "u2", ends: now + 172800000, status: "active" }
    ],
    bids: [
      { id: "ba1", auction: "a1", user: "u2", amount: 60, status: "active", date: now - 7200000 },
      { id: "ba2", auction: "a2", user: "u1", amount: 30, status: "active", date: now - 3600000 }
    ],
    ledger: [
      { id: "g1", user: "u0", currency: "ScRl", delta: 420, note: "Стартовый демо-баланс", date: now },
      { id: "g2", user: "u0", currency: "V-RUB", delta: 1250, note: "Стартовый демо-баланс", date: now }
    ],
    favorites: [],
    reviews: [],
    reports: [],
    notices: [],
    activity: [],
    audit: [],
    teacherUsed: {},
    fees: 0,
    burned: 0,
    rate: 0.05,
    fee: 0.01,
    moneyOps: [],
    aiMessages: []
  };
}

function getData() {
  try {
    const saved = JSON.parse(localStorage.getItem(key) || "null");
    if (saved && Array.isArray(saved.users) && Array.isArray(saved.posts) && Array.isArray(saved.listings) && Array.isArray(saved.deals)) {
      saved.moneyOps = Array.isArray(saved.moneyOps) ? saved.moneyOps : [];
      saved.aiMessages = Array.isArray(saved.aiMessages) ? saved.aiMessages : [];
      saved.teacherUsed = saved.teacherUsed && typeof saved.teacherUsed === "object" ? saved.teacherUsed : {};
      saved.fees = Number(saved.fees || 0);
      saved.burned = Number(saved.burned || 0);
      saved.rate = Number(saved.rate || 0.05);
      saved.fee = Number(saved.fee || 0.01);
      saved.users.forEach(user => {
        user.scrl = Number(user.scrl || 0);
        user.vrub = Number(user.vrub || 0);
        user.holdScrl = Number(user.holdScrl || 0);
        user.holdVrub = Number(user.holdVrub || 0);
        user.blocked = Boolean(user.blocked);
      });
      saved.ledger = Array.isArray(saved.ledger) ? saved.ledger : [];
      saved.reports = Array.isArray(saved.reports) ? saved.reports : [];
      saved.notices = Array.isArray(saved.notices) ? saved.notices : [];
      saved.activity = Array.isArray(saved.activity) ? saved.activity : [];
      saved.audit = Array.isArray(saved.audit) ? saved.audit : [];
      saved.favorites = Array.isArray(saved.favorites) ? saved.favorites : [];
      saved.reviews = Array.isArray(saved.reviews) ? saved.reviews : [];
      saved.trades = Array.isArray(saved.trades) ? saved.trades : [];
      saved.book = Array.isArray(saved.book) ? saved.book : [];
      if (!Array.isArray(saved.exchangeOrders)) {
        saved.exchangeOrders = [];
        (saved.book || []).filter(o => o.status === "open").forEach(o => {
          const owner = saved.users.find(u => u.id === o.user);
          if (!owner) return;
          if (o.side === "sell") {
            const amount = Number(o.left || o.qty || 0);
            owner.holdScrl = Math.max(0, Number(owner.holdScrl || 0) - amount);
            owner.scrl = core.round(Number(owner.scrl || 0) + amount);
          } else {
            const amount = core.round(Number(o.left || o.qty || 0) * Number(o.price || 0));
            owner.holdVrub = Math.max(0, Number(owner.holdVrub || 0) - amount);
            owner.vrub = core.round(Number(owner.vrub || 0) + amount);
          }
          saved.ledger.unshift({ id: "old" + Math.random().toString(36).slice(2,8), user: owner.id, currency: o.side === "sell" ? "ScRl" : "V-RUB", delta: o.side === "sell" ? Number(o.left || o.qty || 0) : Number(o.left || o.qty || 0) * Number(o.price || 0), note: "Возврат резерва старой заявки", date: Date.now() });
        });
      }
      saved.auctions = Array.isArray(saved.auctions) ? saved.auctions : [];
      if (!Array.isArray(saved.bids)) {
        saved.bids = saved.auctions.filter(a => a.leader && Number(a.bid) > 0).map(a => ({
          id: "migrated" + a.id, auction: a.id, user: a.leader, amount: Number(a.bid), status: "active", date: a.created || Date.now()
        }));
      }
      saved.exchangeOrders.forEach(order => { if (order.side === "sell_scrl") order.side = "scrlSell"; if (order.side === "sell_vrub") order.side = "vrubSell"; });
      saved.auctions.forEach(a => {
        if (a.status === "settlement_error") a.status = "settlementError";
        a.startPrice = Number(a.startPrice || 1);
        a.step = Number(a.step || 1);
        a.ends = Number(a.ends || Date.now());
        if (a.status === "done" && a.closed == null) a.closed = Date.now();
      });
      saved.deals.forEach(deal => {
        deal.messages = Array.isArray(deal.messages) ? deal.messages : [];
        if (deal.escrow == null) deal.escrow = Number(deal.amount || 0);
      });
      return saved;
    }
  } catch {}
  return seed();
}

let data = getData();

function save() {
  if (remoteReady && !window.__scrlTestMode) return;
  try {
    localStorage.setItem(key, JSON.stringify(data));
  } catch {
    msg("Не удалось сохранить данные в этом браузере.");
  }
}

function sess() {
  try {
    return JSON.parse(sessionStorage.getItem("scrlSession") || "null");
  } catch {
    return null;
  }
}

function getUser(id) {
  return data.users.find(user => user.id === id);
}

function isAdminAccount() {
  const session = sess();
  return Boolean(session && !session.guest && getUser(session.id)?.role === "admin");
}

function resetAdminPreviewRole() {
  adminPreviewRole = "";
}

function setAdminPreviewRole(role) {
  if (!isAdminAccount()) throw new Error("Режим просмотра доступен только аккаунту администратора.");
  const selected = String(role || "");
  if (!["admin", "student", "teacher"].includes(selected)) {
    throw new Error("Выбери роль администратора, ученика или учителя.");
  }
  adminPreviewRole = selected === "admin" ? "" : selected;
}

function me() {
  const s = sess();
  let user = s && getUser(s.id);
  if (!user && s) {
    user = { id: s.id || "u0", name: s.name || "Ученик", mail: s.mail || "", role: "student", room: "9А", scrl: 0, vrub: 0, holdScrl: 0, holdVrub: 0, blocked: false };
    data.users.push(user);
    save();
  }
  const activeUser = user || data.users[0];
  if (activeUser?.role === "admin" && adminPreviewRole) {
    return new Proxy(activeUser, {
      get(target, property, receiver) {
        if (property === "role") return adminPreviewRole;
        return Reflect.get(target, property, receiver);
      }
    });
  }
  return activeUser;
}

function userName(id) {
  return getUser(id)?.name || "Участник";
}

function change(id, currency, amount, note) {
  if (remoteReady && !window.__scrlTestMode) throw new Error("Баланс изменяется только через защищённые серверные операции.");
  const user = getUser(id);
  if (!user) throw new Error("Участник не найден.");
  const field = currency === "ScRl" ? "scrl" : "vrub";
  const value = Number(amount);
  if (!Number.isFinite(value)) throw new Error("Некорректная сумма.");
  if (user.blocked && value < 0) throw new Error("Аккаунт заблокирован.");
  const next = core.round(Number(user[field] || 0) + value);
  if (next < 0) throw new Error("Недостаточно средств.");
  user[field] = next;
  data.ledger.unshift({ id: uid(), user: id, currency, delta: amount, note, date: Date.now() });
  save();
}

function log(text, who = me().id) {
  if (remoteReady && !window.__scrlTestMode) {
    backend.logSelf(String(text)).catch(error => console.warn("ScRl activity:", error.message));
  }
  const line = { id: uid(), user: who, text, date: Date.now() };
  data.activity.unshift(line);
  data.activity = data.activity.slice(0, 100);
  notify(who, text);
  save();
}

function notificationItems(userId = me().id) {
  return (Array.isArray(data.notices) ? data.notices : [])
    .filter(item => item.user === userId)
    .sort((left, right) => new Date(right.date || right.created_at || 0).getTime() - new Date(left.date || left.created_at || 0).getTime());
}

function updateNotificationBell() {
  const bell = el("notificationBell");
  const count = el("notificationCount");
  const list = el("notificationList");
  if (!bell || !count || !list) return;
  const items = notificationItems();
  const unread = items.filter(item => !item.seen).length;
  count.textContent = unread > 99 ? "99+" : String(unread);
  count.hidden = unread === 0;
  bell.classList.toggle("has-unread", unread > 0);
  bell.setAttribute("aria-label", unread ? "Уведомления. Непрочитанных: " + unread : "Уведомления");
  const summary = el("notificationSummary");
  if (summary) summary.textContent = unread ? unread + " непрочитано" : (items.length ? "Всё прочитано" : "Пока тихо");
  const markAll = el("markAllNotices");
  if (markAll) markAll.disabled = unread === 0;
  const visible = items.slice(0, 6);
  list.innerHTML = visible.length ? visible.map(item => {
    const date = new Date(item.date || item.created_at || Date.now());
    const dateText = Number.isNaN(date.getTime()) ? "" : date.toLocaleString("ru-RU", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });
    return '<button type="button" class="notification-item' + (item.seen ? "" : " is-unread") + '" data-notification-page>' +
      '<span class="notification-dot" aria-hidden="true"></span>' +
      '<span class="notification-copy"><span class="notification-text">' + safe(item.text || "Новое уведомление") + '</span>' +
      '<time>' + safe(dateText) + '</time></span></button>';
  }).join("") : '<p class="notification-empty">Здесь появятся сообщения и события.</p>';
}

function closeNotificationPanel() {
  const panel = el("notificationPanel");
  const bell = el("notificationBell");
  if (panel) panel.hidden = true;
  if (bell) bell.setAttribute("aria-expanded", "false");
}

function notify(id, text) {
  data.notices.unshift({ id: uid(), user: id, text, date: Date.now(), seen: false });
  data.notices = data.notices.slice(0, 100);
  updateNotificationBell();
}

function enterLocal(name, mail, token = "", guest = false, id = "") {
  const userId = guest ? "u0" : (id || "local" + uid());
  let user = getUser(userId);
  if (!user) {
    user = { id: userId, name, mail, role: "student", room: "", scrl: 100, vrub: 0, holdScrl: 0, holdVrub: 0, blocked: false };
    data.ledger.unshift({ id: uid(), user: userId, currency: "ScRl", delta: 100, note: "Стартовый бонус демо", date: Date.now() });
    data.users.push(user);
  }
  if (user.blocked) {
    sessionStorage.removeItem("scrlSession");
    el("logErr").textContent = "Этот аккаунт заблокирован. Обратись к администратору.";
    auth.hidden = false;
    auth.classList.remove("is-closing");
    app.hidden = true;
    return;
  }
  user.name = name || user.name;
  user.mail = mail || user.mail;
  sessionStorage.setItem("scrlSession", JSON.stringify({ id: userId, name: user.name, mail: user.mail, token, guest }));
  save();

  const revealApp = () => {
    auth.hidden = true;
    auth.classList.remove("is-closing");
    auth.removeAttribute("aria-hidden");
    app.hidden = false;
    if (document.body?.classList) document.body.classList.add("app-active");
    el("userName").textContent = user.name;
    el("avatar").textContent = user.name.charAt(0).toUpperCase();
    setPage("home");
    if (!window.__scrlTestMode) {
      app.classList.add("is-entering", "is-ready");
      setTimeout(() => app.classList.remove("is-entering", "is-ready"), 650);
    }
  };

  revealApp();
}

function showBanAppeal() {
  auth.hidden = false;
  app.hidden = true;
  auth.classList.remove("is-closing");
  auth.removeAttribute("aria-hidden");
  if (document.body?.classList) document.body.classList.remove("app-active");
  const book = el("authBook");
  if (book) {
    book.classList.add("is-spread");
    book.dataset.activePage = "3";
  }
  login.hidden = true;
  reg.hidden = true;
  codeForm.hidden = true;
  if (el("banAppealPanel")) el("banAppealPanel").hidden = false;
  if (el("authTitle")) el("authTitle").textContent = "Ограничение доступа";
  if (el("authDesc")) el("authDesc").textContent = "Проверка безопасности ScRl";
  if (el("returnToPage2")) el("returnToPage2").hidden = true;
  if (el("bookSign")) el("bookSign").hidden = true;
  const ban = data.moderation?.activeBan || null;
  const appeal = ban ? (data.moderation?.appeals || []).find(item => item.ban_id === ban.id) : null;
  const info = el("banAppealInfo");
  const status = el("banAppealStatus");
  const form = el("banAppealForm");
  if (info) info.textContent = ban
    ? "Аккаунт временно заблокирован ИИ-модерацией. Причина: " + (ban.reason || "требуется проверка") +
      ". Срок апелляции до " + new Date(ban.appealUntil).toLocaleString("ru-RU") + "."
    : "Аккаунт заблокирован администратором. Обратись к администратору ScRl.";
  if (form) form.hidden = !ban || !ban.canAppeal || Boolean(appeal);
  if (status) status.textContent = appeal
    ? "Апелляция уже отправлена. Ожидай решения администратора."
    : ban && !ban.canAppeal
      ? "Срок подачи апелляции (24 часа) закончился."
      : data.moderation?.unavailable
        ? (data.moderation.error || "Не удалось загрузить данные апелляции.")
        : "";
  updateBookControls();
}

async function enterRemote(name, mail, token, id) {
  resetAdminPreviewRole();
  const session = { id, name: name || "Участник", mail: mail || "", token, guest: false };
  sessionStorage.setItem("scrlSession", JSON.stringify(session));
  remoteReady = false;
  try {
    if (!backend) throw new Error("Не загружен модуль подключения к базе.");
    data = await backend.load(token, id, mail);
    remoteReady = true;

    if (!data.users.some(user => user.role === "admin")) {
      const claimed = await backend.claimInitialAdminForEmail();
      if (claimed === true) {
        data = await backend.load(token, id, mail);
        msg("Подтверждённая почта назначена первым администратором ScRl.");
      }
    }

    const user = getUser(id);
    if (!user) throw new Error("Профиль не найден в общей базе. Повтори вход.");
    session.name = user.name;
    sessionStorage.setItem("scrlSession", JSON.stringify(session));
    if (user.blocked) {
      showBanAppeal();
      return;
    }
    sessionStorage.setItem("scrlSession", JSON.stringify(session));

    const revealApp = () => {
      auth.hidden = true;
      auth.classList.remove("is-closing");
      auth.removeAttribute("aria-hidden");
      app.hidden = false;
      if (document.body?.classList) document.body.classList.add("app-active");
      el("userName").textContent = user.name;
      el("avatar").textContent = user.name.charAt(0).toUpperCase();
      setPage("home");
      if (!window.__scrlTestMode) {
        app.classList.add("is-entering", "is-ready");
        setTimeout(() => app.classList.remove("is-entering", "is-ready"), 650);
      }
    };
    revealApp();
  } catch (error) {
    remoteReady = false;
    sessionStorage.removeItem("scrlSession");
    auth.hidden = false;
    auth.classList.remove("is-closing");
    auth.removeAttribute("aria-hidden");
    app.hidden = true;
    if (document.body?.classList) document.body.classList.remove("app-active");
    const message = error.message || "Не удалось подключиться к общей базе ScRl.";
    if (el("logErr")) el("logErr").textContent = message;
    console.error("ScRl backend login:", error);
  }
}

function enter(name, mail, token = "", guest = false, id = "") {
  if (window.__scrlTestMode) return enterLocal(name, mail, token, guest, id);
  if (guest || !token || !id) {
    sessionStorage.removeItem("scrlSession");
    el("logErr").textContent = "Вход доступен только зарегистрированным пользователям.";
    auth.hidden = false;
    app.hidden = true;
    return;
  }
  return enterRemote(name, mail, token, id);
}

function leave() {
  resetAdminPreviewRole();
  remoteReady = false;
  sessionStorage.removeItem("scrlSession");
  app.hidden = true;
  if (document.body?.classList) document.body.classList.remove("app-active");
  auth.hidden = false;
  login.reset();
  reg.reset();
  codeForm.reset();
  pending = null;
  setMode("login");
}

async function ask(path, body) {
  const url = String(cfg.url || "").replace(/\/$/, "");
  if (!url || !cfg.key) throw new Error("База аккаунтов пока не подключена. Регистрация и вход по email и паролю временно недоступны.");
  const res = await fetch(url + "/auth/v1/" + path, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: cfg.key },
    body: JSON.stringify(body)
  });
  const result = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(result.msg || result.message || result.error_description || "Не получилось выполнить запрос.");
  return result;
}

async function saveProfile(id, name, token, room = null) {
  if (backend) return backend.saveProfile(id, name, room, token);
  const url = String(cfg.url || "").replace(/\/$/, "");
  const profile = { id, full_name: name };
  if (room !== null && room !== undefined) profile.room = room;
  const res = await fetch(url + "/rest/v1/profiles?on_conflict=id", {
    method: "POST",
    headers: { apikey: cfg.key, Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify(profile)
  });
  if (!res.ok) throw new Error("Профиль не сохранился. Попробуй ещё раз.");
}

let remoteRefreshInFlight = null;
async function refreshRemoteData(options = {}) {
  const session = sess();
  if (!remoteReady || !session?.token) return data;
  if (!remoteRefreshInFlight) {
    const pending = backend.load(session.token, session.id, session.mail)
      .then(nextData => {
        const currentSession = sess();
        if (remoteReady && currentSession?.id === session.id) data = nextData;
        return data;
      })
      .finally(() => { if (remoteRefreshInFlight === pending) remoteRefreshInFlight = null; });
    remoteRefreshInFlight = pending;
  }
  const pending = remoteRefreshInFlight;
  if (options.background) {
    pending.then(() => {
      const currentSession = sess();
      if (remoteReady && currentSession?.id === session.id && options.page && !app.hidden) setPage(options.page);
    }).catch(error => console.warn("ScRl background refresh:", error?.message || error));
    return data;
  }
  return pending;
}

function setupAuthDeviceMode() {
  const slider = el("codeDeviceMode");
  if (!slider || window.__scrlTestMode) return;

  const storageKey = "scrlAuthDeviceMode";
  const media = window.matchMedia ? window.matchMedia("(max-width: 760px)") : null;
  let saved = null;
  try {
    saved = localStorage.getItem(storageKey);
  } catch (_) {
    saved = null;
  }
  let manual = saved === "phone" || saved === "laptop";

  const apply = (mode, persist = false) => {
    const next = mode === "laptop" ? "laptop" : "phone";
    if (auth) auth.dataset.deviceMode = next;
    slider.value = next === "laptop" ? "1" : "0";
    if (persist) {
      try {
        localStorage.setItem(storageKey, next);
      } catch (_) {
        // The current selection still works when storage is unavailable.
      }
    }
  };

  apply(manual ? saved : (media && media.matches ? "phone" : "laptop"));
  slider.addEventListener("input", () => {
    manual = true;
    apply(slider.value === "1" ? "laptop" : "phone", true);
  });

  if (media) {
    const syncToScreen = event => {
      if (!manual) apply(event.matches ? "phone" : "laptop");
    };
    if (typeof media.addEventListener === "function") media.addEventListener("change", syncToScreen);
    else if (typeof media.addListener === "function") media.addListener(syncToScreen);
  }
}

function setCodePage() {
  if (el("banAppealPanel")) el("banAppealPanel").hidden = true;
  if (el("returnToPage2")) el("returnToPage2").hidden = false;
  if (el("bookSign")) el("bookSign").hidden = false;
  const book = el("authBook");
  if (book) {
    book.classList.add("is-spread");
    book.dataset.activePage = "3";
  }
  login.hidden = false;
  reg.hidden = true;
  codeForm.hidden = false;
  if (el("loginTab")) el("loginTab").classList.remove("is-active");
  if (el("regTab")) el("regTab").classList.add("is-active");
  const isEmailLogin = pending?.purpose === "email-login";
  el("authTitle").textContent = "Подтвердите почту";
  el("authDesc").textContent = "Код уже отправлен на почту. Введи восемь цифр из письма.";
  el("codeMail").textContent = pending.mail;
  const codeInfo = document.querySelector("#codeForm .code-info");
  if (codeInfo) codeInfo.textContent = "Код уже отправлен на " + pending.mail + ". Открой письмо и введи восемь цифр ниже.";
  updateBookControls();
  el("code").focus();
}

const pages = {
  home: homePage,
  wallet: walletPage,
  finance: financePage,
  assistant: assistantPage,
  board: boardPage,
  exchange: exchangePage,
  auctions: auctionsPage,
  orders: ordersPage,
  activity: activityPage,
  favorites: favoritesPage,
  notices: noticesPage,
  profile: profilePage,
  staff: staffPage,
  admin: adminPage,
  pulse: pulsePage
};

function link(page, text) {
  return '<button class="button button-secondary" data-page="' + page + '">' + text + '</button>';
}

function homePage() {
  const user = me();
  const activeDeals = data.deals.filter(deal =>
    (deal.buyer === user.id || deal.seller === user.id) && ["work", "ready", "dispute"].includes(deal.status)
  ).length;
  const activePosts = data.posts.filter(post => post.user === user.id && post.status === "active").length +
    data.listings.filter(item => item.user === user.id && item.status === "active").length;
  const unread = data.notices.filter(item => item.user === user.id && !item.seen).length;
  const favorites = data.favorites.filter(item => item.user === user.id).length;
  const className = user.room ? "Класс " + safe(user.room) : "Класс не указан";

  return '<p class="eyebrow">ЛИЧНЫЙ КАБИНЕТ</p>' +
    '<h1>Привет, ' + safe(user.name.split(" ")[0]) + '</h1>' +
    '<p class="muted">Твой обзор ScRl · ' + className + ' · ' + roleName(user.role) + '</p>' +
    '<div class="home-overview">' +
      '<article class="home-overview-card"><span class="home-overview-label">МОИ ЗАКАЗЫ</span><strong class="home-overview-value">' + activeDeals + '</strong><p>Активные сделки, подтверждения и споры</p></article>' +
      '<article class="home-overview-card"><span class="home-overview-label">МОИ ПУБЛИКАЦИИ</span><strong class="home-overview-value">' + activePosts + '</strong><p>Действующие запросы и предложения</p></article>' +
      '<article class="home-overview-card"><span class="home-overview-label">УВЕДОМЛЕНИЯ</span><strong class="home-overview-value">' + unread + '</strong><p>Непрочитанные события аккаунта</p></article>' +
      '<article class="home-overview-card"><span class="home-overview-label">ИЗБРАННОЕ</span><strong class="home-overview-value">' + favorites + '</strong><p>Сохранённые объявления и услуги</p></article>' +
    '</div>' +
    '<p class="small muted demo-note">Баланс ScRl и V-RUB доступен прямо в верхней панели. Для перехода между разделами используй навигацию сверху.</p>';
}

function roleName(role) {
  return ({ student: "Ученик", teacher: "Учитель", admin: "Администратор" })[role] || "Ученик";
}

function walletPage() {
  const user = me();
  const rows = data.ledger.filter(row => row.user === user.id).slice(0, 40).map(row =>
    '<div class="data-row"><span>' + safe(row.note) + '<small>' + new Date(row.date).toLocaleString("ru-RU") + '</small></span><b class="' + (row.delta >= 0 ? "plus" : "minus") + '">' +
    (row.delta > 0 ? "+" : "") + money(row.delta) + ' ' + safe(row.currency) + '</b></div>'
  ).join("");
  return '<p class="eyebrow">ЛИЧНЫЕ ФИНАНСЫ</p><h1>Кошелёк</h1>' +
    '<div class="demo-stats"><div class="demo-stat"><span>Доступно ScRl</span><b>' + money(user.scrl) + '</b><small>В резерве: ' + money(user.holdScrl) + '</small></div>' +
    '<div class="demo-stat"><span>V-RUB</span><b>' + money(user.vrub) + '</b><small>В резерве: ' + money(user.holdVrub) + '</small></div></div>' +
    '<h2>История операций</h2><div class="data-list">' + (rows || '<p class="muted">Операций пока нет.</p>') + '</div>' +
    '<p class="small muted demo-note">ScRl и V-RUB здесь — только учебные единицы. Настоящие платежи и вывод денег не подключены.</p>';
}

function boardPage() {
  const rows = data.posts.filter(post =>
    (post.status === "active" || (post.user === me().id && ["review", "hidden"].includes(post.status))) &&
    !getUser(post.user)?.blocked
  )
    .filter(post => filter.type === "all" || post.type === filter.type)
    .filter(post => (post.title + " " + post.desc + " " + post.category).toLowerCase().includes(filter.term.toLowerCase()))
    .map(post => {
      const fav = isFav("post", post.id);
      const moderationTag = post.status === "review"
        ? '<span class="tag moderation-state">На проверке</span>'
        : post.status === "hidden"
          ? '<span class="tag moderation-state">Скрыта модерацией</span>'
          : '';
      return '<article class="demo-card"><div class="card-top"><span class="tag">' + (post.type === "need" ? "Мне нужно" : "Я могу") + '</span>' + moderationTag + '<span class="muted small">' + safe(userName(post.user)) + ' · ' + safe(post.category) + '</span></div>' +
        '<h2>' + safe(post.title) + '</h2><p class="muted">' + safe(post.desc) + '</p><div class="card-bottom"><b>' + (post.price ? money(post.price) + ' ScRl' : 'Бесплатно') + '</b>' +
        '<span class="actions"><button class="text-button" data-do="fav" data-kind="post" data-id="' + post.id + '">' + (fav ? "★ В избранном" : "☆ Избранное") + '</button>' +
        (post.user === me().id ? '<button class="text-button" data-do="remove-post" data-id="' + post.id + '">Закрыть</button>' :
          '<details><summary class="text-button">Пожаловаться</summary><form class="msg-form" data-form="report" data-kind="post" data-id="' + post.id + '"><select name="reason"><option value="spam">Спам или обман</option><option value="unsafe">Опасное предложение</option><option value="privacy">Личные данные</option><option value="harassment">Оскорбления</option><option value="other">Другое</option></select><input name="details" maxlength="180" placeholder="Подробности (необязательно)"><button class="button button-secondary" type="submit">Отправить</button></form></details>' +
          '<button class="text-button" data-do="reply" data-id="' + post.id + '">Откликнуться</button>') + '</span></div></article>';
    }).join("");
  const cats = data.posts.filter(p => p.user === me().id && p.type === "need").map(p => p.category);
  const matches = data.posts.filter(p => p.user !== me().id && p.type === "offer" && p.status === "active" && !getUser(p.user)?.blocked && cats.includes(p.category)).sort((a,b) => a.price-b.price).slice(0,3);
  const hints = matches.map(p => '<div class="data-row"><span><b>' + safe(p.title) + '</b><small>' + safe(userName(p.user)) + ' · ' + safe(p.category) + '</small></span><b>' + (p.price ? money(p.price) + ' ScRl' : 'Бесплатно') + '</b></div>').join("");
  return '<p class="eyebrow">ВЗАИМОПОМОЩЬ</p><h1>Доска</h1><p class="muted">Запросы и предложения учеников.</p>' +
    '<section class="match-box"><h2>Подходящие предложения</h2>' + (hints || '<p class="muted small">Создай запрос — здесь появятся предложения по такой же теме.</p>') + '</section>' +
    '<form id="boardFilter" class="filter-row"><input name="term" id="boardTerm" value="' + safe(filter.term) + '" placeholder="Поиск по публикациям">' +
    '<select name="type"><option value="all"' + (filter.type === "all" ? " selected" : "") + '>Все</option><option value="need"' + (filter.type === "need" ? " selected" : "") + '>Мне нужно</option><option value="offer"' + (filter.type === "offer" ? " selected" : "") + '>Я могу</option></select>' +
    '<button class="button button-secondary" type="submit">Найти</button></form>' +
    '<form id="boardForm" class="demo-form"><h2>Новая публикация</h2><label>Тип</label><select name="type"><option value="need">Мне нужно</option><option value="offer">Я могу</option></select>' +
    '<label>Тема</label><select name="category"><option>Учёба</option><option>Математика</option><option>Языки</option><option>Дизайн</option><option>Творчество</option><option>Другое</option></select>' +
    '<label>Заголовок</label><input name="title" maxlength="80" required><label>Описание</label><textarea name="desc" rows="3" maxlength="300" required></textarea>' +
    '<label>Цена в ScRl (0 — бесплатно)</label><input name="price" type="number" min="0" max="500" value="0" required><button class="button button-primary" type="submit">Опубликовать</button></form>' +
    '<div class="demo-list-title"><h2>Публикации</h2><span class="muted small">' + rows.length + ' записей</span></div>' +
    '<div class="demo-list">' + (rows || '<p class="muted">По этому запросу ничего нет.</p>') + '</div>';
}

function marketPage() {
  const categories = [...new Set(data.listings.filter(item => item.status === "active").map(item => item.category))].sort();
  const items = data.listings.filter(item => item.status === "active" && !getUser(item.user)?.blocked)
    .filter(item => marketFilter.category === "all" || item.category === marketFilter.category)
    .filter(item => (item.title + " " + item.desc + " " + item.category).toLowerCase().includes(marketFilter.term.toLowerCase()))
    .sort((a,b) => marketFilter.sort === "cheap" ? a.price-b.price : marketFilter.sort === "expensive" ? b.price-a.price : b.date-a.date);
  const rows = items.map(item =>
    '<article class="demo-card"><div class="card-top"><span class="tag">Услуга</span><span class="muted small">' + safe(userName(item.user)) + ' · ' + safe(item.category) + '</span></div>' +
    '<h2>' + safe(item.title) + '</h2><p class="muted">' + safe(item.desc) + '</p><div class="card-bottom"><b>' + money(item.price) + ' ScRl · Осталось: ' + item.slots + '</b>' +
    '<span class="actions"><button class="text-button" data-do="fav" data-kind="listing" data-id="' + item.id + '">' + (isFav("listing", item.id) ? "★" : "☆") + ' Избранное</button>' +
    (item.user === me().id ? '<button class="text-button" data-do="remove-listing" data-id="' + item.id + '">Снять</button>' :
      '<details><summary class="text-button">Пожаловаться</summary><form class="msg-form" data-form="report" data-kind="listing" data-id="' + item.id + '"><select name="reason"><option value="spam">Спам или обман</option><option value="unsafe">Опасная услуга</option><option value="privacy">Личные данные</option><option value="harassment">Оскорбления</option><option value="other">Другое</option></select><input name="details" maxlength="180" placeholder="Подробности (необязательно)"><button class="button button-secondary" type="submit">Отправить</button></form></details>' +
      '<button class="text-button" data-do="buy" data-id="' + item.id + '">Заказать</button>') + '</span></div></article>'
  ).join("");
  return '<p class="eyebrow">УСЛУГИ УЧЕНИКОВ</p><h1>Маркет</h1><p class="muted">Услуги и заказы с резервом ScRl до подтверждения.</p>' +
    '<form id="marketFilter" class="filter-row"><input name="term" value="' + safe(marketFilter.term) + '" placeholder="Поиск по услугам"><select name="category"><option value="all">Все категории</option>' +
    categories.map(cat => '<option value="' + safe(cat) + '"' + (marketFilter.category === cat ? " selected" : "") + '>' + safe(cat) + '</option>').join("") + '</select>' +
    '<select name="sort"><option value="new"' + (marketFilter.sort === "new" ? " selected" : "") + '>Сначала новые</option><option value="cheap"' + (marketFilter.sort === "cheap" ? " selected" : "") + '>Сначала дешевле</option><option value="expensive"' + (marketFilter.sort === "expensive" ? " selected" : "") + '>Сначала дороже</option></select><button class="button button-secondary" type="submit">Применить</button></form>' +
    '<form id="marketForm" class="demo-form"><h2>Добавить услугу</h2><label>Название</label><input name="title" maxlength="80" required>' +
    '<label>Описание</label><textarea name="desc" rows="3" maxlength="300" required></textarea><label>Категория</label><select name="category"><option>Учёба</option><option>Дизайн</option><option>Творчество</option><option>Языки</option><option>Другое</option></select>' +
    '<label>Цена в ScRl</label><input name="price" type="number" min="1" max="500" value="20" required><label>Количество заказов</label><input name="slots" type="number" min="1" max="10" value="1" required>' +
    '<button class="button button-primary" type="submit">Опубликовать</button></form><div class="demo-list-title"><h2>Услуги</h2><span class="muted small">' + items.length + ' найдено</span></div>' +
    '<div class="demo-list">' + (rows || '<p class="muted">Услуг по этим условиям нет.</p>') + '</div>';
}


function currentRate() {
  return core.vwap(data.trades, Date.now() - 7 * 86400000, data.rate);
}

function exchangePage() {
  refreshFee();
  const scrlOffers = data.exchangeOrders.filter(o => o.status === "active" && o.side === "scrlSell" && !getUser(o.user)?.blocked);
  const vrubOffers = data.exchangeOrders.filter(o => o.status === "active" && o.side === "vrubSell" && !getUser(o.user)?.blocked);
  const own = data.exchangeOrders.filter(o => o.user === me().id).slice(0,20).map(o =>
    '<div class="data-row"><span>' + (o.side === "scrlSell" ? 'Продажа ScRl' : 'Продажа V-RUB') + ' · ' + money(o.amount) + '<small>' + rateMoney(o.price) + (o.side === "scrlSell" ? ' V-RUB за ScRl' : ' ScRl за V-RUB') + ' · ' + safe(o.status) + '</small></span>' +
    (o.status === "active" ? '<button class="text-button" data-do="canceloffer" data-id="' + o.id + '">Отменить</button>' : '') + '</div>'
  ).join("");
  const scrlRows = scrlOffers.map(o =>
    '<article class="demo-card"><div class="card-top"><span class="tag">Продажа ScRl</span><span class="muted small">' + safe(userName(o.user)) + '</span></div>' +
    '<h2>' + money(o.amount) + ' ScRl</h2><p class="muted">' + rateMoney(o.price) + ' V-RUB за 1 ScRl · всего ' + money(o.amount * o.price) + ' V-RUB</p>' +
    (o.user !== me().id ? '<button class="button button-primary" data-do="buyoffer" data-id="' + o.id + '">Купить ScRl</button>' : '<span class="small muted">Твоё предложение</span>') + '</article>'
  ).join("");
  const vrubRows = vrubOffers.map(o =>
    '<article class="demo-card"><div class="card-top"><span class="tag">Продажа V-RUB</span><span class="muted small">' + safe(userName(o.user)) + '</span></div>' +
    '<h2>' + money(o.amount) + ' V-RUB</h2><p class="muted">' + rateMoney(o.price) + ' ScRl за 1 V-RUB · всего ' + money(o.amount * o.price) + ' ScRl</p>' +
    (o.user !== me().id ? '<button class="button button-primary" data-do="buyoffer" data-id="' + o.id + '">Купить V-RUB</button>' : '<span class="small muted">Твоё предложение</span>') + '</article>'
  ).join("");
  const myTrades = data.trades.filter(t => t.buyer === me().id || t.seller === me().id).slice(0,15).map(t =>
    '<div class="data-row"><span>' + money(t.amountScRl || t.qty) + ' ScRl · ' + money(t.amountVrub || t.qty * t.price) + ' V-RUB<small>' + new Date(t.date).toLocaleString("ru-RU") + ' · ' + (t.buyer === me().id ? 'Ты купил у ' + safe(userName(t.seller)) : 'У тебя купил ' + safe(userName(t.buyer))) + '</small></span><b>' + money(t.fee) + ' ScRl комиссии</b></div>'
  ).join("");
  const cover = refreshFee();
  return '<p class="eyebrow">ОБМЕН</p><h1>Биржа</h1><p class="muted">Два направления: ScRl за V-RUB и V-RUB за ScRl.</p>' +
    '<div class="demo-stats"><div class="demo-stat"><span>Твой ScRl</span><b>' + money(me().scrl) + '</b><small>В резерве: ' + money(me().holdScrl) + '</small></div><div class="demo-stat"><span>Твой V-RUB</span><b>' + money(me().vrub) + '</b><small>В резерве: ' + money(me().holdVrub) + '</small></div></div>' +
    '<section class="match-box"><h2>Курс и комиссия</h2><p>1 ScRl = ' + rateMoney(currentRate()) + ' V-RUB</p><p class="small muted">Целевой курс: ' + rateMoney(data.rate) + ' · Комиссия по покрытию: ' + money(data.fee * 100) + '% · Покрытие: ' + money(cover.ratio * 100) + '%</p></section>' +
    '<div class="demo-columns"><form id="sellScrlForm" class="demo-form"><h2>Продать ScRl</h2><label>Количество ScRl</label><input name="amount" type="number" min="1" max="1000000" step="1" required><label>Цена за 1 ScRl, V-RUB</label><input name="price" type="number" min="0.0001" max="10000" step="0.0001" value="' + data.rate + '" required><button class="button button-primary" type="submit">Выставить ScRl</button></form>' +
    '<form id="sellVrubForm" class="demo-form"><h2>Продать V-RUB</h2><label>Количество V-RUB</label><input name="amount" type="number" min="1" max="1000000" step="1" required><label>Цена за 1 V-RUB, ScRl</label><input name="price" type="number" min="0.0001" max="10000" step="0.0001" value="' + (1 / data.rate).toFixed(4) + '" required><button class="button button-primary" type="submit">Выставить V-RUB</button></form></div>' +
    '<h2>Покупают ScRl за V-RUB</h2><div class="demo-list">' + (scrlRows || '<p class="muted">Предложений пока нет.</p>') + '</div>' +
    '<h2>Покупают V-RUB за ScRl</h2><div class="demo-list">' + (vrubRows || '<p class="muted">Предложений пока нет.</p>') + '</div>' +
    '<h2>Мои предложения</h2><div class="data-list">' + (own || '<p class="muted">Ты пока ничего не выставлял.</p>') + '</div>' +
    '<h2>Мои сделки на бирже</h2><div class="data-list">' + (myTrades || '<p class="muted">Сделок пока нет.</p>') + '</div>' +
    '<p class="small muted demo-note">ScRl и V-RUB — только учебные единицы. Это не реальные деньги.</p>';
}


function auctionsPage() {
  const user = me();
  const canCreate = user.role === "teacher" || user.role === "admin";
  const canBid = user.role === "student";
  const active = data.auctions.filter(a => ["active","settlementError"].includes(a.status)).sort((a,b) => a.ends-b.ends);
  const rows = active.map(a => {
    const leader = a.leader ? userName(a.leader) : "Нет лидера";
    const minNext = a.bid > 0 ? a.bid + a.step : a.startPrice;
    const mayFinish = (user.role === "admin" || (user.role === "teacher" && a.owner === user.id)) && ["active","settlementError"].includes(a.status);
    const history = data.bids.filter(b => b.auction === a.id).sort((x,y) => y.date-x.date).slice(0,5)
      .map(b => '<div class="data-row"><span>' + safe(userName(b.user)) + '<small>' + new Date(b.date).toLocaleString("ru-RU") + ' · ' + safe(b.status) + '</small></span><b>' + money(b.amount) + ' ScRl</b></div>').join("");
    const ended = Date.now() >= a.ends;
    return '<article class="demo-card"><div class="card-top"><span class="tag">' + (a.status === "settlementError" ? "Ошибка расчёта" : ended ? "Время вышло" : "Идёт") + '</span><span class="muted small">До ' + new Date(a.ends).toLocaleString("ru-RU") + '</span></div>' +
      '<h2>' + safe(a.title) + '</h2><p class="muted">Неденежный приз: ' + safe(a.prize) + '</p><div class="card-bottom"><span>Ставка: <b>' + money(a.bid) + ' ScRl</b><small class="muted"> · лидер: ' + safe(leader) + '</small></span>' +
      '<span class="actions">' +
      (canBid && !ended && a.status === "active" && a.owner !== user.id ? '<form class="msg-form" data-form="auctionBid" data-id="' + a.id + '"><input name="amount" type="number" min="' + minNext + '" step="1" placeholder="От ' + minNext + '" required><button class="button button-primary" type="submit">Сделать ставку</button></form>' : '') +
      (mayFinish ? '<button class="text-button" data-do="endauction" data-id="' + a.id + '">' + (a.status === "settlementError" ? "Повторить расчёт" : "Завершить сейчас") + '</button>' : '') +
       +
      '</span></div><details><summary class="text-button">История ставок</summary><div class="data-list">' + (history || '<p class="muted small">Ставок пока нет.</p>') + '</div></details>' +
      (a.settlementError ? '<p class="small muted">' + safe(a.settlementError) + '</p>' : '') + '</article>';
  }).join("");
  const finished = data.auctions.filter(a => a.status === "done").sort((a,b) => (b.closed || 0) - (a.closed || 0)).slice(0,10).map(a =>
    '<div class="data-row"><span><b>' + safe(a.title) + '</b><small>Победитель: ' + safe(a.leader ? userName(a.leader) : "Нет ставок") + ' · ' + safe(a.prize) + '</small></span><b>' + money(a.bid) + ' ScRl</b></div>'
  ).join("");
  const create = canCreate
    ? '<form id="auctionForm" class="demo-form"><h2>Создать аукцион</h2><label>Название</label><input name="title" maxlength="100" required><label>Неденежный приз</label><input name="prize" maxlength="100" required>' +
      '<label>Стартовая цена, ScRl</label><input name="start" type="number" min="1" max="1000000" step="1" value="10" required><label>Шаг ставки</label><input name="step" type="number" min="1" max="1000000" step="1" value="5" required>' +
      '<label>Длительность, минут</label><input name="minutes" type="number" min="1" max="10080" step="1" value="1440" required><button class="button button-primary" type="submit">Создать аукцион</button></form>'
    : '';
  return '<p class="eyebrow">СОБЫТИЯ</p><h1>Аукционы</h1><p class="muted">Создавать аукционы могут учителя и администраторы. Ставки временно удерживаются, а после завершения списываются.</p>' +
    create + '<h2>Активные</h2><div class="demo-list">' + (rows || '<p class="muted">Активных аукционов нет.</p>') + '</div>' +
    '<h2>Завершённые</h2><div class="data-list">' + (finished || '<p class="muted">Завершённых аукционов пока нет.</p>') + '</div>';
}


function ordersPage() {
  const mine = data.deals.filter(d => d.buyer === me().id || d.seller === me().id);
  const rows = mine.map(d => {
    const controls = d.status === "work"
      ? (d.seller === me().id ? '<button class="text-button" data-do="delivered" data-id="' + d.id + '">Отметить выполненным</button>' : '') +
        '<button class="text-button" data-do="dispute" data-id="' + d.id + '">Открыть спор</button>'
      : d.status === "ready" && d.buyer === me().id
        ? '<button class="text-button" data-do="confirm" data-id="' + d.id + '">Подтвердить</button><button class="text-button" data-do="dispute" data-id="' + d.id + '">Спор</button>'
        : d.status === "ready" && d.seller === me().id ? '<button class="text-button" data-do="dispute" data-id="' + d.id + '">Открыть спор</button>' : '';
    const messages = (d.messages || []).map(m => '<div class="chat-line"><b>' + safe(userName(m.user)) + '</b><span>' + safe(m.text) + '</span><small>' + (m.status && m.status !== "active" ? "На проверке ИИ · " : "") + new Date(m.date).toLocaleString("ru-RU") + '</small></div>').join("");
    return '<article class="demo-card"><div class="card-top"><span class="tag">' + statusName(d.status) + '</span><span class="muted small">№ ' + safe(d.id.slice(-6)) + '</span></div><h2>' + safe(d.title) + '</h2>' +
      '<p class="muted">Покупатель: ' + safe(userName(d.buyer)) + ' · Исполнитель: ' + safe(userName(d.seller)) + '</p><div class="card-bottom"><b>' + money(d.amount) + ' ScRl' + (d.amount ? ' в резерве: ' + money(d.escrow) : '') + '</b><span class="actions">' + controls + '</span></div>' +
      '<div class="chat-box">' + (messages || '<p class="muted small">Сообщений пока нет.</p>') + '</div>' +
      '<form class="msg-form" data-form="message" data-id="' + d.id + '"><input name="text" maxlength="240" placeholder="Написать сообщение" required><button class="button button-secondary" type="submit">Отправить</button></form>' +
      (d.status === "done" && !data.reviews.some(r => r.deal === d.id && r.user === me().id) ? '<form class="msg-form" data-form="review" data-id="' + d.id + '"><select name="rating"><option value="5">5 — Отлично</option><option value="4">4 — Хорошо</option><option value="3">3 — Нормально</option><option value="2">2</option><option value="1">1</option></select><input name="text" maxlength="180" placeholder="Отзыв (необязательно)"><button class="button button-secondary" type="submit">Оставить отзыв</button></form>' : '') +
      '</article>';
  }).join("");
  return '<p class="eyebrow">СДЕЛКИ</p><h1>Мои заказы</h1><p class="muted">Здесь можно переписываться, отмечать выполнение и подтверждать оплату.</p>' +
    '<div class="demo-stats"><div class="demo-stat"><span>Активные</span><b>' + mine.filter(d => ["work","ready","dispute"].includes(d.status)).length + '</b></div><div class="demo-stat"><span>Завершённые</span><b>' + mine.filter(d => d.status === "done").length + '</b></div></div>' +
    '<div class="demo-list">' + (rows || '<p class="muted">Пока нет заказов. Можно откликнуться на публикацию или заказать услугу.</p>') + '</div>';
}

function statusName(status) {
  return ({ work: "В работе", ready: "Ждёт подтверждения", dispute: "Спор", done: "Завершён", refund: "Возврат" })[status] || status;
}

function activityPage() {
  const rows = data.activity.filter(a => a.user === me().id).map(a =>
    '<div class="data-row"><span>' + safe(a.text) + '<small>' + new Date(a.date).toLocaleString("ru-RU") + '</small></span></div>'
  ).join("");
  return '<p class="eyebrow">ТВОИ ДЕЙСТВИЯ</p><h1>Активность</h1><div class="data-list">' + (rows || '<p class="muted">История пока пустая.</p>') + '</div>';
}

function isFav(kind, id) {
  return data.favorites.some(f => f.user === me().id && f.kind === kind && f.id === id);
}

function favoritesPage() {
  const favs = data.favorites.filter(f => f.user === me().id).map(f => {
    const item = f.kind === "post" ? data.posts.find(p => p.id === f.id && p.status === "active") : data.listings.find(p => p.id === f.id && p.status === "active");
    if (!item || getUser(item.user)?.blocked) return "";
    return '<article class="demo-card"><div class="card-top"><span class="tag">' + (f.kind === "post" ? "Публикация" : "Услуга") + '</span><button class="text-button" data-do="fav" data-kind="' + f.kind + '" data-id="' + f.id + '">Убрать</button></div><h2>' + safe(item.title) + '</h2><p class="muted">' + safe(item.desc) + '</p></article>';
  }).join("");
  return '<p class="eyebrow">СОХРАНЁННОЕ</p><h1>Избранное</h1><div class="demo-list">' + (favs || '<p class="muted">Ты пока ничего не сохранил.</p>') + '</div>';
}

function noticesPage() {
  const rows = data.notices.filter(n => n.user === me().id).map(n =>
    '<div class="data-row"><span>' + safe(n.text) + '<small>' + new Date(n.date).toLocaleString("ru-RU") + '</small></span><b>' + (n.seen ? "Прочитано" : "Новое") + '</b></div>'
  ).join("");
  return '<p class="eyebrow">УВЕДОМЛЕНИЯ</p><h1>Уведомления</h1><div class="demo-list">' + (rows || '<p class="muted">Новых уведомлений нет.</p>') + '</div><button class="button button-secondary" data-do="readall">Отметить всё прочитанным</button>';
}

function profilePage() {
  const user = me();
  const reviews = data.reviews.filter(r => r.target === user.id && (r.status || "active") === "active");
  const avg = reviews.length ? (reviews.reduce((sum,r) => sum + r.rating, 0) / reviews.length).toFixed(1) : "—";
  const roleChoice = sess()?.guest
    ? '<label>Демо-роль</label><select name="role"><option value="student"' + (user.role === "student" ? " selected" : "") + '>Ученик</option><option value="teacher"' + (user.role === "teacher" ? " selected" : "") + '>Учитель</option><option value="admin"' + (user.role === "admin" ? " selected" : "") + '>Администратор</option></select><p class="small muted">Только просмотр разных экранов. Настоящую роль выдаёт администратор.</p>'
    : isAdminAccount()
      ? '<label for="profileRole">Режим просмотра</label><select id="profileRole" name="role"><option value="admin"' + (user.role === "admin" ? " selected" : "") + '>Администратор</option><option value="student"' + (user.role === "student" ? " selected" : "") + '>Ученик</option><option value="teacher"' + (user.role === "teacher" ? " selected" : "") + '>Учитель</option></select><p class="small muted">Это только переключение интерфейса. Настоящая роль в базе остаётся «Администратор». При новом входе режим сбрасывается.</p>'
      : '<p class="small muted">Роль: ' + roleName(user.role) + '. Изменить её может только администратор.</p>';
  const deleteSection = remoteReady && !sess()?.guest
    ? '<section class="account-danger"><h2>Удаление аккаунта</h2><p>Действие необратимо. Профиль будет обезличен; твои публикации и сообщения удалены, а финансовая история сохранена без личных данных. Остатки ScRl и V-RUB после удаления недоступны. Перед удалением заверши активные сделки, заявки на бирже, аукционы и освободи все резервы.</p><form id="deleteAccountForm" class="demo-form account-delete-form"><label for="deleteAccountConfirm">Введи слово УДАЛИТЬ для подтверждения</label><input id="deleteAccountConfirm" name="confirmation" maxlength="7" autocomplete="off" required><button class="button button-danger" type="submit">Удалить аккаунт окончательно</button></form></section>'
    : '<section class="account-danger"><h2>Удаление аккаунта</h2><p>Удаление доступно только после входа в зарегистрированный аккаунт. В демо-режиме действие отключено.</p></section>';
  return '<p class="eyebrow">АККАУНТ</p><h1>Профиль</h1><div class="demo-stats"><div class="demo-stat"><span>Отзывы</span><b>' + reviews.length + '</b></div><div class="demo-stat"><span>Средняя оценка</span><b>' + avg + '</b></div></div>' +
    '<form id="profileForm" class="demo-form"><h2>Мои данные</h2><label>ФИО</label><input name="name" maxlength="100" value="' + safe(user.name) + '" required><label>Email</label><input value="' + safe(user.mail || "Email скрыт для других участников") + '" disabled><label>Класс</label><input name="room" maxlength="12" value="' + safe(user.room || "") + '"' + (user.role === "teacher" && !isAdminAccount() ? ' disabled title="Класс меняет администратор"' : "") + '>' +
    roleChoice + '<button class="button button-primary" type="submit">Сохранить</button></form>' +
    deleteSection +
    '<h2>Мои отзывы</h2><div class="data-list">' + (reviews.map(r => '<div class="data-row"><span>' + safe(r.text || "Без текста") + '<small>' + r.rating + ' из 5 · ' + safe(userName(r.user)) + '</small></span></div>').join("") || '<p class="muted">Отзывов пока нет.</p>') + '</div>';
}


function weekKey() {
  const d = new Date();
  const start = new Date(d);
  start.setDate(d.getDate() - ((d.getDay() + 6) % 7));
  return start.toISOString().slice(0, 10);
}

function financePage() {
  if (me().role !== "admin") return '<h1>Нет доступа</h1>';
  const rows = (data.moneyOps || []).slice(0,30).map(op =>
    '<div class="data-row"><span>' + safe(op.kind) + '<small>' + new Date(op.date).toLocaleString("ru-RU") + ' · ' + safe(op.status) + '</small></span><b>' + money(op.amount) + ' RUB</b></div>'
  ).join("");
  return '<p class="eyebrow">ФИНАНСОВЫЕ ОПЕРАЦИИ</p><h1>Платежи</h1>' +
    '<div class="demo-stats"><div class="demo-stat"><span>Платёжный модуль</span><b>Отключён</b></div><div class="demo-stat"><span>Операции</span><b>' + (data.moneyOps || []).length + '</b></div></div>' +
    '<p class="muted">Настоящие пополнения и выводы не выполняются. Для них нужны школьное разрешение, договор и серверная интеграция с платёжным партнёром. Здесь нельзя отправить реальные деньги.</p>' +
    '<h2>Журнал операций</h2><div class="data-list">' + (rows || '<p class="muted">Операций пока нет.</p>') + '</div>';
}

function answerAdminQuestion(message) {
  const q = String(message || "").toLowerCase();
  const reports = data.reports.filter(r => r.status === "open");
  const deals = data.deals;
  const cover = refreshFee();
  const needs = data.posts.filter(p => p.status === "active" && p.type === "need");
  const offers = data.posts.filter(p => p.status === "active" && p.type === "offer");
  const risky = data.posts.filter(p => p.status === "review").length + data.listings.filter(p => p.status === "review").length;
  if (q.includes("эконом") || q.includes("курс") || q.includes("покрыт")) {
    return "Экономика ScRl\n\nВ обращении и резерве: " + money(cover.tokens) + " ScRl\nV-RUB: " + money(cover.vrub) + "\nОбеспеченный лимит: " + money(cover.limit) + " ScRl\nПокрытие: " + money(cover.ratio * 100) + "%\nТекущий курс: " + rateMoney(currentRate()) + " V-RUB\nЦелевой курс: " + rateMoney(data.rate) + " V-RUB\nКомиссия: " + money(data.fee * 100) + "%\nСожжено: " + money(data.burned) + " ScRl.";
  }
  if (q.includes("риск") || q.includes("публикац") || q.includes("провер")) {
    const missing = [...new Set(needs.map(p => p.category))].filter(cat => !offers.some(p => p.category === cat));
    return "Проверка публикаций\n\nНа ручной проверке: " + risky + "\nОткрытых жалоб и споров: " + reports.length + "\nЗаблокировано участников: " + data.users.filter(u => u.blocked).length + "\nКатегории без предложений: " + (missing.join(", ") || "нет") + ".\n\nПравила могут только отправить запись на проверку. Скрывать публикации и решать споры должен человек.";
  }
  if (q.includes("жалоб") || q.includes("спор")) {
    return "Очередь модерации\n\nВсего открыто: " + reports.length + "\nЖалобы на доску: " + reports.filter(r => r.kind === "post").length + "\nЖалобы на услуги: " + reports.filter(r => r.kind === "listing").length + "\nСпоры по сделкам: " + reports.filter(r => r.kind === "deal").length + "\n\nОткрой раздел «Администрирование», чтобы принять решение.";
  }
  if (q.includes("взаимопом") || q.includes("отчёт") || q.includes("отчет") || q.includes("пульс")) {
    const done = deals.filter(d => d.status === "done");
    return "Взаимопомощь\n\nЗавершено сделок: " + done.length + "\nБесплатных: " + done.filter(d => !d.amount).length + "\nАктивных запросов: " + needs.length + "\nАктивных предложений: " + offers.length + "\nОткрытых споров: " + deals.filter(d => d.status === "dispute").length + "\n\nПодробная статистика есть в разделе «Пульс лицея».";
  }
  return "Я могу подготовить сводку по экономике, проверить очередь публикаций, посчитать жалобы и споры или собрать отчёт по взаимопомощи.\n\nПопробуй запрос: «Составь отчёт по экономике» или «Сколько открытых жалоб и споров?»";
}

function assistantTaskFor(message) {
  const q = String(message || "").toLowerCase();
  if (q.includes("эконом") || q.includes("курс") || q.includes("покрыт")) return "economy_report";
  if (q.includes("риск") || q.includes("публикац") || q.includes("провер")) return "moderation_overview";
  if (q.includes("жалоб") || q.includes("спор")) return "moderation_queue";
  if (q.includes("взаимопом") || q.includes("отчёт") || q.includes("отчет") || q.includes("пульс")) return "help_metrics";
  return "";
}

function assistantMetrics() {
  const cover = refreshFee();
  return {
    participants: data.users.length,
    activeParticipants: data.users.filter(user => !user.blocked).length,
    blockedParticipants: data.users.filter(user => user.blocked).length,
    openReports: data.reports.filter(report => report.status === "open").length,
    postsReview: data.posts.filter(post => post.status === "review").length,
    listingsReview: data.listings.filter(listing => listing.status === "review").length,
    activeRequests: data.posts.filter(post => post.status === "active" && post.type === "need").length,
    activeOffers: data.posts.filter(post => post.status === "active" && post.type === "offer").length,
    activeDeals: data.deals.filter(deal => ["work", "ready", "dispute"].includes(deal.status)).length,
    openDisputes: data.deals.filter(deal => deal.status === "dispute").length,
    completedDeals: data.deals.filter(deal => deal.status === "done").length,
    scRlTotal: cover.tokens,
    vRubTotal: cover.vrub,
    coverageRatio: cover.ratio,
    targetRate: Number(data.rate || 0),
    currentRate: Number(currentRate() || 0),
    feeRate: Number(data.fee || 0),
    burnedScRl: Number(data.burned || 0)
  };
}

function askAssistant(message) {
  if (me().role !== "admin") throw new Error("Нет доступа.");
  const text = String(message || "").trim().slice(0, 1000);
  if (!text) throw new Error("Напиши вопрос помощнику.");
  const requesterId = me().id;
  data.aiMessages.push({ id: uid(), user: requesterId, role: "user", text, date: Date.now() });
  const reply = { id: uid(), user: requesterId, role: "assistant", text: answerAdminQuestion(text), date: Date.now(), provider: "локально" };
  data.aiMessages.push(reply);
  data.aiMessages = data.aiMessages.slice(-60);
  save();

  // Only a fixed task identifier and aggregate numeric metrics leave the browser.
  // The administrator's free-form question and individual student records are never sent.
  const task = assistantTaskFor(text);
  if (remoteReady && !window.__scrlTestMode && task) {
    backend.aiAssist(task, assistantMetrics()).then(result => {
      if (sess()?.id !== requesterId || me()?.role !== "admin") return;
      const answer = String(result?.answer || "").trim();
      if (!answer) throw new Error("Внешняя модель вернула пустой ответ.");
      reply.text = answer + "\n\nАнализ использовал только агрегированные числовые показатели.";
      reply.provider = String(result.model || "внешний ИИ").slice(0, 60);
      reply.date = Date.now();
      setPage("assistant");
    }).catch(error => {
      if (sess()?.id !== requesterId || me()?.role !== "admin") return;
      reply.text += "\n\nВнешний ИИ не ответил. Оставлен локальный отчёт.";
      reply.provider = "локальный резерв";
      reply.date = Date.now();
      console.warn("ScRl external AI:", error?.message || error);
      setPage("assistant");
    });
  }
}

function assistantPage() {
  if (me().role !== "admin") return '<h1>Нет доступа</h1>';
  const history = data.aiMessages.filter(m => m.user === me().id).slice(-30).map(m =>
    '<article class="demo-card"><div class="card-top"><span class="tag">' + (m.role === "user" ? "Ты" : "ScRl Assistant · " + safe(m.provider || "локально")) + '</span><span class="muted small">' + new Date(m.date).toLocaleString("ru-RU") + '</span></div><p class="assistant-text">' + safe(m.text) + '</p></article>'
  ).join("");
  return '<p class="eyebrow">ПОМОЩНИК АДМИНИСТРАТОРА</p><h1>AI Moderator</h1>' +
    '<section class="match-box"><h2>Внешняя модель с локальным резервом</h2><p class="muted">При подключении API помощник получает только фиксированный тип отчёта и обезличенные числовые показатели. Текст вопросов, ФИО, email и публикации учащихся не отправляются внешнему провайдеру. ИИ даёт рекомендации; решения о блокировках и скрытии публикаций остаются за человеком.</p></section>' +
    '<form class="demo-form" data-form="assistant"><label>Сообщение помощнику</label><textarea name="message" rows="3" maxlength="1000" placeholder="Например: составь отчёт по экономике" required></textarea><button class="button button-primary" type="submit">Отправить</button></form>' +
    '<div class="demo-links"><button class="button button-secondary" data-do="assistantAsk" data-question="Составь отчёт по экономике">Отчёт по экономике</button><button class="button button-secondary" data-do="assistantAsk" data-question="Покажи публикации с рисками">Публикации с рисками</button><button class="button button-secondary" data-do="assistantAsk" data-question="Сколько открытых жалоб и споров?">Жалобы и споры</button><button class="button button-secondary" data-do="assistantAsk" data-question="Составь отчёт по взаимопомощи">Взаимопомощь</button></div>' +
    '<h2>История диалога</h2><div class="demo-list">' + (history || '<p class="muted">История диалога пока пуста.</p>') + '</div>';
}


function staffPage() {
  const user = me();
  if (user.role !== "teacher" && user.role !== "admin") return '<h1>Нет доступа</h1>';
  const keyWeek = user.id + ":" + weekKey();
  const used = data.teacherUsed[keyWeek] || 0;
  const limit = 500;
  const students = data.users.filter(u => u.role === "student" && !u.blocked && (user.role === "admin" || u.room === user.room));
  const rows = students.map(s => '<div class="data-row"><span><b>' + safe(s.name) + '</b><small>' + safe(s.room || "Класс не указан") + '</small></span><b>' + money(s.scrl) + ' ScRl</b></div>').join("");
  const history = data.ledger.filter(x => x.currency === "ScRl" && x.note.startsWith("Начисление") && students.some(s => s.id === x.user)).slice(0,20).map(x =>
    '<div class="data-row"><span>' + safe(userName(x.user)) + '<small>' + safe(x.note) + ' · ' + new Date(x.date).toLocaleString("ru-RU") + '</small></span><b class="plus">+' + money(x.delta) + '</b></div>'
  ).join("");
  return '<p class="eyebrow">КАБИНЕТ СОТРУДНИКА</p><h1>Кабинет учителя</h1>' +
    '<div class="demo-stats"><div class="demo-stat"><span>Недельный лимит</span><b>' + limit + ' ScRl</b></div><div class="demo-stat"><span>Использовано</span><b>' + money(used) + ' ScRl</b></div><div class="demo-stat"><span>Осталось</span><b>' + money(limit - used) + ' ScRl</b></div></div>' +
    '<form id="staffForm" class="demo-form"><h2>Начислить ученику</h2><label>Ученик</label><select name="student" required>' + students.map(s => '<option value="' + s.id + '">' + safe(s.name) + ' · ' + safe(s.room) + '</option>').join("") + '</select>' +
    '<label>Количество ScRl</label><input name="amount" type="number" min="1" max="' + Math.max(1, limit - used) + '" value="10" required><label>Основание</label><select name="reason"><option>Помощь однокласснику</option><option>Участие в событии</option><option>Учебное достижение</option><option>Проект</option><option>Инициатива</option><option>Другое</option></select>' +
    '<button class="button button-primary" type="submit" ' + (used >= limit || !students.length ? "disabled" : "") + '>Начислить</button></form>' +
    '<h2>Ученики класса</h2><div class="data-list">' + (rows || '<p class="muted">Учеников пока нет.</p>') + '</div><h2>Последние начисления</h2><div class="data-list">' + (history || '<p class="muted">Начислений пока нет.</p>') + '</div>';
}


function adminPage() {
  const user = me();
  if (user.role !== "admin") return '<h1>Нет доступа</h1>';
  const reports = data.reports.filter(r => r.status === "open");
  const search = adminFilter.term.toLowerCase();
  const people = data.users.filter(u =>
    (adminFilter.role === "all" || u.role === adminFilter.role) &&
    (adminFilter.locked === "all" || (adminFilter.locked === "yes" ? u.blocked : !u.blocked)) &&
    [u.name, u.mail, u.room].join(" ").toLowerCase().includes(search)
  );
  const users = people.map(u => '<div class="data-row"><span><b>' + safe(u.name) + '</b><small>' + safe(u.mail || "Email скрыт в общем списке") + ' · ' + safe(u.room || "Без класса") + ' · ' + roleName(u.role) + (u.blocked ? ' · Заблокирован: ' + safe(u.blockReason || "без причины") : '') + '</small></span>' +
    '<span class="actions">' + (u.role !== "admin" ? '<button class="text-button" data-do="block" data-id="' + u.id + '">' + (u.blocked ? "Разблокировать" : "Заблокировать") + '</button><button class="text-button" data-do="promote" data-id="' + u.id + '">' + (u.role === "teacher" ? "Сделать учеником" : "Назначить учителем") + '</button>' : '<span class="small muted">Администратор</span>') +
    (u.id !== user.id && u.role !== "admin" && !u.name.includes("Удалённый") ? '<button class="text-button" data-do="removeuser" data-id="' + u.id + '">Обезличить</button>' : '') + '</span></div>'
  ).join("");
  const queue = reports.map(r => {
    if (r.kind === "deal") return '<div class="data-row"><span><b>' + safe(r.reason) + '</b><small>Спор · ' + new Date(r.date).toLocaleString("ru-RU") + '</small></span><span class="actions"><button class="text-button" data-do="refunddeal" data-id="' + r.id + '">Вернуть</button><button class="text-button" data-do="paydeal" data-id="' + r.id + '">Выплатить</button><button class="text-button" data-do="splitdeal" data-id="' + r.id + '">50/50</button></span></div>';
    return '<div class="data-row"><span><b>' + safe(r.reason) + '</b><small>' + safe(r.reasonCode || r.kind) + ' · ' + safe(r.details || "") + ' · ' + new Date(r.date).toLocaleString("ru-RU") + '</small></span>' +
      '<span class="actions"><button class="text-button" data-do="keep" data-id="' + r.id + '">Оставить</button><button class="text-button" data-do="hide" data-id="' + r.id + '">Скрыть</button></span></div>';
  }).join("");
  const aiCases = (data.moderation?.adminCases || []).map(item =>
    '<article class="data-row"><span><b>' + safe(item.user) + ' · ' + safe(item.kind) + ' · ' + safe(item.decision) + '</b><small>' +
    safe((item.categories || []).join(", ")) + ' · уверенность ' + Math.round(Number(item.confidence || 0) * 100) + '% · ' +
    safe(item.reason) + ' · ' + new Date(item.created_at).toLocaleString("ru-RU") + '</small><details class="moderation-evidence"><summary>Показать проверенное содержимое</summary><pre style="white-space:pre-wrap;overflow-wrap:anywhere;max-height:180px;overflow:auto">' + safe(JSON.stringify(item.evidence || {}, null, 2)) + '</pre></details></span>' +
    '<span class="actions"><button class="text-button" data-do="mod-case-restore" data-id="' + safe(item.id) + '">Восстановить</button>' +
    '<button class="text-button" data-do="mod-case-keep" data-id="' + safe(item.id) + '">Оставить скрытым</button></span></article>'
  ).join("");
  const aiStatusText = data.moderation?.aiEnabled === true
    ? "Включена · Groq отвечает"
    : "Ожидает новый ключ Groq и разрешение на внешнюю проверку";
  const aiAppeals = (data.moderation?.adminAppeals || []).map(item =>
    '<article class="data-row"><span><b>' + safe(item.user) + ' · Апелляция</b><small>' +
    safe(item.reason) + ' · ' + new Date(item.created_at).toLocaleString("ru-RU") + '</small></span>' +
    '<span class="actions"><button class="text-button" data-do="mod-appeal-accept" data-id="' + safe(item.id) + '">Удовлетворить</button>' +
    '<button class="text-button" data-do="mod-appeal-reject" data-id="' + safe(item.id) + '">Отклонить</button></span></article>'
  ).join("");
  const cover = refreshFee();
  const chartValues = data.trades.slice(0, 12).reverse().map(t => Number(t.price));
  const chartMin = Math.min(...(chartValues.length ? chartValues : [data.rate]));
  const chartMax = Math.max(...(chartValues.length ? chartValues : [data.rate]));
  const chart = (chartValues.length ? chartValues : [data.rate]).map(v =>
    '<span title="' + rateMoney(v) + ' V-RUB" style="height:' + (chartMax === chartMin ? 65 : 12 + (v - chartMin) / (chartMax - chartMin) * 88) + '%"></span>'
  ).join("");
  const needs = data.posts.filter(p => p.status === "active" && p.type === "need");
  const offers = data.posts.filter(p => p.status === "active" && p.type === "offer");
  const missing = [...new Set(needs.map(p => p.category))].filter(cat => !offers.some(p => p.category === cat));
  const hints = [];
  if (reports.length) hints.push("Проверь " + reports.length + " жалоб и споров.");
  if (missing.length) hints.push("Нет предложений в категориях: " + missing.join(", ") + ".");
  if (!reports.length && !missing.length) hints.push("Открытых проблем по демо-данным нет.");
  return '<p class="eyebrow">УПРАВЛЕНИЕ</p><h1>Администрирование</h1><div class="demo-links">' + link("pulse", "Пульс лицея") + link("finance", "Платежи") + link("assistant", "AI Moderator") + '</div>' +
    '<div class="demo-stats"><div class="demo-stat"><span>Участники</span><b>' + data.users.length + '</b></div><div class="demo-stat"><span>Открытые жалобы и споры</span><b>' + reports.length + '</b></div></div>' +
    '<section class="match-box"><h2>Подсказки модератора</h2><p class="muted small">Локальная сводка по данным сайта, без внешней ИИ-модели.</p>' + hints.map(x => '<div class="data-row">' + safe(x) + '</div>').join("") + '<button class="button button-secondary" data-do="scan">Перепроверить публикации</button></section>' +
    '<h2>Экономика ScRl</h2><div class="demo-stats"><div class="demo-stat"><span>ScRl в обороте и резерве</span><b>' + money(cover.tokens) + '</b></div><div class="demo-stat"><span>V-RUB всего</span><b>' + money(cover.vrub) + '</b></div><div class="demo-stat"><span>Обеспеченный лимит</span><b>' + money(cover.limit) + '</b></div><div class="demo-stat"><span>Покрытие</span><b>' + money(cover.ratio * 100) + '%</b></div></div>' +
    '<p class="muted small">Текущий курс: ' + rateMoney(currentRate()) + ' V-RUB за ScRl · комиссия по покрытию: ' + money(data.fee * 100) + '% · сожжено: ' + money(data.burned) + ' ScRl.</p>' +
    '<div class="rate-bars">' + chart + '</div><form id="economyForm" class="demo-form"><h2>Целевой курс</h2><label>V-RUB за 1 ScRl</label><input name="rate" type="number" min="0.001" max="1" step="0.001" value="' + data.rate + '" required><button class="button button-primary" type="submit">Сохранить курс</button></form>' +
    '<h2>Участники · ' + people.length + '</h2><form id="adminFilter" class="filter-row"><input name="term" value="' + safe(adminFilter.term) + '" placeholder="Поиск: ФИО, email или класс"><select name="role"><option value="all"' + (adminFilter.role === "all" ? " selected" : "") + '>Все роли</option><option value="student"' + (adminFilter.role === "student" ? " selected" : "") + '>Ученики</option><option value="teacher"' + (adminFilter.role === "teacher" ? " selected" : "") + '>Учителя</option><option value="admin"' + (adminFilter.role === "admin" ? " selected" : "") + '>Администраторы</option></select><select name="locked"><option value="all"' + (adminFilter.locked === "all" ? " selected" : "") + '>Все статусы</option><option value="yes"' + (adminFilter.locked === "yes" ? " selected" : "") + '>Заблокированные</option><option value="no"' + (adminFilter.locked === "no" ? " selected" : "") + '>Активные</option></select><button class="button button-secondary" type="submit">Фильтр</button></form><div class="data-list">' + (users || '<p class="muted">Никого не найдено.</p>') + '</div>' +
    '<section class="match-box moderation-admin"><h2>ИИ-модерация</h2><p class="moderation-status-line"><b>Статус:</b> ' + safe(aiStatusText) + '</p><p class="muted small">На проверку попадают публикации, услуги, аукционы, сделки, личные сообщения, отзывы, имена профилей, жалобы и основания начислений. Критическая блокировка применяется только при высокой уверенности; остальные случаи остаются в очереди.</p>' +
    '<h3>Дела на проверке · ' + (data.moderation?.adminCases || []).length + '</h3><div class="data-list">' + (aiCases || '<p class="muted">Открытых AI-дел нет.</p>') + '</div>' +
    '<h3>Апелляции · ' + (data.moderation?.adminAppeals || []).length + '</h3><div class="data-list">' + (aiAppeals || '<p class="muted">Ожидающих апелляций нет.</p>') + '</div></section>' +
    '<h2>Проверка публикаций и споров</h2><div class="data-list">' + (queue || '<p class="muted">Очередь пуста.</p>') + '</div>' +
    '<h2>Журнал действий</h2><div class="data-list">' + data.audit.slice(0,20).map(a => '<div class="data-row"><span>' + safe(a.text) + '<small>' + new Date(a.date).toLocaleString("ru-RU") + '</small></span><b>' + safe(userName(a.user)) + '</b></div>').join("") + '</div>' +
    '<p class="small muted demo-note">Изменение ролей, блокировки, модерация и финансовые решения проверяются на сервере. Контактные email других участников не раскрываются.</p>';
}


function pulsePage() {
  const user = me();
  if (user.role !== "admin" && user.role !== "teacher") return '<h1>Нет доступа</h1>';
  const members = data.users.filter(u => u.role === "student" && (user.role === "admin" || u.room === user.room));
  const ids = new Set(members.map(u => u.id));
  const posts = data.posts.filter(p => ids.has(p.user));
  const deals = data.deals.filter(d => ids.has(d.buyer) && ids.has(d.seller));
  const since = Date.now() - 30 * 86400000;
  const done = deals.filter(d => d.status === "done" && (d.closed || d.date) >= since);
  const free = done.filter(d => !d.amount).length;
  const activeNeed = posts.filter(p => p.status === "active" && p.type === "need").length;
  const activeOffer = posts.filter(p => p.status === "active" && p.type === "offer").length;
  const openDisputes = deals.filter(d => d.status === "dispute").length;
  const activeDeals = deals.filter(d => ["work","ready","dispute"].includes(d.status)).length;
  const responseTimes = deals.map(d => {
    const post = posts.find(p => p.id === d.sourceId);
    return post ? Math.max(0, d.date - post.date) / 3600000 : null;
  }).filter(v => v !== null);
  const avgHours = responseTimes.length ? responseTimes.reduce((sum,v) => sum + v,0) / responseTimes.length : null;
  const answered = posts.filter(p => p.type === "need" && deals.some(d => d.sourceId === p.id)).length;
  const requests = posts.filter(p => p.type === "need").length;
  const noOffers = [...new Set(posts.filter(p => p.type === "need").map(p => p.category))]
    .filter(cat => !posts.some(p => p.type === "offer" && p.category === cat));
  const scope = user.role === "admin" ? "Весь лицей" : "Класс " + (user.room || "не указан");
  return '<p class="eyebrow">АНАЛИТИКА</p><h1>Пульс лицея</h1><p class="muted">Сводка за 30 дней · ' + safe(scope) + '</p>' +
    '<div class="demo-stats"><div class="demo-stat"><span>Завершённые сделки</span><b>' + done.length + '</b></div><div class="demo-stat"><span>Бесплатная помощь</span><b>' + free + '</b></div>' +
    '<div class="demo-stat"><span>Запросы с откликом</span><b>' + (requests ? money(answered / requests * 100) + '%' : '—') + '</b></div><div class="demo-stat"><span>Среднее время ответа</span><b>' + (avgHours === null ? '—' : money(avgHours) + ' ч') + '</b></div></div>' +
    '<div class="demo-stats"><div class="demo-stat"><span>Активные запросы</span><b>' + activeNeed + '</b></div><div class="demo-stat"><span>Активные предложения</span><b>' + activeOffer + '</b></div>' +
    '<div class="demo-stat"><span>Активные сделки</span><b>' + activeDeals + '</b></div><div class="demo-stat"><span>Активные споры</span><b>' + openDisputes + '</b></div></div>' +
    '<h2>Где нужна помощь</h2><div class="data-list">' + (noOffers.map(cat => '<div class="data-row"><span>' + safe(cat) + '</span><b>Нет предложений</b></div>').join("") || '<p class="muted">По категориям уже есть предложения.</p>') + '</div>' +
    '<p class="small muted demo-note">Показаны только агрегированные показатели. Имена, классы и тексты обращений в аналитике не раскрываются.</p>';
}


function updateMenu() {
  const role = me().role;
  document.querySelectorAll("[data-role]").forEach(btn => {
    btn.hidden = !(btn.dataset.role.split(" ").includes(role));
  });
  if (el("extraMenu")) {
    el("extraMenu").querySelectorAll("[data-page]").forEach(btn => {
      if (btn.dataset.page === "staff") btn.hidden = role !== "teacher" && role !== "admin";
      if (btn.dataset.page === "admin") btn.hidden = role !== "admin";
      if (btn.dataset.page === "pulse") btn.hidden = role !== "teacher" && role !== "admin";
      if (btn.dataset.page === "finance") btn.hidden = role !== "admin";
      if (btn.dataset.page === "assistant") btn.hidden = role !== "admin";
    });
  }
}

function updateTopbarBalance() {
  const user = me();
  const scrl = el("topbarScrlBalance");
  const vrub = el("topbarVrubBalance");
  const control = el("topbarBalance");
  if (!user) return;
  if (scrl) scrl.textContent = money(user.scrl);
  if (vrub) vrub.textContent = money(user.vrub);
  if (control) control.setAttribute("aria-label",
    "Открыть кошелёк. Доступно " + money(user.scrl) + " ScRl и " + money(user.vrub) + " V-RUB."
  );
}

function updateModerationNotice() {
  const notice = el("moderationNotice");
  if (!notice) return;
  if (data.moderation?.aiEnabled === true) {
    notice.dataset.state = "active";
    notice.innerHTML = '<b>ИИ-модерация включена.</b> Groq проверяет пользовательский текст до публикации. Спорные материалы скрываются или направляются в очередь; при недоступности ИИ отправка останавливается.';
  } else {
    notice.dataset.state = "setup";
    notice.innerHTML = '<b>ИИ-модерация пока не активирована.</b> Нужен новый секретный ключ Groq и разрешение на внешнюю проверку. Пока настройка не завершена, новые публикации и другие проверяемые тексты не проходят без проверки.';
  }
}

function setPage(name) {
  closeExpiredAuctions();
  let page = pages[name] ? name : "home";
  const role = me().role;
  if (page === "staff" && role !== "teacher" && role !== "admin") page = "home";
  if (page === "admin" && role !== "admin") page = "home";
  if (page === "pulse" && role !== "teacher" && role !== "admin") page = "home";
  if (page === "finance" && role !== "admin") page = "home";
  if (page === "assistant" && role !== "admin") page = "home";
  document.querySelectorAll(".nav-tab").forEach(btn => {
    const active = btn.dataset.page === page;
    btn.classList.toggle("is-active", active);
    if (active) btn.setAttribute("aria-current", "page");
    else btn.removeAttribute("aria-current");
  });
  el("page").innerHTML = pages[page]();
  updateModerationNotice();
  updateTopbarBalance();
  updateMenu();
  updateNotificationBell();
}

function createDeal(title, buyer, seller, amount, from, sourceId = "") {
  if (remoteReady && !window.__scrlTestMode) return (async () => {
    await backend.createDeal({ title, buyer, seller, amount, source: from, sourceId });
    await refreshRemoteData();
    return data.deals[0] || null;
  })();

  const b = getUser(buyer);
  const s = getUser(seller);
  const price = Number(amount);
  if (!b || !s) throw new Error("Не получилось найти участников сделки.");
  if (buyer === seller) throw new Error("Нельзя создать сделку с самим собой.");
  if (b.blocked || s.blocked) throw new Error("Заблокированный участник не может участвовать в сделке.");
  if (!Number.isFinite(price) || price < 0 || price > 500) throw new Error("Некорректная сумма сделки.");
  if (price > 0) {
    change(buyer, "ScRl", -price, "Резерв по сделке: " + title);
    b.holdScrl = core.round(b.holdScrl + price);
  }
  const deal = { id: uid(), title, buyer, seller, amount: price, escrow: price, status: "work", from, sourceId, messages: [], date: Date.now() };
  data.deals.unshift(deal);
  notify(buyer, "Создана сделка: " + title);
  notify(seller, "Тебе поступил заказ: " + title);
  log("Создана сделка «" + title + "»", buyer);
  log("Новая сделка «" + title + "»", seller);
  save();
  return deal;
}

function refreshFee() {
  if (remoteReady && data.economy) {
    data.fee = Number(data.economy.fee || 0);
    return {
      tokens: Number(data.economy.tokens || 0),
      vrub: Number(data.economy.vrub || 0),
      limit: Number(data.economy.limit || 0),
      ratio: Number(data.economy.ratio || 0)
    };
  }
  const stats = core.coverage(data.users, data.rate);
  data.fee = core.feeFromCoverage(stats.ratio);
  return stats;
}

function releaseDeal(deal, mode, share = 1) {
  if (remoteReady && !window.__scrlTestMode) return (async () => {
    if (me().role === "admin" && deal?.status === "dispute") await backend.resolveDispute(deal.id, mode, share);
    else await backend.dealAction(deal.id, mode, share);
    refreshRemoteData({ background: true, page: "orders" });
  })();

  if (!deal || !["dispute","ready","work"].includes(deal.status)) throw new Error("Эту сделку нельзя завершить.");
  if (me().role !== "admin" && mode === "refund" && deal.status === "dispute") throw new Error("Возврат по спору может сделать только администратор.");
  if (!["refund","pay","split"].includes(mode)) throw new Error("Некорректное решение по сделке.");
  const amount = Number(deal.escrow || 0);
  const buyer = getUser(deal.buyer);
  const seller = getUser(deal.seller);
  if (!buyer || !seller) throw new Error("Участники сделки не найдены.");
  refreshFee();
  const result = core.settlement(amount, data.fee, mode, share);
  buyer.holdScrl = Math.max(0, core.round(buyer.holdScrl - amount));
  if (result.seller > 0) change(deal.seller, "ScRl", result.seller, "Оплата по сделке: " + deal.title);
  if (result.buyer > 0) change(deal.buyer, "ScRl", result.buyer, mode === "refund" ? "Возврат по сделке: " + deal.title : "Возврат остатка по сделке: " + deal.title);
  data.fees = core.round(data.fees + result.fee);
  data.burned = core.round(data.burned + result.fee);
  deal.escrow = 0;
  deal.status = mode === "refund" ? "refund" : "done";
  deal.closed = Date.now();
  notify(deal.buyer, "Сделка «" + deal.title + "» завершена.");
  notify(deal.seller, "Сделка «" + deal.title + "» завершена.");
  log("Сделка «" + deal.title + "»: " + statusName(deal.status));
  save();
}

function placeExchangeOrder(side, amount, price) {
  if (remoteReady && !window.__scrlTestMode) return (async () => {
    await backend.placeExchangeOrder(side, Number(amount), Number(price));
    refreshRemoteData({ background: true, page: "exchange" });
    return null;
  })();

  const user = me();
  const qty = Number(amount);
  const rate = Number(price);
  if (!["scrlSell","vrubSell"].includes(side)) throw new Error("Выбери направление обмена.");
  if (!Number.isSafeInteger(qty) || qty < 1 || qty > 1000000 || !Number.isFinite(rate) || rate < 0.0001 || rate > 10000) {
    throw new Error("Проверь количество и цену.");
  }
  const currency = side === "scrlSell" ? "ScRl" : "V-RUB";
  if (side === "scrlSell") {
    if (user.scrl < qty) throw new Error("Не хватает ScRl для резерва.");
    change(user.id, "ScRl", -qty, "Резерв заявки: продажа ScRl");
    user.holdScrl = core.round(user.holdScrl + qty);
  } else {
    if (user.vrub < qty) throw new Error("Не хватает V-RUB для резерва.");
    change(user.id, "V-RUB", -qty, "Резерв заявки: продажа V-RUB");
    user.holdVrub = core.round(user.holdVrub + qty);
  }
  const order = { id: uid(), side, user: user.id, amount: qty, price: core.round(rate, 4), status: "active", date: Date.now() };
  data.exchangeOrders.unshift(order);
  log("Выставлена заявка на продажу " + qty + " " + currency + ".");
  save();
  return order;
}

function buyExchangeOrder(id) {
  if (remoteReady && !window.__scrlTestMode) return (async () => {
    await backend.buyExchangeOrder(id);
    refreshRemoteData({ background: true, page: "exchange" });
  })();

  const order = data.exchangeOrders.find(x => x.id === id && x.status === "active");
  if (!order) throw new Error("Предложение уже недоступно.");
  if (order.user === me().id) throw new Error("Нельзя купить собственное предложение.");
  const seller = getUser(order.user);
  const buyer = me();
  if (!seller || seller.blocked || buyer.blocked) throw new Error("Один из участников заблокирован.");
  refreshFee();
  const qty = Number(order.amount);
  if (order.side === "scrlSell" && seller.holdScrl < qty) throw new Error("Резерв ScRl этой заявки не найден.");
  if (order.side === "vrubSell" && seller.holdVrub < qty) throw new Error("Резерв V-RUB этой заявки не найден.");
  const deal = core.exchange(order.side, qty, order.price, data.fee);
  if (buyer[deal.buyerPaysIn === "ScRl" ? "scrl" : "vrub"] < deal.buyerPays) {
    throw new Error(deal.buyerPaysIn === "ScRl" ? "Не хватает ScRl для покупки V-RUB." : "Не хватает V-RUB для покупки ScRl.");
  }
  if (order.side === "scrlSell") {
    change(buyer.id, "V-RUB", -deal.buyerPays, "Покупка ScRl на бирже");
    change(buyer.id, "ScRl", deal.buyerGets, "Получено ScRl на бирже");
    seller.holdScrl = Math.max(0, core.round(seller.holdScrl - qty));
    change(seller.id, "V-RUB", deal.sellerGets, "Продажа ScRl на бирже");
  } else {
    change(buyer.id, "ScRl", -deal.buyerPays, "Покупка V-RUB на бирже");
    change(buyer.id, "V-RUB", deal.buyerGets, "Получено V-RUB на бирже");
    seller.holdVrub = Math.max(0, core.round(seller.holdVrub - qty));
    change(seller.id, "ScRl", deal.sellerGets, "Продажа V-RUB на бирже");
  }
  data.fees = core.round(data.fees + deal.fee);
  data.burned = core.round(data.burned + deal.fee);
  order.status = "filled";
  order.buyer = buyer.id;
  order.filledAt = Date.now();
  const amountScRl = order.side === "scrlSell" ? deal.buyerGets : deal.buyerPays;
  const amountVrub = order.side === "scrlSell" ? deal.buyerPays : deal.buyerGets;
  data.trades.unshift({
    id: uid(), buyer: buyer.id, seller: seller.id,
    qty: amountScRl, price: amountScRl > 0 ? core.round(amountVrub / amountScRl, 6) : 0,
    amountScRl, amountVrub, fee: deal.fee, date: Date.now()
  });
  notify(seller.id, "Твоё предложение на бирже купили.");
  notify(buyer.id, "Обмен завершён.");
  log("Обмен на бирже завершён.", buyer.id);
  log("Твоё предложение на бирже купили.", seller.id);
  save();
}

function returnExchangeOrder(order) {
  if (remoteReady && !window.__scrlTestMode) return (async () => {
    if (order) await backend.cancelExchangeOrder(order.id);
    await refreshRemoteData();
  })();

  if (!order || order.status !== "active") return;
  const user = getUser(order.user);
  if (!user) throw new Error("Владелец заявки не найден.");
  if (order.side === "scrlSell") {
    if (user.holdScrl < order.amount) throw new Error("Резерв ScRl этой заявки не найден.");
    user.holdScrl = Math.max(0, core.round(user.holdScrl - order.amount));
    change(user.id, "ScRl", order.amount, "Возврат резерва заявки биржи");
  } else {
    if (user.holdVrub < order.amount) throw new Error("Резерв V-RUB этой заявки не найден.");
    user.holdVrub = Math.max(0, core.round(user.holdVrub - order.amount));
    change(user.id, "V-RUB", order.amount, "Возврат резерва заявки биржи");
  }
  order.status = "cancelled";
  order.cancelledAt = Date.now();
}

function cancelExchangeOrder(id) {
  if (remoteReady && !window.__scrlTestMode) return (async () => {
    await backend.cancelExchangeOrder(id);
    refreshRemoteData({ background: true, page: "exchange" });
  })();

  const order = data.exchangeOrders.find(x => x.id === id && x.user === me().id && x.status === "active");
  if (!order) throw new Error("Активная заявка не найдена.");
  returnExchangeOrder(order);
  log("Заявка на бирже отменена.");
  save();
}


function fav(kind, id) {
  if (remoteReady && !window.__scrlTestMode) return (async () => {
    const exists = data.favorites.some(f => f.user === me().id && f.kind === kind && f.id === id);
    await backend.toggleFavorite(me().id, kind, id, exists);
    await refreshRemoteData();
  })();

  const i = data.favorites.findIndex(f => f.user === me().id && f.kind === kind && f.id === id);
  if (i >= 0) data.favorites.splice(i, 1);
  else data.favorites.push({ user: me().id, kind, id });
  save();
}

function needsReview(text) {
  return /(https?:\/\/|www\.|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|\+?\d[\d\s()-]{8,})/i.test(text);
}

function report(kind, id, reasonCode, details) {
  if (remoteReady && !window.__scrlTestMode) return (async () => {
    const exists = data.reports.some(r => r.kind === kind && r.target === id && r.user === me().id && r.status === "open");
    if (exists) throw new Error("Жалоба уже отправлена.");
    const labels = { unsafe: "Опасное предложение", privacy: "Личные данные", harassment: "Оскорбления", spam: "Спам или обман", other: "Другое" };
    await backend.report({ kind, target: id, user: me().id, reason: labels[reasonCode] || labels.other, reasonCode: reasonCode || "other", details: String(details || "").trim().slice(0,180) });
    await refreshRemoteData();
    msg("Жалоба отправлена на проверку.");
  })();

  const exists = data.reports.some(r => r.kind === kind && r.target === id && r.user === me().id && r.status === "open");
  if (exists) throw new Error("Жалоба уже отправлена.");
  const labels = { unsafe: "Опасное предложение", privacy: "Личные данные", harassment: "Оскорбления", spam: "Спам или обман", other: "Другое" };
  const reason = labels[reasonCode] || labels.other;
  data.reports.unshift({ id: uid(), kind, target: id, user: me().id, reason, reasonCode: reasonCode || "other", details: String(details || "").trim().slice(0,180), status: "open", date: Date.now() });
  data.users.filter(u => u.role === "admin").forEach(u => notify(u.id, "Новая жалоба на " + kind));
  log("Отправлена жалоба на публикацию.");
  msg("Жалоба отправлена на проверку.");
}

function bid(id, amount) {
  if (remoteReady && !window.__scrlTestMode) return (async () => {
    await backend.placeBid(id, Number(amount));
    refreshRemoteData({ background: true, page: "auctions" });
  })();

  if (me().role !== "student") throw new Error("Ставки доступны ученикам.");
  const a = data.auctions.find(x => x.id === id && x.status === "active");
  if (!a || Date.now() >= a.ends || a.owner === me().id) throw new Error("Этот аукцион уже закрыт или принадлежит тебе.");
  const value = Number(amount);
  const minimum = a.bid > 0 ? a.bid + a.step : a.startPrice;
  if (!Number.isSafeInteger(value) || value < minimum || value > 1000000) throw new Error("Минимальная ставка — " + minimum + " ScRl.");
  if (a.leader && a.bid > 0) {
    const old = getUser(a.leader);
    const oldBid = data.bids.find(b => b.auction === a.id && b.user === a.leader && b.amount === a.bid && b.status === "active");
    if (!old || !oldBid || old.holdScrl < a.bid) throw new Error("Не удалось проверить резерв предыдущей ставки.");
    old.holdScrl = Math.max(0, core.round(old.holdScrl - a.bid));
    oldBid.status = old.id === me().id ? "raised" : "outbid";
    change(old.id, "ScRl", a.bid, "Возврат перебитой ставки");
    if (old.id !== me().id) notify(old.id, "Твою ставку в аукционе «" + a.title + "» перебили.");
  }
  if (me().scrl < value) throw new Error("Недостаточно ScRl для такой ставки.");
  change(me().id, "ScRl", -value, "Ставка в аукционе: " + a.title);
  me().holdScrl = core.round(me().holdScrl + value);
  const newBid = { id: uid(), auction: a.id, user: me().id, amount: value, status: "active", date: Date.now() };
  data.bids.unshift(newBid);
  a.bid = value;
  a.leader = me().id;
  a.bids = (a.bids || 0) + 1;
  log("Ставка " + money(value) + " ScRl в аукционе «" + a.title + "»");
  notify(a.owner, "Новая ставка в аукционе «" + a.title + "».");
  save();
}

function closeAuction(a) {
  if (remoteReady && !window.__scrlTestMode) return (async () => {
    if (!a) return false;
    await backend.finishAuction(a.id);
    await refreshRemoteData();
    return true;
  })();

  if (!a || !["active","settlementError"].includes(a.status)) return false;
  if (a.leader && a.bid > 0) {
    const winner = getUser(a.leader);
    const winningBid = data.bids.find(b => b.auction === a.id && b.user === a.leader && b.amount === a.bid && b.status === "active");
    if (!winner || !winningBid || winner.holdScrl < a.bid) {
      a.status = "settlementError";
      a.settlementError = "Не удалось подтвердить удержанную победную ставку.";
      a.settlementErrorAt = Date.now();
      return false;
    }
    winner.holdScrl = Math.max(0, core.round(winner.holdScrl - a.bid));
    winningBid.status = "won";
    data.burned = core.round(data.burned + a.bid);
    data.ledger.unshift({ id: uid(), user: winner.id, currency: "ScRl", delta: 0, note: "Победная ставка списана", date: Date.now() });
    notify(winner.id, "Ты выиграл аукцион «" + a.title + "».");
  }
  a.status = "done";
  a.closed = Date.now();
  delete a.settlementError;
  data.users.filter(u => u.id === a.owner).forEach(u => notify(u.id, "Аукцион «" + a.title + "» завершён."));
  log("Аукцион «" + a.title + "» завершён.");
  return true;
}

function closeExpiredAuctions() {
  if (remoteReady && !window.__scrlTestMode) {
    if (closingAuctions) return;
    const expired = data.auctions.filter(a => a.status === "active" && Date.now() >= a.ends && (a.owner === me().id || me().role === "admin"));
    if (!expired.length) return;
    closingAuctions = true;
    Promise.all(expired.map(a => backend.finishAuction(a.id).catch(error => console.warn("ScRl auction settlement:", error.message))))
      .then(refreshRemoteData).catch(error => console.warn("ScRl refresh:", error.message))
      .finally(() => { closingAuctions = false; });
    return;
  }

  let changed = false;
  data.auctions.filter(a => a.status === "active" && Date.now() >= a.ends).forEach(a => {
    closeAuction(a);
    changed = true;
  });
  if (changed) save();
}

function endAuction(id) {
  if (remoteReady && !window.__scrlTestMode) return (async () => {
    await backend.finishAuction(id);
    refreshRemoteData({ background: true, page: "auctions" });
  })();

  if (me().role !== "admin" && me().role !== "teacher") throw new Error("Нет доступа.");
  const a = data.auctions.find(x => x.id === id && ["active","settlementError"].includes(x.status));
  if (!a) throw new Error("Аукцион уже завершён.");
  if (me().role === "teacher" && a.owner !== me().id) throw new Error("Учитель может завершить только свой аукцион.");
  if (!closeAuction(a)) throw new Error(a.settlementError || "Не удалось завершить аукцион.");
  save();
}


function action(btn) {
  if (remoteReady && !window.__scrlTestMode) return actionRemote(btn);

  if (me().blocked) throw new Error("Аккаунт заблокирован.");
  const id = btn.dataset.id;
  const type = btn.dataset.do;
  if (type === "fav") {
    fav(btn.dataset.kind, id);
    setPage("favorites");
  }
  if (type === "report") report(btn.dataset.kind, id, "other", "");
  if (type === "remove-post") {
    const post = data.posts.find(p => p.id === id && p.user === me().id && p.status === "active");
    if (post) { post.status = "closed"; log("Закрыта публикация «" + post.title + "»."); setPage("board"); }
  }
  if (type === "remove-listing") {
    const item = data.listings.find(p => p.id === id && p.user === me().id && p.status === "active");
    if (item) { item.status = "closed"; log("Снята услуга «" + item.title + "»."); setPage("market"); }
  }
  if (type === "scan") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    let count = 0;
    data.posts.filter(p => p.status === "active").forEach(p => { if (needsReview(p.title + " " + p.desc)) { p.status = "review"; data.reports.unshift({ id: uid(), kind: "post", target: p.id, user: p.user, reason: "Повторная проверка: ссылка или контактные данные", reasonCode: "auto", status: "open", date: Date.now() }); count++; } });
    data.listings.filter(p => p.status === "active").forEach(p => { if (needsReview(p.title + " " + p.desc)) { p.status = "review"; data.reports.unshift({ id: uid(), kind: "listing", target: p.id, user: p.user, reason: "Повторная проверка: ссылка или контактные данные", reasonCode: "auto", status: "open", date: Date.now() }); count++; } });
    data.audit.unshift({ id: uid(), user: me().id, text: "Повторно проверено публикаций: " + count, date: Date.now() });
    save(); setPage("admin"); msg("Проверено публикаций: " + count + ".");
  }
  if (type === "reply") {
    const post = data.posts.find(p => p.id === id && p.status === "active");
    if (!post) return;
    const buyer = post.type === "need" ? post.user : me().id;
    const seller = post.type === "need" ? me().id : post.user;
    createDeal(post.title, buyer, seller, Number(post.price || 0), "board", post.id);
    setPage("orders");
    msg("Отклик добавлен в сделки.");
  }
  if (type === "buy") {
    const item = data.listings.find(x => x.id === id && x.status === "active" && x.slots > 0);
    if (!item) throw new Error("Эта услуга уже недоступна.");
    if (item.user === me().id) throw new Error("Нельзя заказать собственную услугу.");
    createDeal(item.title, me().id, item.user, item.price, "market", item.id);
    item.slots--;
    if (item.slots <= 0) item.status = "sold";
    setPage("orders");
    msg("Заказ создан. ScRl удерживаются до подтверждения.");
  }
  if (type === "endauction" || type === "retryauction") {
    endAuction(id);
    setPage("auctions");
    msg("Аукцион завершён.");
  }
  if (type === "endauction") {
    endAuction(id);
    setPage("auctions");
    msg("Аукцион завершён.");
  }
  if (type === "buyoffer") {
    buyExchangeOrder(id);
    setPage("exchange");
    msg("Обмен завершён.");
  }
  if (type === "canceloffer") {
    cancelExchangeOrder(id);
    setPage("exchange");
    msg("Предложение снято, резерв возвращён.");
  }
  if (type === "delivered") {
    const d = data.deals.find(x => x.id === id && x.seller === me().id && x.status === "work");
    if (d) {
      d.status = "ready";
      notify(d.buyer, "Исполнитель отметил заказ как выполненный.");
      log("Отмечено выполнение заказа «" + d.title + "».");
      setPage("orders");
    }
  }
  if (type === "confirm") {
    const d = data.deals.find(x => x.id === id && x.buyer === me().id && x.status === "ready");
    if (d) {
      releaseDeal(d, "pay");
      setPage("orders");
      msg("Заказ подтверждён, оплата отправлена.");
    }
  }
  if (type === "dispute") {
    const d = data.deals.find(x => x.id === id && (x.buyer === me().id || x.seller === me().id) && ["work","ready"].includes(x.status));
    if (d) {
      d.status = "dispute";
      data.reports.unshift({ id: uid(), kind: "deal", target: d.id, user: me().id, reason: "Спор по сделке «" + d.title + "»", status: "open", date: Date.now() });
      data.users.filter(u => u.role === "admin").forEach(u => notify(u.id, "Открыт спор по сделке."));
      log("Открыт спор по сделке «" + d.title + "».");
      setPage("orders");
    }
  }
  if (type === "assistantAsk") {
    askAssistant(btn.dataset.question || "");
    setPage("assistant");
  }
  if (type === "readall") {
    data.notices.filter(n => n.user === me().id).forEach(n => n.seen = true);
    save();
    setPage("notices");
  }
  if (type === "block") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const u = getUser(id);
    if (u && u.id !== me().id && u.role !== "admin") {
      if (!u.blocked) {
        const activeAuction = data.auctions.some(a => a.status === "active" && (a.owner === u.id || a.leader === u.id));
        if (activeAuction) throw new Error("Сначала завершите активный аукцион участника.");
        const badReserve = data.exchangeOrders.some(o => o.user === u.id && o.status === "active" &&
          (o.side === "scrlSell" ? u.holdScrl < o.amount : u.holdVrub < o.amount));
        if (badReserve) throw new Error("Сначала проверьте резерв заявок участника.");
        const reason = prompt("Причина блокировки участника " + u.name + ":");
        if (!reason || !reason.trim()) throw new Error("Нужно указать причину блокировки.");
        u.blockReason = reason.trim().slice(0, 180);
      } else {
        u.blockReason = "";
      }
      u.blocked = !u.blocked;
      if (u.blocked) {
        data.exchangeOrders.filter(o => o.user === u.id && o.status === "active").forEach(returnExchangeOrder);
        data.users.filter(x => x.role === "admin").forEach(x => notify(x.id, "Участник заблокирован: " + u.name));
      }
      data.audit.unshift({ id: uid(), user: me().id, text: (u.blocked ? "Заблокирован " : "Разблокирован ") + u.name + (u.blocked ? ": " + u.blockReason : ""), date: Date.now() });
      save();
      setPage("admin");
    }
  }
  if (type === "promote") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const u = getUser(id);
    if (u && u.id !== me().id && u.role !== "admin") {
      if (u.role === "teacher") {
        u.role = "student";
      } else {
        const room = prompt("Введи класс для учителя " + u.name + ":");
        if (!room || !room.trim()) throw new Error("Для учителя нужно указать класс.");
        u.room = room.trim().slice(0, 12);
        u.role = "teacher";
      }
      data.audit.unshift({ id: uid(), user: me().id, text: "Изменена роль: " + u.name + " → " + roleName(u.role) + (u.role === "teacher" ? " · " + u.room : ""), date: Date.now() });
      save();
      setPage("admin");
    }
  }
  if (type === "refunddeal" || type === "paydeal" || type === "splitdeal") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const r = data.reports.find(x => x.id === id && x.kind === "deal" && x.status === "open");
    const d = r && data.deals.find(x => x.id === r.target && x.status === "dispute");
    if (d) {
      if (type === "refunddeal") releaseDeal(d, "refund");
      if (type === "paydeal") releaseDeal(d, "pay");
      if (type === "splitdeal") releaseDeal(d, "split", 0.5);
      r.status = "resolved";
      data.audit.unshift({ id: uid(), user: me().id, text: "Решён спор: " + d.title + " · " + type, date: Date.now() });
      save();
      setPage("admin");
    }
  }
  if (type === "removeuser") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const u = getUser(id);
    if (u && u.id !== me().id && u.role !== "admin") {
      const active = data.deals.some(d => (d.buyer === id || d.seller === id) && ["work","ready","dispute"].includes(d.status));
      const orders = data.exchangeOrders.some(o => o.user === id && o.status === "active");
      const auctions = data.auctions.some(a => a.status === "active" && (a.owner === id || a.leader === id));
      if (active || orders || auctions) throw new Error("Сначала заверши сделки, заявки и аукционы участника.");
      if (!confirm("Обезличить профиль " + u.name + "? Его активные объявления будут закрыты.")) return;
      u.name = "Удалённый участник";
      u.mail = "";
      u.room = "";
      u.role = "student";
      u.blocked = true;
      data.posts.filter(x => x.user === id).forEach(x => x.status = "hidden");
      data.listings.filter(x => x.user === id).forEach(x => x.status = "hidden");
      data.audit.unshift({ id: uid(), user: me().id, text: "Обезличен аккаунт участника", date: Date.now() });
      save();
      setPage("admin");
    }
  }
  if (type === "keep" || type === "hide") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const r = data.reports.find(x => x.id === id && x.status === "open");
    if (r) {
      r.status = type === "keep" ? "kept" : "hidden";
      const arr = r.kind === "post" ? data.posts : (r.kind === "listing" ? data.listings : []);
      const target = arr.find(x => x.id === r.target);
      if (target) target.status = type === "hide" ? "hidden" : "active";
      data.audit.unshift({ id: uid(), user: me().id, text: (type === "keep" ? "Оставлена публикация: " : "Скрыта публикация: ") + (target?.title || r.reason), date: Date.now() });
      save();
      setPage("admin");
    }
  }
}

async function actionRemote(btn) {
  if (me()?.blocked) throw new Error("Аккаунт заблокирован.");
  const id = btn.dataset.id;
  const type = btn.dataset.do;

  if (type === "fav") {
    await fav(btn.dataset.kind, id);
    setPage("favorites");
    return;
  }
  if (type === "report") {
    await report(btn.dataset.kind, id, "other", "");
    return;
  }
  if (type === "remove-post" || type === "remove-listing") {
    await backend.closePublication(type === "remove-post" ? "post" : "listing", id);
    await refreshRemoteData();
    setPage(type === "remove-post" ? "board" : "market");
    return;
  }
  if (type === "scan") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const count = await backend.scanPublications();
    await refreshRemoteData();
    setPage("admin");
    msg("Проверено публикаций: " + count + ".");
    return;
  }
  if (type === "reply") {
    const post = data.posts.find(item => item.id === id && item.status === "active");
    if (!post) throw new Error("Публикация больше недоступна.");
    const buyer = post.type === "need" ? post.user : me().id;
    const seller = post.type === "need" ? me().id : post.user;
    await createDeal(post.title, buyer, seller, Number(post.price || 0), "board", post.id);
    setPage("orders");
    msg("Отклик добавлен в сделки.");
    return;
  }
  if (type === "buy") {
    const item = data.listings.find(x => x.id === id && x.status === "active" && x.slots > 0);
    if (!item) throw new Error("Эта услуга уже недоступна.");
    if (item.user === me().id) throw new Error("Нельзя заказать собственную услугу.");
    await createDeal(item.title, me().id, item.user, item.price, "market", item.id);
    setPage("orders");
    msg("Заказ создан. ScRl удерживаются до подтверждения.");
    return;
  }
  if (type === "endauction" || type === "retryauction") {
    await endAuction(id);
    setPage("auctions");
    msg("Аукцион завершён.");
    return;
  }
  if (type === "buyoffer") {
    await buyExchangeOrder(id);
    setPage("exchange");
    msg("Обмен завершён.");
    return;
  }
  if (type === "canceloffer") {
    await cancelExchangeOrder(id);
    setPage("exchange");
    msg("Предложение снято, резерв возвращён.");
    return;
  }
  if (type === "delivered" || type === "confirm" || type === "dispute") {
    const actionName = type === "delivered" ? "delivered" : type === "confirm" ? "confirm" : "dispute";
    await backend.dealAction(id, actionName);
    await refreshRemoteData();
    setPage("orders");
    if (type === "confirm") msg("Заказ подтверждён, оплата отправлена.");
    else if (type === "delivered") msg("Выполнение отмечено.");
    else msg("Спор отправлен администратору.");
    return;
  }
  if (type === "assistantAsk") {
    askAssistant(btn.dataset.question || "");
    setPage("assistant");
    return;
  }
  if (type === "readall") {
    await backend.markNotificationsRead();
    await refreshRemoteData();
    setPage("notices");
    return;
  }
  if (type === "block") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const target = getUser(id);
    if (!target) throw new Error("Участник не найден.");
    const reason = target.blocked ? "" : prompt("Причина блокировки участника " + target.name + ":");
    if (!target.blocked && (!reason || !reason.trim())) throw new Error("Нужно указать причину блокировки.");
    await backend.adminSetUser(id, "block", reason || "");
    await refreshRemoteData();
    setPage("admin");
    return;
  }
  if (type === "promote") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const target = getUser(id);
    if (!target) throw new Error("Участник не найден.");
    let actionName = "teacher";
    let room = "";
    if (target.role === "teacher") actionName = "student";
    else {
      room = prompt("Введи класс для учителя " + target.name + ":");
      if (!room || !room.trim()) throw new Error("Для учителя нужно указать класс.");
    }
    await backend.adminSetUser(id, actionName, "", room.trim());
    await refreshRemoteData();
    setPage("admin");
    return;
  }
  if (type === "removeuser") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const target = getUser(id);
    if (!target || !confirm("Обезличить профиль " + target.name + "? Его активные объявления будут закрыты.")) return;
    await backend.adminSetUser(id, "anonymize");
    await refreshRemoteData();
    setPage("admin");
    return;
  }
  if (type === "mod-case-restore" || type === "mod-case-keep") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    await backend.adminReviewCase(id, type === "mod-case-restore" ? "restore" : "keep_hidden");
    await refreshRemoteData();
    setPage("admin");
    msg("Решение по делу модерации сохранено.");
    return;
  }
  if (type === "mod-appeal-accept" || type === "mod-appeal-reject") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    await backend.adminReviewAppeal(id, type === "mod-appeal-accept" ? "accept" : "reject");
    await refreshRemoteData();
    setPage("admin");
    msg(type === "mod-appeal-accept" ? "Апелляция удовлетворена, блокировка снята." : "Апелляция отклонена.");
    return;
  }
  if (type === "refunddeal" || type === "paydeal" || type === "splitdeal") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const reportRow = data.reports.find(item => item.id === id && item.kind === "deal" && item.status === "open");
    if (!reportRow) throw new Error("Спор не найден.");
    const actionName = type === "refunddeal" ? "refund" : type === "paydeal" ? "pay" : "split";
    await backend.resolveDispute(reportRow.target, actionName, 0.5);
    await refreshRemoteData();
    setPage("admin");
    return;
  }
  if (type === "keep" || type === "hide") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const reportRow = data.reports.find(item => item.id === id && item.status === "open");
    if (!reportRow) throw new Error("Жалоба не найдена.");
    if (!["post","listing"].includes(reportRow.kind)) throw new Error("Этот тип жалобы решается отдельно.");
    await backend.adminModerate(reportRow.kind, reportRow.target, type);
    await refreshRemoteData();
    setPage("admin");
  }
}

async function submitRemote(form) {
  if (me()?.blocked) throw new Error("Аккаунт заблокирован.");
  const fields = new FormData(form);

  if (form.dataset.form === "assistant") {
    askAssistant(String(fields.get("message") || ""));
    setPage("assistant");
    return;
  }
  if (form.dataset.form === "report") {
    await report(form.dataset.kind, form.dataset.id, String(fields.get("reason") || "other"), String(fields.get("details") || ""));
    form.reset();
    return;
  }
  if (form.id === "adminFilter") {
    adminFilter.term = String(fields.get("term") || "").trim();
    adminFilter.role = String(fields.get("role") || "all");
    adminFilter.locked = String(fields.get("locked") || "all");
    setPage("admin");
    return;
  }
  if (form.id === "economyForm") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const rate = Number(fields.get("rate"));
    if (!Number.isFinite(rate) || rate < 0.001 || rate > 1) throw new Error("Курс должен быть от 0,001 до 1 V-RUB.");
    await backend.adminUpdateEconomy(rate);
    await refreshRemoteData();
    setPage("admin");
    msg("Целевой курс сохранён.");
    return;
  }
  if (form.id === "marketFilter") {
    marketFilter.term = String(fields.get("term") || "").trim();
    marketFilter.category = String(fields.get("category") || "all");
    marketFilter.sort = String(fields.get("sort") || "new");
    setPage("market");
    return;
  }
  if (form.id === "boardFilter") {
    filter.term = String(fields.get("term") || "").trim();
    filter.type = String(fields.get("type") || "all");
    setPage("board");
    return;
  }
  if (form.id === "boardForm") {
    const title = String(fields.get("title") || "").trim();
    const description = String(fields.get("desc") || "").trim();
    const price = Number(fields.get("price"));
    if (!title || !description || !Number.isFinite(price) || price < 0 || price > 500) throw new Error("Проверь заголовок, описание и цену.");
    await backend.createPost({
      type: String(fields.get("type") || "need"), title, description,
      category: String(fields.get("category") || "Другое"), price
    });
    await refreshRemoteData();
    const created = data.posts[0];
    setPage("board");
    msg(created?.status === "review"
      ? "Публикация отправлена на проверку."
      : created?.status === "hidden"
        ? "Публикация скрыта ИИ до решения модератора."
        : "Публикация добавлена.");
    return;
  }
  if (form.id === "marketForm") {
    const title = String(fields.get("title") || "").trim();
    const description = String(fields.get("desc") || "").trim();
    const price = Number(fields.get("price"));
    const slots = Number(fields.get("slots"));
    if (!title || !description || !Number.isFinite(price) || price < 1 || price > 500 ||
        !Number.isInteger(slots) || slots < 1 || slots > 10) throw new Error("Проверь данные услуги.");
    await backend.createListing({
      title, description, category: String(fields.get("category") || "Другое"), price, slots
    });
    await refreshRemoteData();
    const created = data.listings[0];
    setPage("market");
    msg(created?.status === "review"
      ? "Услуга отправлена на проверку."
      : created?.status === "hidden"
        ? "Услуга скрыта ИИ до решения модератора."
        : "Услуга опубликована.");
    return;
  }
  if (form.id === "sellScrlForm") {
    await placeExchangeOrder("scrlSell", Number(fields.get("amount")), Number(fields.get("price")));
    setPage("exchange");
    msg("Предложение ScRl опубликовано.");
    return;
  }
  if (form.id === "sellVrubForm") {
    await placeExchangeOrder("vrubSell", Number(fields.get("amount")), Number(fields.get("price")));
    setPage("exchange");
    msg("Предложение V-RUB опубликовано.");
    return;
  }
  if (form.dataset.form === "auctionBid") {
    await bid(form.dataset.id, Number(fields.get("amount")));
    setPage("auctions");
    msg("Ставка принята.");
    return;
  }
  if (form.id === "auctionForm") {
    if (me().role !== "teacher" && me().role !== "admin") throw new Error("Создавать аукционы могут учителя и администраторы.");
    const title = String(fields.get("title") || "").trim();
    const prize = String(fields.get("prize") || "").trim();
    const startPrice = Number(fields.get("start"));
    const step = Number(fields.get("step"));
    const minutes = Number(fields.get("minutes"));
    const cashPrize = /(руб|рубл|деньг|денеж|налич|перевод|оплат|usd|eur|cash|dollar|банковск|[₽€$])/iu.test(prize);
    if (!title || !prize || cashPrize || !Number.isSafeInteger(startPrice) || startPrice < 1 || startPrice > 1000000 ||
        !Number.isSafeInteger(step) || step < 1 || step > 1000000 ||
        !Number.isSafeInteger(minutes) || minutes < 1 || minutes > 10080) {
      throw new Error("Проверь данные аукциона. Приз должен быть неденежным.");
    }
    await backend.createAuction({ title, prize, start: startPrice, step, minutes });
    await refreshRemoteData();
    const createdAuction = data.auctions[0];
    setPage("auctions");
    msg(createdAuction?.status === "review"
      ? "Аукцион отправлен на проверку."
      : createdAuction?.status === "hidden"
        ? "Аукцион скрыт ИИ до решения модератора."
        : "Аукцион опубликован.");
    return;
  }
  if (form.id === "deleteAccountForm") {
    const confirmation = String(fields.get("confirmation") || "").trim();
    if (confirmation !== "УДАЛИТЬ") throw new Error("Введи слово УДАЛИТЬ без изменений.");
    const button = form.querySelector('button[type="submit"]');
    if (button) { button.disabled = true; button.textContent = "Удаляем аккаунт…"; }
    try {
      await backend.deleteAccount(confirmation);
      sessionStorage.removeItem("scrlSession");
      remoteReady = false;
      leave();
      if (el("logErr")) el("logErr").textContent = "Аккаунт удалён. Личные данные обезличены.";
    } catch (error) {
      if (button) { button.disabled = false; button.textContent = "Удалить аккаунт окончательно"; }
      throw error;
    }
    return;
  }
  if (form.id === "profileForm") {
    const name = String(fields.get("name") || "").trim();
    const roomField = fields.get("room");
    const room = roomField == null ? String(me().room || "") : String(roomField).trim();
    const selectedRole = String(fields.get("role") || "");
    if (!name) throw new Error("Имя не может быть пустым.");
    if (name.length > 100) throw new Error("ФИО не должно быть длиннее 100 символов.");
    await backend.updateProfile(me().id, name, room);
    me().name = name;
    me().room = room;
    const session = sess();
    session.name = name;
    sessionStorage.setItem("scrlSession", JSON.stringify(session));
    if (isAdminAccount() && selectedRole) setAdminPreviewRole(selectedRole);
    el("userName").textContent = name;
    el("avatar").textContent = name.charAt(0).toUpperCase();
    log("Обновлён профиль.");
    setPage("profile");
    msg("Профиль сохранён после проверки.");
    refreshRemoteData({ background: true, page: "profile" });
    return;
  }
  if (form.id === "staffForm") {
    if (me().role !== "teacher" && me().role !== "admin") throw new Error("Нет доступа.");
    const studentId = String(fields.get("student") || "");
    const amount = Number(fields.get("amount"));
    const reason = String(fields.get("reason") || "Другое");
    await backend.issueTokens(studentId, amount, reason);
    await refreshRemoteData();
    setPage("staff");
    msg("ScRl начислены.");
  }
}

async function submit(form) {
  if (remoteReady && !window.__scrlTestMode) return submitRemote(form);

  if (me().blocked) throw new Error("Аккаунт заблокирован.");
  const fields = new FormData(form);
  if (form.dataset.form === "assistant") {
    askAssistant(String(fields.get("message") || ""));
    setPage("assistant");
    return;
  }
  if (form.dataset.form === "report") {
    report(form.dataset.kind, form.dataset.id, String(fields.get("reason") || "other"), String(fields.get("details") || ""));
    form.reset();
    return;
  }
  if (form.id === "adminFilter") {
    adminFilter.term = String(fields.get("term") || "").trim();
    adminFilter.role = String(fields.get("role") || "all");
    adminFilter.locked = String(fields.get("locked") || "all");
    setPage("admin");
    return;
  }
  if (form.id === "economyForm") {
    if (me().role !== "admin") throw new Error("Нет доступа.");
    const rate = Number(fields.get("rate"));
    if (!Number.isFinite(rate) || rate < 0.001 || rate > 1) throw new Error("Курс должен быть от 0,001 до 1 V-RUB.");
    data.rate = core.round(rate, 3);
    refreshFee();
    data.audit.unshift({ id: uid(), user: me().id, text: "Изменён целевой курс ScRl: " + rateMoney(data.rate), date: Date.now() });
    save(); setPage("admin"); msg("Целевой курс сохранён.");
    return;
  }
  if (form.id === "marketFilter") {
    marketFilter.term = String(fields.get("term") || "").trim();
    marketFilter.category = String(fields.get("category") || "all");
    marketFilter.sort = String(fields.get("sort") || "new");
    setPage("market");
    return;
  }
  if (form.id === "boardFilter") {
    filter.term = String(fields.get("term") || "").trim();
    filter.type = String(fields.get("type") || "all");
    setPage("board");
  }
  if (form.id === "boardForm") {
    const title = String(fields.get("title") || "").trim();
    const desc = String(fields.get("desc") || "").trim();
    const price = Number(fields.get("price"));
    if (!title || !desc || !Number.isFinite(price) || price < 0 || price > 500) throw new Error("Проверь заголовок, описание и цену.");
    const status = needsReview(title + " " + desc) ? "review" : "active";
    const post = { id: uid(), type: fields.get("type"), title, desc, category: fields.get("category"), price, user: me().id, status, date: Date.now() };
    data.posts.unshift(post);
    if (status === "review") data.reports.unshift({ id: uid(), kind: "post", target: post.id, user: me().id, reason: "Автопроверка: в тексте есть ссылка или контактные данные", status: "open", date: Date.now() });
    log("Создана публикация «" + title + "».");
    setPage("board");
    msg(status === "review" ? "Публикация отправлена на проверку." : "Публикация добавлена.");
  }
  if (form.id === "marketForm") {
    const title = String(fields.get("title") || "").trim();
    const desc = String(fields.get("desc") || "").trim();
    const price = Number(fields.get("price"));
    const slots = Number(fields.get("slots"));
    if (!title || !desc || !Number.isFinite(price) || price < 1 || price > 500 || !Number.isInteger(slots) || slots < 1 || slots > 10) throw new Error("Проверь данные услуги.");
    const status = needsReview(title + " " + desc) ? "review" : "active";
    const item = { id: uid(), title, desc, category: fields.get("category"), price, slots, user: me().id, status, date: Date.now() };
    data.listings.unshift(item);
    if (status === "review") data.reports.unshift({ id: uid(), kind: "listing", target: item.id, user: me().id, reason: "Автопроверка: в тексте есть ссылка или контактные данные", status: "open", date: Date.now() });
    log("Добавлена услуга «" + title + "».");
    setPage("market");
    msg(status === "review" ? "Услуга отправлена на проверку." : "Услуга опубликована.");
  }
  if (form.id === "sellScrlForm") {
    const amount = Number(fields.get("amount"));
    const price = Number(fields.get("price"));
    placeExchangeOrder("scrlSell", amount, price);
    setPage("exchange");
    msg("Предложение ScRl опубликовано.");
    return;
  }
  if (form.id === "sellVrubForm") {
    const amount = Number(fields.get("amount"));
    const price = Number(fields.get("price"));
    placeExchangeOrder("vrubSell", amount, price);
    setPage("exchange");
    msg("Предложение V-RUB опубликовано.");
    return;
  }
  if (form.dataset.form === "auctionBid") {
    bid(form.dataset.id, Number(fields.get("amount")));
    setPage("auctions");
    msg("Ставка принята.");
    return;
  }
  if (form.id === "auctionForm") {
    if (me().role !== "teacher" && me().role !== "admin") throw new Error("Создавать аукционы могут учителя и администраторы.");
    const title = String(fields.get("title") || "").trim();
    const prize = String(fields.get("prize") || "").trim();
    const start = Number(fields.get("start"));
    const step = Number(fields.get("step"));
    const minutes = Number(fields.get("minutes"));
    const cashPrize = /(руб|рубл|деньг|денеж|налич|перевод|оплат|usd|eur|cash|dollar|банковск|[₽€$])/iu.test(prize);
    if (!title || !prize || cashPrize || !Number.isSafeInteger(start) || start < 1 || start > 1000000 ||
        !Number.isSafeInteger(step) || step < 1 || step > 1000000 || !Number.isSafeInteger(minutes) || minutes < 1 || minutes > 10080) {
      throw new Error("Проверь данные аукциона. Приз должен быть неденежным.");
    }
    const auction = { id: uid(), title, prize, startPrice: start, step, bid: 0, leader: "", owner: me().id, ends: Date.now() + minutes * 60000, status: "active", bids: 0, created: Date.now() };
    data.auctions.unshift(auction);
    log("Создан аукцион «" + title + "».");
    setPage("auctions");
    msg("Аукцион опубликован.");
  }
  if (form.id === "profileForm") {
    const name = String(fields.get("name") || "").trim();
    if (!name) throw new Error("Имя не может быть пустым.");
    me().name = name;
    const roomField = fields.get("room");
    me().room = roomField == null ? String(me().room || "") : String(roomField).trim();
    const s = sess();
    if (s?.guest) me().role = fields.get("role") || "student";
    else if (isAdminAccount() && fields.get("role")) setAdminPreviewRole(fields.get("role"));
    if (!s?.guest && s?.token && cfg.url && cfg.key) await saveProfile(me().id, name, s.token, me().room);
    s.name = name;
    sessionStorage.setItem("scrlSession", JSON.stringify(s));
    el("userName").textContent = name;
    el("avatar").textContent = name.charAt(0).toUpperCase();
    log("Обновлён профиль.");
    setPage("profile");
    msg("Профиль сохранён.");
  }
  if (form.id === "staffForm") {
    if (me().role !== "teacher" && me().role !== "admin") throw new Error("Нет доступа.");
    const target = getUser(fields.get("student"));
    const amount = Number(fields.get("amount"));
    const wk = me().id + ":" + weekKey();
    const used = data.teacherUsed[wk] || 0;
    const limit = 500;
    if (!target || target.blocked || target.role !== "student" || (me().role === "teacher" && target.room !== me().room)) throw new Error("Выбери активного ученика из своего класса.");
    if (!Number.isInteger(amount) || amount < 1 || used + amount > limit) throw new Error("Превышен недельный лимит.");
    const cover = refreshFee();
    if (cover.tokens + amount > cover.limit) throw new Error("Начисление превысит обеспеченный лимит ScRl.");
    change(target.id, "ScRl", amount, "Начисление: " + fields.get("reason"));
    data.teacherUsed[wk] = used + amount;
    log("Начислено " + amount + " ScRl ученику " + target.name + ".", me().id);
    data.audit.unshift({ id: uid(), user: me().id, text: "Начислено " + amount + " ScRl: " + target.name, date: Date.now() });
    setPage("staff");
    msg("ScRl начислены.");
  }
}

function paintWorldTheme(theme) {
  const normalized = theme === "light" ? "light" : "dark";
  const world = normalized === "dark" ? "cave" : "surface";
  const root = document.documentElement;
  root.dataset.theme = normalized;
  root.dataset.world = world;
  if (document.body) {
    document.body.dataset.theme = normalized;
    document.body.dataset.world = world;
  }
  localStorage.setItem("scrlTheme", normalized);

  [el("themeBtn"), el("authThemeBtn")].forEach(button => {
    if (!button) return;
    button.textContent = normalized === "dark" ? "☀ Светлая тема" : "☾ Тёмная тема";
    button.setAttribute("aria-label", normalized === "dark" ? "Включить светлую тему" : "Включить тёмную тему");
    button.title = normalized === "dark" ? "Светлая тема" : "Тёмная тема";
  });

  const meta = document.querySelector && document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute("content", normalized === "dark" ? "#101820" : "#9ab99b");
}

function applyTheme() {
  const savedTheme = localStorage.getItem("scrlTheme");
  const normalized = savedTheme === "dark" ? "dark" : "light";
  paintWorldTheme(normalized);
}

function switchTheme() {
  const current = document.documentElement.dataset.theme === "light" ? "light" : "dark";
  paintWorldTheme(current === "dark" ? "light" : "dark");
}

applyTheme();
[el("themeBtn"), el("authThemeBtn")].forEach(button => {
  if (button) button.addEventListener("click", switchTheme);
});


el("openRegistration").addEventListener("click", () => setMode("reg"));
el("returnToPage2").addEventListener("click", () => setMode("login"));
el("backToLogin").addEventListener("click", () => setMode("login"));
const loginFormConfigs = [
  { form: login, mailId: "logMail", passId: "logPass", errorId: "logErr" }
];
loginFormConfigs.forEach(config => {
  if (!config.form) return;
  config.form.addEventListener("submit", async event => {
    event.preventDefault();
    const mailField = el(config.mailId);
    const passField = el(config.passId);
    const errorField = el(config.errorId);
    if (errorField) errorField.textContent = "";
    try {
      const email = mailField.value.trim().toLowerCase();
      const result = await ask("token?grant_type=password", {
        email,
        password: passField.value
      });
      const name = result.user?.user_metadata?.full_name || result.user?.email || "Ученик";
      await enter(name, result.user?.email || email, result.access_token || "", false, result.user.id);
    } catch (err) {
      const message = String(err.message || "");
      if (/email not confirmed/i.test(message)) {
        if (errorField) errorField.textContent = "Сначала подтверди почту в процессе регистрации.";
      } else if (/invalid login credentials|invalid grant|invalid email or password/i.test(message)) {
        if (errorField) errorField.textContent = "Не удалось войти. Проверь email и пароль. Если аккаунт ещё не создан, сначала зарегистрируйся.";
      } else if (errorField) {
        errorField.textContent = message;
      }
    }
  });
});

reg.addEventListener("submit", async event => {
  event.preventDefault();
  el("regErr").textContent = "";
  const last = el("regLast").value.trim();
  const first = el("regFirst").value.trim();
  const pat = el("regPat").value.trim();
  const mail = el("regMail").value.trim().toLowerCase();
  const pass = el("regPass").value;
  const again = el("regAgain").value;
  if (!last || !first) return el("regErr").textContent = "Напиши фамилию и имя.";
  if (!mail) return el("regErr").textContent = "Введи электронную почту.";
  if (pass.length < 8) return el("regErr").textContent = "Пароль должен быть не короче 8 символов.";
  if (pass !== again) return el("regErr").textContent = "Пароли не совпадают.";
  const name = [last, first, pat].filter(Boolean).join(" ");
  pending = { name, mail };
  try {
    await ask("signup?redirect_to=" + encodeURIComponent(APP_REDIRECT_URL), { email: mail, password: pass });
    setCodePage();
    msg("Код отправлен на почту.");
  } catch (err) {
    pending = null;
    el("regErr").textContent = err.message;
  }
});

codeForm.addEventListener("submit", async event => {
  event.preventDefault();
  el("codeErr").textContent = "";
  const token = el("code").value.trim();
  if (!/^[0-9]{8}$/.test(token)) return el("codeErr").textContent = "Введи все восемь цифр.";
  if (!pending?.mail) return el("codeErr").textContent = "Начни регистрацию заново.";

  try {
    const mail = pending.mail;
    const result = await ask("verify", { email: mail, token, type: "email" });
    if (!result.user?.id || !result.access_token) {
      throw new Error("Не удалось подтвердить почту. Проверь код или запроси новый.");
    }
    const name = pending.name || result.user?.email || mail;
    pending = null;
    codeForm.reset();
    reg.reset();
    el("logMail").value = mail;
    setMode("login");
    try {
      await saveProfile(result.user.id, name, result.access_token);
      msg("Почта подтверждена. Теперь войди по email и паролю.");
    } catch (profileError) {
      msg("Почта подтверждена. Имя можно сохранить после настройки ИИ-модерации.");
      console.warn("ScRl profile moderation:", profileError);
    }
  } catch (err) {
    const message = String(err?.message || "");
    if (/otp_expired|token has expired or is invalid|invalid.*token/i.test(message)) {
      el("codeErr").textContent = "Этот код уже использован, заменён новым или истёк. Запроси новый код и введи только самый последний из письма. Если почта уже подтверждена по ссылке, вернись ко входу и попробуй войти по паролю.";
    } else {
      el("codeErr").textContent = message || "Не удалось проверить код. Попробуй ещё раз.";
    }
  }
});

const banAppealForm = el("banAppealForm");
if (banAppealForm) {
  banAppealForm.addEventListener("submit", async event => {
    event.preventDefault();
    const reason = String(el("banAppealReason")?.value || "").trim();
    const ban = data.moderation?.activeBan;
    const status = el("banAppealStatus");
    if (!ban?.id) {
      if (status) status.textContent = "Не найдена активная блокировка для апелляции.";
      return;
    }
    if (!ban.canAppeal) {
      if (status) status.textContent = "Срок подачи апелляции (24 часа) закончился.";
      return;
    }
    if (reason.length < 10) {
      if (status) status.textContent = "Опиши ситуацию подробнее: минимум 10 символов.";
      return;
    }
    const button = banAppealForm.querySelector("button[type=submit]");
    if (button) button.disabled = true;
    if (status) status.textContent = "Отправляем апелляцию…";
    try {
      await backend.submitAppeal(ban.id, reason);
      const session = sess();
      data = await backend.load(session.token, session.id, session.mail);
      showBanAppeal();
      if (status) status.textContent = "Апелляция отправлена. Администратор рассмотрит её.";
      banAppealForm.hidden = true;
    } catch (error) {
      if (status) status.textContent = error.message || "Не удалось отправить апелляцию.";
    } finally {
      if (button) button.disabled = false;
    }
  });
}

el("againCode").addEventListener("click", async () => {
  const button = el("againCode");
  el("codeErr").textContent = "";
  if (!pending?.mail) {
    el("codeErr").textContent = "Начни регистрацию заново.";
    return;
  }
  if (button.disabled) return;
  button.disabled = true;
  try {
    await ask("resend", { type: "signup", email: pending.mail });
    el("code").value = "";
    el("code").dispatchEvent(new Event("input", { bubbles: true }));
    el("code").focus();
    msg("Новый код отправлен. Старый код больше не подходит.");
  } catch (err) {
    el("codeErr").textContent = err.message;
  } finally {
    button.disabled = false;
  }
});

el("backReg").addEventListener("click", () => {
  setMode("reg");
  el("regLast").focus();
});
setupAuthDeviceMode();

const otpInput = el("code");
if (otpInput && !window.__scrlTestMode) {
  otpInput.addEventListener("input", () => {
    const current = otpInput.value;
    const caret = typeof otpInput.selectionStart === "number" ? otpInput.selectionStart : current.length;
    const digitsBeforeCaret = current.slice(0, caret).replace(/[^0-9]/g, "").length;
    const clean = current.replace(/[^0-9]/g, "").slice(0, 8);
    if (clean !== current) {
      otpInput.value = clean;
      if (typeof otpInput.setSelectionRange === "function") {
        otpInput.setSelectionRange(Math.min(digitsBeforeCaret, clean.length), Math.min(digitsBeforeCaret, clean.length));
      }
    }
  });
}

const authBook = el("authBook");
if (authBook && !window.__scrlTestMode) {
  authBook.addEventListener("focusin", event => {
    const target = event.target;
    if (target.closest && target.closest("#regForm, #codeForm")) {
      authBook.dataset.activePage = "3";
    }
    updateBookControls();
  });
  installMinecraftBookCursors();
}

document.querySelectorAll(".nav-tab").forEach(btn => btn.addEventListener("click", () => setPage(btn.dataset.page)));
if (el("topbarBalance")) el("topbarBalance").addEventListener("click", () => setPage("wallet"));
el("logout").addEventListener("click", () => {
  if (window.confirm("Выйти из аккаунта ScRl?")) leave();
});

if (el("moreBtn")) {
  el("moreBtn").addEventListener("click", () => {
    const menu = el("extraMenu");
    menu.hidden = !menu.hidden;
    el("moreBtn").setAttribute("aria-expanded", String(!menu.hidden));
    closeNotificationPanel();
  });
  el("extraMenu").addEventListener("click", event => {
    const btn = event.target.closest("[data-page]");
    if (btn) {
      setPage(btn.dataset.page);
      el("extraMenu").hidden = true;
      el("moreBtn").setAttribute("aria-expanded", "false");
    }
  });
}
if (el("notificationBell")) {
  el("notificationBell").addEventListener("click", event => {
    if (event.stopPropagation) event.stopPropagation();
    const panel = el("notificationPanel");
    const opening = panel.hidden;
    panel.hidden = !opening;
    el("notificationBell").setAttribute("aria-expanded", String(opening));
    el("extraMenu").hidden = true;
    el("moreBtn").setAttribute("aria-expanded", "false");
    if (opening) updateNotificationBell();
  });
}
if (el("notificationPanel")) {
  el("notificationPanel").addEventListener("click", event => {
    const control = event.target.closest("[data-do], [data-notification-page]");
    if (!control) return;
    if (control.dataset.do === "readall") {
      try {
        const result = action(control);
        if (result && typeof result.catch === "function") result.catch(error => msg(error.message || "Не удалось обновить уведомления."));
      } catch (error) {
        msg(error.message || "Не удалось обновить уведомления.");
      }
      closeNotificationPanel();
      return;
    }
    if (control.dataset.notificationPage !== undefined) {
      setPage("notices");
      closeNotificationPanel();
    }
  });
}
if (document.addEventListener) {
  document.addEventListener("click", event => {
    if (event.target?.closest && !event.target.closest(".notification-wrap")) closeNotificationPanel();
  });
  document.addEventListener("keydown", event => {
    if (event.key === "Escape") closeNotificationPanel();
  });
}

el("page").addEventListener("click", event => {
  const target = event.target;
  if (!target.closest) return;
  const pageBtn = target.closest("[data-page]");
  if (pageBtn) {
    setPage(pageBtn.dataset.page);
    if (el("extraMenu")) el("extraMenu").hidden = true;
    return;
  }
  const btn = target.closest("[data-do]");
  if (!btn) return;
  try {
    const result = action(btn);
    if (result && typeof result.catch === "function") result.catch(err => msg(err.message || "Не получилось выполнить действие."));
  } catch (err) {
    msg(err.message || "Не получилось выполнить действие.");
  }
});

el("page").addEventListener("submit", async event => {
  const form = event.target;
  if (!form.matches("form")) return;
  event.preventDefault();
  if (form.dataset.form === "message") {
    const d = data.deals.find(x => x.id === form.dataset.id);
    const text = String(new FormData(form).get("text") || "").trim();
    if (remoteReady && d && text && (d.buyer === me().id || d.seller === me().id)) {
      backend.sendMessage(d.id, text).then(async result => {
        await refreshRemoteData();
        setPage("orders");
        msg(result && result.moderation && (result.moderation.decision === "flag" || result.moderation.decision === "hide")
          ? "Сообщение отправлено и скрыто от собеседника до проверки."
          : "Сообщение отправлено.");
      }).catch(err => msg(err.message || "Не удалось отправить сообщение."));
    } else if (d && text && (d.buyer === me().id || d.seller === me().id)) {
      d.messages.push({ user: me().id, text, date: Date.now() });
      notify(d.buyer === me().id ? d.seller : d.buyer, "Новое сообщение по сделке «" + d.title + "».");
      log("Отправлено сообщение по сделке «" + d.title + "».");
      setPage("orders");
    }
    return;
  }
  if (form.dataset.form === "review") {
    const d = data.deals.find(x => x.id === form.dataset.id && x.status === "done");
    const fields = new FormData(form);
    if (remoteReady && d && !data.reviews.some(r => r.deal === d.id && r.user === me().id)) {
      const target = d.buyer === me().id ? d.seller : d.buyer;
      backend.addReview({ deal: d.id, user: me().id, target, rating: Number(fields.get("rating")), text: String(fields.get("text") || "").trim() })
        .then(refreshRemoteData).then(() => setPage("orders")).catch(err => msg(err.message || "Не удалось сохранить отзыв."));
    } else if (d && !data.reviews.some(r => r.deal === d.id && r.user === me().id)) {
      const target = d.buyer === me().id ? d.seller : d.buyer;
      data.reviews.unshift({ id: uid(), deal: d.id, user: me().id, target, rating: Number(fields.get("rating")), text: String(fields.get("text") || "").trim(), date: Date.now() });
      notify(target, "Тебе оставили отзыв.");
      log("Оставлен отзыв по сделке «" + d.title + "».");
      setPage("orders");
    }
    return;
  }
  try {
    await submit(form);
  } catch (err) {
    msg(err.message || "Проверь заполненные поля.");
  }
});

const oldSess = sess();
if (oldSess) {
  enter(oldSess.name || "Ученик", oldSess.mail || "", oldSess.token || "", oldSess.guest || false, oldSess.id || "");
} else {
  auth.hidden = false;
  app.hidden = true;
  setMode("login");
}

if (window.__scrlTestMode) {
  window.scrlTest = {
    activeTheme: () => document.documentElement.dataset.theme,
    switchTheme,
    applyTheme,
    get data() { return data; },
    me,
    getUser,
    isAdminAccount,
    setAdminPreviewRole,
    resetAdminPreviewRole,
    leave,
    setPage,
    updateTopbarBalance,
    homePage,
    boardPage,
    exchangePage,
    auctionsPage,
    assistantPage,
    financePage,
    walletPage,
    ordersPage,
    activityPage,
    favoritesPage,
    noticesPage,
    notificationItems,
    updateNotificationBell,
    notify,
    profilePage,
    staffPage,
    adminPage,
    pulsePage,
    askAssistant,
    action,
    enter,
    submit,
    report,
    createDeal,
    releaseDeal,
    bid,
    endAuction,
    closeExpiredAuctions,
    placeExchangeOrder,
    buyExchangeOrder,
    cancelExchangeOrder
  };
}
