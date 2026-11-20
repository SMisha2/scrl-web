const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function loadBackend(config = {}) {
  const calls = [];
  const window = { cfg: { url: "https://scrl-test.supabase.co", key: "sb_publishable_test" } };
  const stored = new Map([["scrlSession", JSON.stringify(config.session || { token: "signed-user-jwt" })]]);
  const local = new Map();
  const localStorage = {
    getItem(key) { return local.has(key) ? local.get(key) : null; },
    setItem(key, value) { local.set(key, String(value)); },
    removeItem(key) { local.delete(key); }
  };
  const sessionStorage = {
    getItem(key) { return stored.has(key) ? stored.get(key) : null; },
    setItem(key, value) { stored.set(key, String(value)); },
    removeItem(key) { stored.delete(key); }
  };
  const fetch = async (url, options) => {
    calls.push({ url, options });
    if (config.fetch) return config.fetch(url, options, { localStorage, sessionStorage });
    if (String(url).includes("/functions/v1/scrl-moderation")) {
      return {
        ok: true, status: 200,
        async text() { return JSON.stringify({ allowed: true, decision: "allow", reason: "" }); }
      };
    }
    return { ok: true, status: 204, async text() { return ""; } };
  };
  vm.runInNewContext(
    fs.readFileSync(path.join(__dirname, "../js/backend.js"), "utf8"),
    { window, localStorage, sessionStorage, fetch, JSON, String, Number, Map, Date, encodeURIComponent }
  );
  return { api: window.ScrlBackend, calls, localStorage, sessionStorage };
}

test("profile login update does not erase the saved class", async () => {
  const { api, calls } = loadBackend();
  await api.saveProfile("profile-id", "Имя Фамилия", null, "signed-user-jwt");
  assert.match(calls[0].url, /functions\/v1\/scrl-moderation$/);
  assert.equal(JSON.parse(calls[0].options.body).kind, "profile");
  const patch = calls.find(call => call.url.includes("/rest/v1/profiles?"));
  assert.deepEqual(JSON.parse(patch.options.body), { full_name: "Имя Фамилия" });
});

test("profile form explicitly saves a class when one is supplied", async () => {
  const { api, calls } = loadBackend();
  await api.saveProfile("profile-id", "Имя Фамилия", "9А", "signed-user-jwt");
  const patch = calls.find(call => call.url.includes("/rest/v1/profiles?"));
  assert.deepEqual(JSON.parse(patch.options.body), { full_name: "Имя Фамилия", room: "9А" });
});

test("initial admin claim uses the email-bound server function", async () => {
  const { api, calls } = loadBackend();
  await api.claimInitialAdminForEmail();
  assert.match(calls[0].url, /rpc\/scrl_claim_initial_admin_for_email$/);
  assert.equal(calls[0].options.method, "POST");
  assert.equal(calls[0].options.body, "{}");
});

test("external AI requests use the user's JWT and don't require a browser API secret", async () => {
  const { api, calls } = loadBackend();
  await api.aiAssist("economy_report", { participants: 12, scRlTotal: 100 });
  assert.match(calls[0].url, /functions\/v1\/scrl-ai$/);
  assert.equal(calls[0].options.headers.Authorization, "Bearer signed-user-jwt");
  assert.equal(calls[0].options.headers.apikey, "sb_publishable_test");
  assert.equal(JSON.parse(calls[0].options.body).task, "economy_report");
});


test("all user-written content is moderated before its database write", async () => {
  const { api, calls } = loadBackend();
  await api.createPost({ type: "need", title: "Нужна помощь", description: "Описание", category: "Учёба", price: 0 });
  assert.match(calls[0].url, /functions\/v1\/scrl-moderation$/);
  assert.equal(JSON.parse(calls[0].options.body).kind, "post");
  assert.match(calls[1].url, /rpc\/scrl_create_post$/);

  calls.length = 0;
  await api.createListing({ title: "Репетиторство", description: "Помощь", category: "Учёба", price: 10, slots: 1 });
  assert.equal(JSON.parse(calls[0].options.body).kind, "listing");
  assert.match(calls[1].url, /rpc\/scrl_create_listing$/);

  calls.length = 0;
  await api.sendMessage("deal-1", "Привет, готов помочь");
  assert.equal(JSON.parse(calls[0].options.body).kind, "message");
  assert.match(calls[1].url, /rpc\/scrl_send_message$/);

  calls.length = 0;
  await api.createAuction({ title: "Конкурс", prize: "Книга", start: 10, step: 5, minutes: 60 });
  assert.equal(JSON.parse(calls[0].options.body).kind, "auction");
  assert.match(calls[1].url, /rpc\/scrl_create_auction$/);

  calls.length = 0;
  await api.createDeal({ title: "Заказ", buyer: "buyer", seller: "seller", amount: 1, source: "board", sourceId: "p1" });
  assert.equal(JSON.parse(calls[0].options.body).kind, "deal");
  assert.match(calls[1].url, /rpc\/scrl_create_deal$/);
});

