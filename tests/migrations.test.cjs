const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const migrationDir = path.join(__dirname, "../supabase/migrations");
const migrationFiles = fs.readdirSync(migrationDir)
  .filter(name => name.endsWith(".sql"))
  .sort();

test("all production migrations remain versioned and tracked", () => {
  assert.ok(
    migrationFiles.length >= 36,
    `Expected at least 36 tracked migrations, found ${migrationFiles.length}`
  );

  const versions = migrationFiles.map(name => {
    const match = name.match(/^(\d{14})_[a-z0-9_]+\.sql$/);
    assert.ok(match, `Invalid migration filename: ${name}`);
    return match[1];
  });

  assert.equal(new Set(versions).size, versions.length, "Migration versions must be unique");
  assert.deepEqual(versions, [...versions].sort(), "Migration files must remain in version order");

  for (const name of migrationFiles) {
    const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
    assert.ok(sql.trim().length > 0, `Migration is empty: ${name}`);
  }

  assert.ok(migrationFiles.includes("20261116005525_create_secure_scrl_application_backend.sql"));
  assert.ok(migrationFiles.includes("20261117073253_require_admin_parent_consent_verification_note.sql"));
});

test("notification RPC updates and deletes only the signed-in user's rows", () => {
  const name = "20261120120000_add_secure_mark_notifications_read_rpc.sql";
  const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
  assert.match(sql, /IF v_action IN \('read', 'mark_read', 'mark_all_read', 'read_all'\) THEN/i);
  assert.match(sql, /ELSIF v_action IN \('clear', 'delete', 'clear_all', 'delete_all'\) THEN/i);
  assert.equal((sql.match(/WHERE user_id = auth\.uid\(\)/gi) || []).length, 2);
  assert.match(sql, /SECURITY DEFINER[\s\S]*?SET search_path = public, auth, pg_temp/i);
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.scrl_manage_my_notifications\(text\) FROM PUBLIC, anon/i);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\.scrl_manage_my_notifications\(text\) TO authenticated/i);
});


