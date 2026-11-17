const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function loadBackend() {
  const calls = [];
  const window = { cfg: { url: "https://scrl-test.supabase.co", key: "sb_publishable_test" } };
  const sessionStorage = {
    getItem(key) { return key === "scrlSession" ? JSON.stringify({ token: "signed-user-jwt" }) : null; }
  };
  const fetch = async (url, options) => {
    calls.push({ url, options });
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
    { window, sessionStorage, fetch, JSON, String, Number, Map, Date, encodeURIComponent }
  );
  return { api: window.ScrlBackend, calls };
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
