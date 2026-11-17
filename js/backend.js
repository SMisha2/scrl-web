/* ScRl shared backend client. Uses only Supabase publishable key + the signed-in user's JWT. */
(function (root) {
  "use strict";
  const cfg = root.cfg || {};

  function tokenFromSession() {
    try { return JSON.parse(sessionStorage.getItem("scrlSession") || "null")?.token || ""; }
    catch { return ""; }
  }

  function baseUrl() {
    const value = String(cfg.url || "").replace(/\/$/, "");
    if (!value || !cfg.key) throw new Error("Сервер ScRl не настроен. Обнови страницу или сообщи администратору сайта.");
    return value;
  }

  async function request(path, options = {}, explicitToken = "") {
    const token = explicitToken || tokenFromSession();
    if (!token) throw new Error("Сессия закончилась. Войди в аккаунт ещё раз.");
    const headers = {
      apikey: cfg.key,
      Authorization: "Bearer " + token,
      Accept: "application/json"
    };
    if (options.body !== undefined) headers["Content-Type"] = "application/json";
    if (options.prefer) headers.Prefer = options.prefer;
    const response = await fetch(baseUrl() + path, {
      method: options.method || "GET",
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body)
    });
    const raw = await response.text();
    let payload = null;
    if (raw) {
      try { payload = JSON.parse(raw); }
      catch { payload = raw; }
    }
    if (!response.ok) {
      const message = payload && typeof payload === "object"
        ? (payload.message || payload.msg || payload.error_description || payload.details || payload.hint)
        : payload;
      if (response.status === 401) throw new Error("Сессия истекла. Войди в ScRl заново.");
      if (response.status === 403) throw new Error("Недостаточно прав для этой операции.");
      throw new Error(String(message || "Ошибка сервера ScRl (" + response.status + ")."));
    }
    return payload;
  }

  async function edgeFunction(name, body, explicitToken = "") {
    const token = explicitToken || tokenFromSession();
    if (!token) throw new Error("Сессия закончилась. Войди в аккаунт ещё раз.");
    const response = await fetch(baseUrl() + "/functions/v1/" + encodeURIComponent(name), {
      method: "POST",
      headers: {
        apikey: cfg.key,
        Authorization: "Bearer " + token,
        "Content-Type": "application/json",
        Accept: "application/json"
      },
      body: JSON.stringify(body || {})
    });
    const raw = await response.text();
    let payload = null;
    if (raw) {
      try { payload = JSON.parse(raw); } catch { payload = { message: raw }; }
    }
    if (!response.ok) {
      if (payload && typeof payload === "object" && payload.banned) {
        throw new Error("Аккаунт заблокирован ИИ-модерацией. Обнови страницу, чтобы открыть форму апелляции.");
      }
      const message = payload && typeof payload === "object"
        ? (payload.error || payload.message || payload.msg || payload.reason)
        : payload;
      throw new Error(String(message || "Внешний сервис ScRl временно недоступен (" + response.status + ")."));
    }
    return payload;
  }

  function table(name, query = "select=*", token = "") {
    return request("/rest/v1/" + name + "?" + query, {}, token);
  }

  function rpc(name, args = {}) {
    return request("/rest/v1/rpc/" + name, { method: "POST", body: args });
  }

  async function moderationCheck(kind, payload, token = "") {
    const result = await edgeFunction("scrl-moderation", { action: "check", kind, payload }, token);
    if (!result || result.allowed !== true) {
      if (result && result.banned) throw new Error("Аккаунт заблокирован ИИ-модерацией. Обнови страницу для подачи апелляции.");
      throw new Error((result && result.reason) || "Содержимое остановлено модерацией и отправлено на проверку.");
    }
    return result;
  }

  const time = value => {
    const date = value ? new Date(value).getTime() : Date.now();
    return Number.isFinite(date) ? date : Date.now();
  };

  async function load(token, currentUserId, email) {
    const tables = [
      ["profiles", "select=id,full_name,room,role,blocked,created_at&order=full_name.asc"],
      ["wallets", "select=user_id,scrl,vrub,hold_scrl,hold_vrub"],
      ["ledger", "select=id,user_id,currency,delta,note,created_at&order=created_at.desc&limit=1000"],
      ["posts", "select=*&order=created_at.desc&limit=1000"],
      ["listings", "select=*&order=created_at.desc&limit=1000"],
      ["deals", "select=*&order=created_at.desc&limit=1000"],
      ["deal_messages", "select=*&order=created_at.asc&limit=2000"],
      ["exchange_orders", "select=*&order=created_at.desc&limit=1000"],
      ["trades", "select=*&order=created_at.desc&limit=1000"],
      ["auctions", "select=*&order=created_at.desc&limit=1000"],
      ["bids", "select=*&order=created_at.desc&limit=2000"],
      ["favorites", "select=*"],
      ["reports", "select=*&order=created_at.desc&limit=1000"],
      ["notifications", "select=*&order=created_at.desc&limit=500"],
      ["reviews", "select=*&order=created_at.desc&limit=1000"],
      ["activity", "select=*&order=created_at.desc&limit=200"],
      ["audit", "select=*&order=created_at.desc&limit=200"],
      ["teacher_issuance", "select=*"],
      ["platform_settings", "select=*"]
    ];

    const [result, economy] = await Promise.all([
      Promise.all(tables.map(([name, query]) => table(name, query, token))),
      request("/rest/v1/rpc/scrl_economy_snapshot", { method: "POST", body: {} }, token)
    ]);
    let moderation = {
      activeBan: null, appeals: [], cases: [], blocked: false, admin: false,
      adminCases: [], adminAppeals: [], unavailable: false
    };
    try {
      moderation = await edgeFunction("scrl-moderation", { action: "my_status" }, token) || moderation;
    } catch (error) {
      moderation.unavailable = true;
      moderation.error = error && error.message ? error.message : "Состояние модерации пока недоступно.";
    }
    const rows = Object.fromEntries(tables.map(([name], index) => [name, Array.isArray(result[index]) ? result[index] : []]));
    const wallets = new Map(rows.wallets.map(row => [row.user_id, row]));
    const profiles = rows.profiles.map(row => {
      const wallet = wallets.get(row.id) || {};
      return {
        id: row.id,
        name: row.full_name,
        mail: row.id === currentUserId ? (email || "") : "",
        role: row.role,
        room: row.room || "",
        scrl: Number(wallet.scrl || 0),
        vrub: Number(wallet.vrub || 0),
        holdScrl: Number(wallet.hold_scrl || 0),
        holdVrub: Number(wallet.hold_vrub || 0),
        blocked: Boolean(row.blocked),
        blockReason: ""
      };
    });
    const nameById = new Map(profiles.map(user => [user.id, user.name]));
    const messagesByDeal = new Map();
    rows.deal_messages.forEach(row => {
      const item = {
        user: row.user_id,
        text: row.message,
        status: row.status || "active",
        date: time(row.created_at)
      };
      if (!messagesByDeal.has(row.deal_id)) messagesByDeal.set(row.deal_id, []);
      messagesByDeal.get(row.deal_id).push(item);
    });
    const settings = rows.platform_settings[0] || {};
    const totalTokens = profiles.reduce((sum, user) => sum + user.scrl + user.holdScrl, 0);
    const totalVrub = profiles.reduce((sum, user) => sum + user.vrub + user.holdVrub, 0);
    const coverage = totalTokens > 0 && Number(settings.target_rate || 0.05) > 0
      ? totalVrub / (totalTokens * Number(settings.target_rate || 0.05)) : 0;
    const fee = coverage < 1 ? Math.min(0.2, Math.max(0, 0.005 + (1 - coverage) * 0.2))
      : coverage < 2 ? Math.max(0, 0.005 * (2 - coverage)) : 0;

    const data = {
      users: profiles,
      moderation,
      posts: rows.posts.map(row => ({
        id: row.id, type: row.type, title: row.title, desc: row.description,
        category: row.category, price: Number(row.price), user: row.owner_id,
        status: row.status, date: time(row.created_at)
      })),
      listings: rows.listings.map(row => ({
        id: row.id, title: row.title, desc: row.description, category: row.category,
        price: Number(row.price), user: row.owner_id, slots: Number(row.slots),
        status: row.status, date: time(row.created_at)
      })),
      deals: rows.deals.map(row => ({
        id: row.id, title: row.title, buyer: row.buyer_id, seller: row.seller_id,
        amount: Number(row.amount), escrow: Number(row.escrow), from: row.source,
        sourceId: row.source_id, status: row.status, messages: messagesByDeal.get(row.id) || [],
        date: time(row.created_at), closed: row.closed_at ? time(row.closed_at) : 0
      })),
      book: [],
      exchangeOrders: rows.exchange_orders.map(row => ({
        id: row.id, side: row.side, user: row.owner_id, amount: Number(row.amount),
        price: Number(row.price), status: row.status, buyer: row.buyer_id || "",
        date: time(row.created_at), filledAt: row.filled_at ? time(row.filled_at) : 0,
        cancelledAt: row.cancelled_at ? time(row.cancelled_at) : 0
      })),
      trades: rows.trades.map(row => ({
        id: row.id, buyer: row.buyer_id, seller: row.seller_id,
        qty: Number(row.qty), price: Number(row.price), amountScRl: Number(row.amount_scrl),
        amountVrub: Number(row.amount_vrub), fee: Number(row.fee), date: time(row.created_at)
      })),
      auctions: rows.auctions.map(row => ({
        id: row.id, title: row.title, prize: row.prize, startPrice: Number(row.start_price),
        step: Number(row.step), bid: Number(row.current_bid), leader: row.leader_id || "",
        owner: row.owner_id, ends: time(row.ends_at), status: row.status,
        bids: Number(row.bids_count), created: time(row.created_at),
        closed: row.closed_at ? time(row.closed_at) : 0
      })),
      bids: rows.bids.map(row => ({
        id: row.id, auction: row.auction_id, user: row.user_id, amount: Number(row.amount),
        status: row.status, date: time(row.created_at)
      })),
      ledger: rows.ledger.map(row => ({
        id: row.id, user: row.user_id, currency: row.currency,
        delta: Number(row.delta), note: row.note, date: time(row.created_at)
      })),
      favorites: rows.favorites.map(row => ({ user: row.user_id, kind: row.kind, id: row.target_id })),
      reviews: rows.reviews.map(row => ({
        id: row.id, deal: row.deal_id, user: row.user_id, target: row.target_id,
        rating: Number(row.rating), text: row.text, status: row.status || "active", date: time(row.created_at)
      })),
      reports: rows.reports.map(row => ({
        id: row.id, kind: row.kind, target: row.target_id, user: row.reporter_id,
        reason: row.reason, reasonCode: row.reason_code, details: row.details,
        status: row.status, date: time(row.created_at)
      })),
      notices: rows.notifications.map(row => ({
        id: row.id, user: row.user_id, text: row.message, seen: Boolean(row.seen),
        date: time(row.created_at)
      })),
      activity: rows.activity.map(row => ({
        id: row.id, user: row.user_id, text: row.message, date: time(row.created_at)
      })),
      audit: rows.audit.map(row => ({
        id: row.id, user: row.actor_id, text: row.message, date: time(row.created_at)
      })),
      teacherUsed: {},
      fees: Number(economy?.fees ?? settings.fees_scrl ?? 0),
      burned: Number(economy?.burned ?? settings.burned_scrl ?? 0),
      rate: Number(economy?.rate ?? settings.target_rate ?? 0.05),
      fee: Number(economy?.fee ?? fee),
      economy: {
        tokens: Number(economy?.tokens || 0),
        vrub: Number(economy?.vrub || 0),
        rate: Number(economy?.rate || settings.target_rate || 0.05),
        fee: Number(economy?.fee || 0),
        ratio: Number(economy?.ratio || 0),
        limit: Number(economy?.limit || 0)
      },
      moneyOps: [],
      aiMessages: []
    };
    rows.teacher_issuance.forEach(row => {
      data.teacherUsed[row.teacher_id + ":" + String(row.week_start).slice(0, 10)] = Number(row.amount || 0);
    });
    return data;
  }

  const api = {
    load,
    rpc,
    async saveProfile(id, name, room = null, token = "") {
      await moderationCheck("profile", { full_name: String(name || "").trim() }, token);
      const body = { full_name: name };
      if (room !== null && room !== undefined) body.room = room;
      return request("/rest/v1/profiles?id=eq." + encodeURIComponent(id), {
        method: "PATCH", body, prefer: "return=minimal"
      }, token);
    },
    async createPost(payload) {
      await moderationCheck("post", {
        type: payload.type,
        title: String(payload.title || "").trim(),
        description: String(payload.description || "").trim(),
        category: String(payload.category || "Другое").trim() || "Другое",
        price: Number(payload.price)
      });
      return rpc("scrl_create_post", {
        p_type: payload.type, p_title: payload.title, p_description: payload.description,
        p_category: payload.category, p_price: payload.price
      });
    },
    async createListing(payload) {
      await moderationCheck("listing", {
        title: String(payload.title || "").trim(),
        description: String(payload.description || "").trim(),
        category: String(payload.category || "Другое").trim() || "Другое",
        price: Number(payload.price), slots: Number(payload.slots)
      });
      return rpc("scrl_create_listing", {
        p_title: payload.title, p_description: payload.description,
        p_category: payload.category, p_price: payload.price, p_slots: payload.slots
      });
    },
    closePublication(kind, id) {
      return rpc("scrl_close_publication", { p_kind: kind, p_id: id });
    },
    async createDeal(payload) {
      await moderationCheck("deal", { title: String(payload.title || "").trim() });
      return rpc("scrl_create_deal", {
        p_title: payload.title, p_buyer: payload.buyer, p_seller: payload.seller,
        p_amount: payload.amount, p_source: payload.source, p_source_id: payload.sourceId
      });
    },
    dealAction(id, action, share = 1) {
      return rpc("scrl_deal_action", { p_deal: id, p_action: action, p_share: share });
    },
    resolveDispute(id, action, share = 0.5) {
      return rpc("scrl_admin_resolve_dispute", { p_deal: id, p_action: action, p_share: share });
    },
    async sendMessage(id, message) {
      const text = String(message || "").trim();
      const moderation = await moderationCheck("message", { deal_id: String(id), message: text });
      const result = await rpc("scrl_send_message", { p_deal: id, p_message: text });
      return { id: result, moderation };
    },
    placeExchangeOrder(side, amount, price) {
      return rpc("scrl_place_exchange_order", { p_side: side, p_amount: amount, p_price: price });
    },
    buyExchangeOrder(id) {
      return rpc("scrl_buy_exchange_order", { p_order: id });
    },
    cancelExchangeOrder(id) {
      return rpc("scrl_cancel_exchange_order", { p_order: id });
    },
    async createAuction(payload) {
      await moderationCheck("auction", {
        title: String(payload.title || "").trim(), prize: String(payload.prize || "").trim(),
        start_price: Number(payload.start), step: Number(payload.step)
      });
      return rpc("scrl_create_auction", {
        p_title: payload.title, p_prize: payload.prize, p_start: payload.start,
        p_step: payload.step, p_minutes: payload.minutes
      });
    },
    placeBid(id, amount) {
      return rpc("scrl_place_bid", { p_auction: id, p_amount: amount });
    },
    finishAuction(id) {
      return rpc("scrl_finish_auction", { p_auction: id });
    },
    async issueTokens(student, amount, reason) {
      await moderationCheck("teacher_issue", {
        student_id: String(student), amount: Number(amount),
        reason: String(reason || "Другое").trim().slice(0, 120)
      });
      return rpc("scrl_teacher_issue", { p_student: student, p_amount: amount, p_reason: reason });
    },
    adminSetUser(id, action, reason = "", room = "") {
      return rpc("scrl_admin_set_user", { p_target: id, p_action: action, p_reason: reason, p_room: room });
    },
    adminModerate(kind, target, action) {
      return rpc("scrl_admin_moderate", { p_kind: kind, p_target: target, p_action: action });
    },
    adminUpdateEconomy(rate) {
      return rpc("scrl_admin_update_economy", { p_rate: rate });
    },
    scanPublications() {
      return rpc("scrl_scan_publications", {});
    },
    markNotificationsRead() {
      return rpc("scrl_mark_notifications_read", {});
    },
    logSelf(message) {
      return rpc("scrl_log_self", { p_message: message });
    },
    async report(payload) {
      const body = {
        kind: payload.kind, target_id: String(payload.target), reporter_id: payload.user,
        reason: payload.reason, reason_code: payload.reasonCode || "other",
        details: String(payload.details || "").trim().slice(0, 180), status: "open"
      };
      await moderationCheck("report", {
        kind: body.kind, target_id: body.target_id, reason: body.reason,
        reason_code: body.reason_code, details: body.details
      });
      return request("/rest/v1/reports", {
        method: "POST", body, prefer: "return=minimal"
      });
    },
    async toggleFavorite(user, kind, id, exists) {
      const query = "user_id=eq." + encodeURIComponent(user) + "&kind=eq." +
        encodeURIComponent(kind) + "&target_id=eq." + encodeURIComponent(id);
      if (exists) return request("/rest/v1/favorites?" + query, { method: "DELETE", prefer: "return=minimal" });
      return request("/rest/v1/favorites", {
        method: "POST",
        body: { user_id: user, kind, target_id: String(id) },
        prefer: "return=minimal"
      });
    },
    async addReview(payload) {
      const body = {
        deal_id: payload.deal, user_id: payload.user, target_id: payload.target,
        rating: Number(payload.rating), text: String(payload.text || "").trim()
      };
      await moderationCheck("review", {
        deal_id: String(body.deal_id), target_id: String(body.target_id),
        rating: body.rating, text: body.text
      });
      return request("/rest/v1/reviews", {
        method: "POST", body, prefer: "return=minimal"
      });
    },
    updateProfile(id, name, room, token = "") {
      return this.saveProfile(id, name, room, token);
    },
    claimInitialAdminForEmail() {
      return rpc("scrl_claim_initial_admin_for_email", {});
    },
    submitAppeal(banId, reason) {
      return edgeFunction("scrl-moderation", { action: "submit_appeal", ban_id: banId, reason });
    },
    adminReviewCase(caseId, decision) {
      return edgeFunction("scrl-moderation", { action: "admin_review_case", case_id: caseId, decision });
    },
    adminReviewAppeal(appealId, decision, note = "") {
      return edgeFunction("scrl-moderation", { action: "admin_review_appeal", appeal_id: appealId, decision, note });
    },
    aiAssist(task, metrics) {
      return edgeFunction("scrl-ai", { task, metrics });
    }
  };
  root.ScrlBackend = api;
})(window);