test("reviews, reports, and teacher issuance are checked before insertion", async () => {
  const { api, calls } = loadBackend();
  await api.addReview({ deal: "d1", user: "u1", target: "u2", rating: 5, text: "Всё хорошо" });
  assert.equal(JSON.parse(calls[0].options.body).kind, "review");
  assert.match(calls[1].url, /\/rest\/v1\/reviews$/);

  calls.length = 0;
  await api.report({ kind: "post", target: "p1", user: "u1", reason: "spam", reasonCode: "spam", details: "проверить" });
  assert.equal(JSON.parse(calls[0].options.body).kind, "report");
  assert.match(calls[1].url, /\/rest\/v1\/reports$/);

  calls.length = 0;
  await api.issueTokens("u2", 5, "За помощь");
  assert.equal(JSON.parse(calls[0].options.body).kind, "teacher_issue");
  assert.match(calls[1].url, /rpc\/scrl_teacher_issue$/);
});

test("appeals use the signed-in JWT and do not depend on the Groq moderation key", async () => {
  const { api, calls } = loadBackend();
  await api.submitAppeal("ban-1", "Прошу пересмотреть решение");
  assert.match(calls[0].url, /functions\/v1\/scrl-moderation$/);
  assert.equal(JSON.parse(calls[0].options.body).action, "submit_appeal");
  assert.equal(calls[0].options.headers.Authorization, "Bearer signed-user-jwt");
});


test("profile names are moderated and account deletion invokes the protected Edge Function", async () => {
  const { api, calls } = loadBackend();
  await api.saveProfile("profile-id", "Новое ФИО", "9А", "signed-user-jwt");
  assert.match(calls[0].url, /functions\/v1\/scrl-moderation$/);
  assert.equal(JSON.parse(calls[0].options.body).kind, "profile");
  const patchIndex = calls.findIndex(call => call.url.includes("/rest/v1/profiles?"));
  assert.ok(patchIndex > 0);
  assert.deepEqual(JSON.parse(calls[patchIndex].options.body), { full_name: "Новое ФИО", room: "9А" });
  calls.length = 0;
  await api.deleteAccount("УДАЛИТЬ");
  assert.match(calls[0].url, /functions\/v1\/scrl-account$/);
  assert.equal(JSON.parse(calls[0].options.body).action, "delete_account");
  assert.equal(JSON.parse(calls[0].options.body).confirmation, "УДАЛИТЬ");
});



test("admin account deletion calls the protected account Edge Function with only the target ID", async () => {
  const { api, calls } = loadBackend();
  await api.adminDeleteUser("6d2d7e2a-9e94-4e0d-91f2-8bb84be070ad");
  assert.match(calls[0].url, /functions\/v1\/scrl-account$/);
  assert.equal(calls[0].options.headers.Authorization, "Bearer signed-user-jwt");
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    action: "delete_user",
    target_user_id: "6d2d7e2a-9e94-4e0d-91f2-8bb84be070ad"
  });
});

test("own post deletion uses the authenticated owner/admin RPC", async () => {
  const { api, calls } = loadBackend();
  await api.deletePost("6d2d7e2a-9e94-4e0d-91f2-8bb84be070ad");
  assert.match(calls[0].url, /rest\/v1\/rpc\/scrl_delete_publication$/);
  assert.equal(calls[0].options.headers.Authorization, "Bearer signed-user-jwt");
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    p_kind: "post",
    p_id: "6d2d7e2a-9e94-4e0d-91f2-8bb84be070ad"
  });
});


test("reading and clearing notifications use the user-scoped notification RPC", async () => {
  const { api, calls } = loadBackend();
  await api.markNotificationsRead();
  await api.clearNotifications();
  assert.equal(calls.length, 2);
  assert.match(calls[0].url, /rpc\/scrl_manage_my_notifications$/);
  assert.deepEqual(JSON.parse(calls[0].options.body), { p_action: "read" });
  assert.match(calls[1].url, /rpc\/scrl_manage_my_notifications$/);
  assert.deepEqual(JSON.parse(calls[1].options.body), { p_action: "clear" });
  assert.equal(calls[0].options.headers.Authorization, "Bearer signed-user-jwt");
  assert.equal(calls[1].options.headers.Authorization, "Bearer signed-user-jwt");
});

