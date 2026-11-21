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
  assert.match(sql, /PERFORM w\\.user_id[\\s\\S]*?ORDER BY w\\.user_id[\\s\\S]*?FOR UPDATE/i);
  assert.match(sql, /IF v_buyer_wallet\\.hold_scrl < v_deal\\.escrow THEN/i);
  assert.match(sql, /SET hold_scrl = hold_scrl - v_deal\\.escrow/i);
  assert.doesNotMatch(sql, /hold_scrl\\s*=\\s*greatest/i);
  assert.match(sql, /REVOKE ALL ON FUNCTION public\\.scrl_deal_action\\(uuid, text, numeric\\) FROM PUBLIC, anon/i);
});

test("SECURITY DEFINER functions pin their search_path", () => {
  for (const name of migrationFiles) {
    const sql = fs.readFileSync(path.join(migrationDir, name), "utf8");
    const functions = [...sql.matchAll(
      /CREATE\\s+(?:OR\\s+REPLACE\\s+)?FUNCTION\\b[\\s\\S]*?\\bAS\\s+(\\$[a-z_]*\\$|\\$\\$)[\\s\\S]*?\\1\\s*;/gi
    )].map(match => match[0]);

    for (const definition of functions) {
      if (/\\bSECURITY\\s+DEFINER\\b/i.test(definition)) {
        assert.match(
          definition,
          /\\bSET\\s+search_path\\b/i,
          `SECURITY DEFINER function without fixed search_path in ${name}`
        );
      }
    }
  }
});