test("every frontend RPC call has a tracked SQL function definition", () => {
  const backend = fs.readFileSync(path.join(__dirname, "../js/backend.js"), "utf8");
  const sql = migrationFiles
    .map(name => fs.readFileSync(path.join(migrationDir, name), "utf8"))
    .join("\n");

  const calls = new Set([
    ...[...backend.matchAll(/\brpc\(\s*["'`](scrl_[a-z0-9_]+)["'`]/g)].map(match => match[1]),
    ...[...backend.matchAll(/request\(\s*["'`]\/rest\/v1\/rpc\/(scrl_[a-z0-9_]+)/g)].map(match => match[1])
  ]);
  const missing = [...calls].filter(name =>
    !new RegExp("CREATE\\s+(?:OR\\s+REPLACE\\s+)?FUNCTION\\s+public\\." + name + "\\s*\\(", "i").test(sql)
  );
  assert.deepEqual(missing, [], "Untracked SQL RPC definitions: " + missing.join(", "));
});


test("deal settlement refuses missing escrow and locks participant wallets before paying", () => {
  const name = "20261121100000_harden_deal_escrow_settlement.sql";
  const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
  assert.match(sql, /PERFORM w\.user_id[\s\S]*?ORDER BY w\.user_id[\s\S]*?FOR UPDATE/i);
  assert.match(sql, /IF v_buyer_wallet\.hold_scrl < v_deal\.escrow THEN/i);
  assert.match(sql, /SET hold_scrl = hold_scrl - v_deal\.escrow/i);
  assert.doesNotMatch(sql, /hold_scrl\s*=\s*greatest/i);
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.scrl_deal_action\(uuid, text, numeric\) FROM PUBLIC, anon/i);
});

test("SECURITY DEFINER functions pin their search_path", () => {
  for (const name of migrationFiles) {
    const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
    const functions = [...sql.matchAll(
      /CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\b[\s\S]*?\bAS\s+(\$[a-z_]*\$|\$\$)[\s\S]*?\1\s*;/gi
    )].map(match => match[0]);

    for (const definition of functions) {
      if (/\bSECURITY\s+DEFINER\b/i.test(definition)) {
        assert.match(
          definition,
          /\bSET\s+search_path\b/i,
          `SECURITY DEFINER function without fixed search_path in ${name}`
        );
      }
    }
  }
});


test("ordinary user management cannot demote or modify administrator profiles", () => {
  const name = "20261121103000_protect_admin_profiles_from_user_management.sql";
  const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
  const adminGuard = sql.indexOf("IF v_user.role = 'admin' THEN");
  const firstMutation = sql.indexOf("IF p_action = 'teacher'");

  assert.ok(adminGuard >= 0, "The SQL function must reject administrator targets");
  assert.ok(firstMutation > adminGuard, "The administrator guard must run before role changes");
  assert.ok(sql.includes("Профили администраторов нельзя изменять через управление участниками."));
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.scrl_admin_set_user\(uuid, text, text, text\) FROM PUBLIC, anon/i);
});


test("active administrators can use the exchange without the parent-consent gate", () => {
  const name = "20261121104500_allow_admin_exchange_access.sql";
  const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
  const adminBranch = sql.indexOf("p.role = 'admin'");
  const ageGate = sql.indexOf("s.birth_date <= current_date");

  assert.ok(adminBranch >= 0, "Active admin role must be explicitly allowed");
  assert.ok(ageGate > adminBranch, "Admin bypass must be evaluated independently of participant age checks");
  assert.ok(sql.includes("p.deleted_at IS NULL"));
  assert.ok(sql.includes("p.blocked = false"));
  assert.ok(sql.includes("s.parent_exchange_status = 'approved'"));
  assert.ok(sql.includes("GRANT EXECUTE ON FUNCTION private.scrl_user_can_exchange(uuid) TO authenticated"));
});


test("moderation case and appeal decisions are atomic and cannot be processed twice", () => {
  const name = "20261124190000_make_moderation_reviews_atomic.sql";
  const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
  const cases = sql.slice(sql.indexOf("FUNCTION public.scrl_moderation_admin_resolve_case"));
  const appeals = sql.slice(sql.indexOf("FUNCTION public.scrl_moderation_admin_resolve_appeal"));

  const caseLock = cases.indexOf("WHERE id = p_case_id");
  const appealLock = appeals.indexOf("WHERE id = p_appeal_id");
  assert.ok(caseLock >= 0 && cases.indexOf("FOR UPDATE", caseLock) > caseLock);
  assert.ok(appealLock >= 0 && appeals.indexOf("FOR UPDATE", appealLock) > appealLock);
  assert.ok(cases.includes("v_case.status <> 'pending'"));
  assert.ok(cases.includes("NOT EXISTS ("));
  assert.ok(cases.includes("scrl_moderation_bans"));
  assert.ok(cases.includes("source_id IS NOT NULL"));
  assert.ok(cases.includes("INSERT INTO public.notifications"));
  assert.ok(cases.includes("UPDATE public.scrl_moderation_appeals"));
  assert.ok(cases.includes("Дело восстановлено администратором."));
  assert.ok(appeals.includes("v_appeal.status <> 'pending'"));
  assert.ok(appeals.includes("v_ban.active = false"));
  assert.ok(appeals.includes("UPDATE public.scrl_moderation_cases"));
  assert.ok(appeals.includes("appeal_accepted"));
  assert.ok(appeals.includes("appeal_rejected"));
  assert.ok(appeals.includes("NOT EXISTS ("));
  assert.ok(appeals.includes("scrl_moderation_bans"));
  assert.ok(sql.includes("GRANT EXECUTE ON FUNCTION public.scrl_moderation_admin_resolve_case(uuid, uuid, text) TO service_role"));
  assert.ok(sql.includes("GRANT EXECUTE ON FUNCTION public.scrl_moderation_admin_resolve_appeal(uuid, uuid, text, text) TO service_role"));

  const edge = fs.readFileSync(path.join(__dirname, "../supabase/functions/scrl-moderation/index.ts"), "utf8");
  assert.ok(edge.includes('rpc("rpc/scrl_moderation_admin_resolve_case"') || edge.includes('"rpc/scrl_moderation_admin_resolve_case"'));
  assert.ok(edge.includes("rpc/scrl_moderation_admin_resolve_appeal"));
  assert.ok(!edge.includes('rest("scrl_moderation_cases?id=eq."'));
});

test("external AI consent is separate, optional and revocable", () => {
  const name = "20261124185600_separate_ai_consent_and_enable_manual_review.sql";
  const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
  assert.ok(sql.includes("ALTER COLUMN ai_moderation_consent_at DROP NOT NULL"));
  assert.ok(sql.includes("ALTER COLUMN ai_moderation_consent_version DROP NOT NULL"));
  assert.ok(sql.includes("ADD COLUMN IF NOT EXISTS revoked_at timestamptz"));
  assert.ok(sql.includes("IF p_ai_consent IS TRUE AND p_ai_version IS DISTINCT FROM '2026-11-17-v2'"));
  assert.ok(sql.includes("SET revoked_at = coalesce(revoked_at, v_now)"));
  assert.ok(sql.includes("'needsOnboarding', (v_row.birth_date IS NULL OR NOT v_personal_ok)"));
  assert.ok(sql.includes("p.role = 'admin'"));
  assert.ok(sql.includes("CHECK (status IN ('active', 'review', 'done', 'settlementError'))"));

  const consentGuard = sql.slice(sql.indexOf("FUNCTION private.scrl_require_user_consents"));
  assert.ok(consentGuard.includes("personal_data_consent_version = '2026-11-17-v1'"));
  assert.ok(!consentGuard.includes("ai_moderation_consent_at"));
});

test("manual moderation avoids external processing without consent and keeps financial actions fail-closed", () => {
  const edge = fs.readFileSync(path.join(__dirname, "../supabase/functions/scrl-moderation/index.ts"), "utf8");
  assert.ok(edge.includes('rpc("rpc/scrl_has_ai_processing_consent"') || edge.includes('"rpc/scrl_has_ai_processing_consent"'));
  assert.ok(edge.includes("const useExternalAI=providerEnabled&&aiConsent"));
  assert.ok(edge.includes('categories:["manual_review"]'));
  assert.ok(edge.includes('manualReview&&["deal","teacher_issue"].includes(kind)'));
  assert.ok(edge.includes("moderation_admin_resolve_case"));

  const sql = fs.readFileSync(path.join(migrationDir, "20261124185600_separate_ai_consent_and_enable_manual_review.sql"), "utf8");
  assert.ok(sql.includes("IF v_status = 'active' THEN"));
  assert.ok(sql.includes("scrl_send_message(uuid, text)"));
});


test("automatic moderation bans update the ban, profile, notification and audit atomically", () => {
  const name = "20261124192000_make_automatic_moderation_bans_atomic.sql";
  const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
  assert.ok(sql.includes("pg_advisory_xact_lock"));
  assert.ok(sql.includes("v_case.status <> 'pending'"));
  assert.ok(sql.includes("v_case.decision <> 'ban'"));
  assert.ok(sql.includes("v_case.severity <> 'critical'"));
  assert.ok(sql.includes("v_case.confidence < 0.98"));
  assert.ok(sql.includes("sexual_exploitation_or_grooming"));
  assert.ok(sql.includes("UPDATE public.profiles"));
  assert.ok(sql.includes("INSERT INTO public.scrl_moderation_bans"));
  assert.ok(sql.includes("INSERT INTO public.notifications"));
  assert.ok(sql.includes("INSERT INTO public.audit"));
  assert.ok(sql.includes("role <> 'admin'"));
  assert.ok(sql.includes("public.deals"));
  assert.ok(sql.includes("public.exchange_orders"));
  assert.ok(sql.includes("public.auctions"));
  assert.ok(sql.includes("UPDATE public.scrl_moderation_cases"));
  assert.ok(sql.includes("RETURN NULL"));
  assert.ok(sql.includes("GRANT EXECUTE ON FUNCTION public.scrl_moderation_issue_automatic_ban(uuid, uuid, text, timestamptz) TO service_role"));

  const edge = fs.readFileSync(path.join(__dirname, "../supabase/functions/scrl-moderation/index.ts"), "utf8");
  assert.ok(edge.includes("rpc/scrl_moderation_issue_automatic_ban"));
  assert.ok(edge.includes('profile.role!=="admin"'));
  assert.ok(edge.includes("if(!banId)"));
  assert.ok(edge.includes("у участника есть активные финансовые операции"));
});


test("all money releases preserve aggregate ScRl and V-RUB reserves across deals, exchange and auctions", () => {
  const name = "20261124193000_check_aggregate_wallet_reserves.sql";
  const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
  assert.ok(sql.includes("FUNCTION private.scrl_required_scrl_holds"));
  assert.ok(sql.includes("FUNCTION private.scrl_required_vrub_holds"));
  assert.ok(sql.includes("public.deals AS d"));
  assert.ok(sql.includes("public.exchange_orders AS o"));
  assert.ok(sql.includes("public.auctions AS a"));
  assert.ok(sql.includes("status IN ('active', 'settlementError')"));

  const deal = sql.slice(sql.indexOf("FUNCTION public.scrl_deal_action"));
  const buy = sql.slice(sql.indexOf("FUNCTION public.scrl_buy_exchange_order"));
  const cancel = sql.slice(sql.indexOf("FUNCTION public.scrl_cancel_exchange_order"));
  const bid = sql.slice(sql.indexOf("FUNCTION public.scrl_place_bid"));
  const finish = sql.slice(sql.toLowerCase().indexOf("function public.scrl_finish_auction"));
  for (const [name, source] of [["deal", deal], ["buy", buy], ["cancel", cancel], ["bid", bid], ["finish", finish]]) {
    assert.ok(source.includes("scrl_required_scrl_holds"), name + " must validate ScRl liabilities");
  }
  assert.ok(buy.includes("scrl_required_vrub_holds"));
  assert.ok(cancel.includes("scrl_required_vrub_holds"));
  assert.ok(finish.toLowerCase().includes("set status='settlementerror'"));
  assert.ok(finish.toLowerCase().includes("return;"));
});


test("pre-write approvals create short-lived one-use retry tickets and pending messages stay private", () => {
  const migration = fs.readFileSync(path.join(migrationDir, "20261124201030_add_manual_review_retry_permits_and_hide_pending_messages.sql"), "utf8");
  assert.match(migration, /user_id = \(SELECT auth\.uid\(\)\)/);
  assert.match(migration, /status = 'active'[\s\S]*?AND EXISTS/);
  assert.match(migration, /source_table <> 'prewrite'/);
  assert.match(migration, /decision = 'allow'/);
  assert.match(migration, /manual_approved/);
  assert.match(migration, /v_now \+ interval '30 minutes'/);
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.scrl_moderation_admin_resolve_prewrite_case/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.scrl_moderation_admin_resolve_prewrite_case[\s\S]*TO service_role/);

  const edge = fs.readFileSync(path.join(__dirname, "../supabase/functions/scrl-moderation/index.ts"), "utf8");
  assert.ok(edge.includes("findManualRetryPermit"));
  assert.ok(edge.includes("scrl_moderation_admin_resolve_prewrite_case"));
  assert.ok(edge.includes('["deal","teacher_issue"].includes(kind)?"prewrite"'));
  assert.ok(edge.includes('ticket.categories.includes("manual_approved")'));
});

test("external moderation receives only allowlisted text fields and never receives reports", () => {
  const edge = fs.readFileSync(path.join(__dirname, "../supabase/functions/scrl-moderation/index.ts"), "utf8");
  assert.ok(edge.includes("function externalModerationPayload"));
  assert.ok(edge.includes('report:[]'));
  assert.ok(edge.includes('kind!=="report"'));
  assert.ok(edge.includes('await classify(kind,providerPayload,analysisViews)'));
  assert.ok(edge.includes('profile.deleted_at'));
});

test("financial operations lock active participant profiles before reserves and order rows", () => {
  const name = "20261124200000_serialize_financial_actor_profile_locks.sql";
  const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");

  const normalized = sql.toLowerCase();
  const from = (signature) => {
    const index = normalized.indexOf(signature.toLowerCase());
    assert.ok(index >= 0, "Missing SQL function: " + signature);
    return normalized.slice(index);
  };
  const deal = from("function public.scrl_create_deal");
  const teacher = from("function public.scrl_teacher_issue");
  const auction = from("function public.scrl_create_auction");
  const place = from("function public.scrl_place_exchange_order");
  const buy = from("function public.scrl_buy_exchange_order");

  for (const [name, source] of [["deal", deal], ["teacher_issue", teacher], ["buy", buy]]) {
    assert.ok(source.includes("order by p.id"), name + " must lock profiles in stable UUID order");
    assert.ok(source.includes("get diagnostics v_locked_profiles = row_count"), name + " must verify both profiles exist");
    assert.ok(source.indexOf("order by p.id") < source.indexOf("for update"), name + " must lock profiles before proceeding");
  }

  assert.ok(deal.indexOf("order by p.id") < deal.indexOf("select * into v_listing"), "deal creation locks profiles before publication rows");
  assert.ok(teacher.indexOf("order by p.id") < teacher.indexOf("teacher_issuance"), "teacher issuance locks profiles before quotas and wallets");
  assert.ok(auction.includes("deleted_at is null"));
  assert.ok(auction.includes("v_role is null or v_role not in ('teacher','admin')"));
  assert.ok(auction.includes("for update"));
  assert.ok(place.includes("blocked = false"));
  assert.ok(place.includes("deleted_at is null"));
  assert.ok(place.indexOf("for update") < place.indexOf("from public.wallets"));
  const buyProfileLock = buy.indexOf("order by p.id");
  const buyOrderLock = buy.indexOf("for update", buy.indexOf("from public.exchange_orders", buyProfileLock));
  assert.ok(buyProfileLock >= 0 && buyOrderLock > buyProfileLock, "exchange buy locks profiles before locking the order");
  assert.ok(buy.includes("scrl_required_scrl_holds"));
});
