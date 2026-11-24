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

  assert.match(cases, /WHERE id = p_case_id[\\s\\S]*?FOR UPDATE/i);
  assert.match(cases, /v_case.status <> 'pending'/i);
  assert.match(cases, /NOT EXISTS \\([\\s\\S]*?scrl_moderation_bans/i);
  assert.match(cases, /source_id IS NOT NULL/i);
  assert.match(cases, /INSERT INTO public.notifications/i);
  assert.match(appeals, /WHERE id = p_appeal_id[\\s\\S]*?FOR UPDATE/i);
  assert.match(appeals, /v_appeal.status <> 'pending'/i);
  assert.match(appeals, /v_ban.active = false/i);
  assert.match(appeals, /NOT EXISTS \\([\\s\\S]*?scrl_moderation_bans/i);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\\.scrl_moderation_admin_resolve_case\\(uuid, uuid, text\\) TO service_role/i);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\\.scrl_moderation_admin_resolve_appeal\\(uuid, uuid, text, text\\) TO service_role/i);

  const edge = fs.readFileSync(path.join(__dirname, "../supabase/functions/scrl-moderation/index.ts"), "utf8");
  assert.match(edge, /rpc\\/scrl_moderation_admin_resolve_case/);
  assert.match(edge, /rpc\\/scrl_moderation_admin_resolve_appeal/);
  assert.doesNotMatch(edge, /scrl_moderation_cases\\?id=eq\\.[\\s\\S]*?method:"PATCH"/);
});

test("external AI consent is separate, optional and revocable", () => {
  const name = "20261124185600_separate_ai_consent_and_enable_manual_review.sql";
  const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
  assert.match(sql, /ALTER COLUMN ai_moderation_consent_at DROP NOT NULL/i);
  assert.match(sql, /ALTER COLUMN ai_moderation_consent_version DROP NOT NULL/i);
  assert.match(sql, /ADD COLUMN IF NOT EXISTS revoked_at timestamptz/i);
  assert.match(sql, /IF p_ai_consent IS TRUE AND p_ai_version IS DISTINCT FROM '2026-11-17-v2'/i);
  assert.match(sql, /SET revoked_at = coalesce\\(revoked_at, v_now\\)/i);
  assert.match(sql, /'needsOnboarding', \\(v_row.birth_date IS NULL OR NOT v_personal_ok\\)/i);
  assert.match(sql, /p.role = 'admin'/i);
  assert.match(sql, /CHECK \\(status IN \\('active', 'review', 'done', 'settlementError'\\)\\)/i);

  const consentGuard = sql.slice(sql.indexOf("FUNCTION private.scrl_require_user_consents"));
  assert.match(consentGuard, /personal_data_consent_version = '2026-11-17-v1'/i);
  assert.doesNotMatch(consentGuard, /ai_moderation_consent_at/i);
});

test("manual moderation does not send content externally without consent and keeps financial actions fail-closed", () => {
  const edge = fs.readFileSync(path.join(__dirname, "../supabase/functions/scrl-moderation/index.ts"), "utf8");
  assert.match(edge, /rpc\\/scrl_has_ai_processing_consent/);
  assert.match(edge, /const useExternalAI=providerEnabled&&aiConsent/);
  assert.match(edge, /decision:"flag"[\\s\\S]*?categories:\\["manual_review"\\]/);
  assert.match(edge, /manualReview&&\\["deal","teacher_issue"\\]\\.includes\\(kind\\)/);
  assert.match(edge, /moderation_admin_resolve_case/);

  const sql = fs.readFileSync(path.join(migrationDir, "20261124185600_separate_ai_consent_and_enable_manual_review.sql"), "utf8");
  assert.match(sql, /IF v_status = 'active' THEN[\\s\\S]*?scrl_notify/i);
  assert.match(sql, /scrl_send_message\\(uuid, text\\)/i);
});