test("an expired REST session is refreshed and the failed request is retried", async () => {
  const { api, calls, localStorage, sessionStorage } = loadBackend({
    session: { id: "user-1", token: "expired-access", refreshToken: "refresh-old" },
    fetch: async (url, options) => {
      if (String(url).includes("/auth/v1/token?grant_type=refresh_token")) {
        return {
          ok: true, status: 200,
          async text() { return JSON.stringify({ access_token: "fresh-access", refresh_token: "refresh-new" }); }
        };
      }
      if (String(url).includes("/rpc/scrl_manage_my_notifications")) {
        if (options.headers.Authorization === "Bearer expired-access") {
          return { ok: false, status: 401, async text() { return JSON.stringify({ message: "JWT expired" }); } };
        }
        return { ok: true, status: 204, async text() { return ""; } };
      }
      return { ok: true, status: 204, async text() { return ""; } };
    }
  });

  await api.markNotificationsRead();
  assert.equal(calls.length, 3);
  assert.match(calls[0].url, /rpc\/scrl_manage_my_notifications$/);
  assert.match(calls[1].url, /auth\/v1\/token\?grant_type=refresh_token$/);
  assert.match(calls[2].url, /rpc\/scrl_manage_my_notifications$/);
  assert.equal(calls[2].options.headers.Authorization, "Bearer fresh-access");
  assert.deepEqual(JSON.parse(localStorage.getItem("scrlSession")), {
    id: "user-1", token: "fresh-access", refreshToken: "refresh-new"
  });
  assert.equal(sessionStorage.getItem("scrlSession"), null);
});

test("an expired Edge Function session is refreshed and retried with the new JWT", async () => {
  const { api, calls, localStorage, sessionStorage } = loadBackend({
    session: { id: "user-2", token: "expired-access", refreshToken: "refresh-old" },
    fetch: async (url, options) => {
      if (String(url).includes("/auth/v1/token?grant_type=refresh_token")) {
        return {
          ok: true, status: 200,
          async text() { return JSON.stringify({ access_token: "fresh-edge-access", refresh_token: "refresh-edge-new" }); }
        };
      }
      if (String(url).includes("/functions/v1/scrl-account")) {
        if (options.headers.Authorization === "Bearer expired-access") {
          return { ok: false, status: 401, async text() { return JSON.stringify({ message: "JWT expired" }); } };
        }
        return { ok: true, status: 200, async text() { return JSON.stringify({ success: true }); } };
      }
      return { ok: true, status: 204, async text() { return ""; } };
    }
  });

  await api.adminDeleteUser("6d2d7e2a-9e94-4e0d-91f2-8bb84be070ad");
  assert.equal(calls.length, 3);
  assert.match(calls[1].url, /auth\/v1\/token\?grant_type=refresh_token$/);
  assert.equal(calls[2].options.headers.Authorization, "Bearer fresh-edge-access");
  assert.deepEqual(JSON.parse(localStorage.getItem("scrlSession")), {
    id: "user-2", token: "fresh-edge-access", refreshToken: "refresh-edge-new"
  });
  assert.equal(sessionStorage.getItem("scrlSession"), null);
});


test("a refresh-token race in another tab keeps the newer shared session", async () => {
  const { api, calls, localStorage } = loadBackend({
    session: { id: "user-3", token: "expired-access", refreshToken: "refresh-old" },
    fetch: async (url, options, storage) => {
      if (String(url).includes("/auth/v1/token?grant_type=refresh_token")) {
        storage.localStorage.setItem("scrlSession", JSON.stringify({
          id: "user-3", token: "fresh-from-other-tab", refreshToken: "refresh-rotated"
        }));
        return { ok: false, status: 400, async text() { return JSON.stringify({ message: "refresh token already used" }); } };
      }
      if (String(url).includes("/rpc/scrl_manage_my_notifications")) {
        if (options.headers.Authorization === "Bearer expired-access") {
          return { ok: false, status: 401, async text() { return JSON.stringify({ message: "JWT expired" }); } };
        }
        return { ok: true, status: 204, async text() { return ""; } };
      }
      return { ok: true, status: 204, async text() { return ""; } };
    }
  });

  await api.markNotificationsRead();
  assert.equal(calls.length, 3);
  assert.equal(calls[2].options.headers.Authorization, "Bearer fresh-from-other-tab");
  assert.deepEqual(JSON.parse(localStorage.getItem("scrlSession")), {
    id: "user-3", token: "fresh-from-other-tab", refreshToken: "refresh-rotated"
  });
});

test("403 from database preserves the actual rejection reason", async () => {
  const { api } = loadBackend({
    fetch: async () => ({
      ok: false,
      status: 403,
      async text() {
        return JSON.stringify({ message: "Сначала прими актуальное согласие на обработку персональных данных и ИИ-проверку." });
      }
    })
  });
  await assert.rejects(
    () => api.markNotificationsRead(),
    /Сначала прими актуальное согласие на обработку персональных данных и ИИ-проверку/
  );
});
