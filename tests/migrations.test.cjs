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
    const match = name.match(/^(\\d{14})_[a-z0-9_]+\\.sql$/);
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
  assert.match(sql, /IF v_action IN \\('read', 'mark_read', 'mark_all_read', 'read_all'\\) THEN/i);
  assert.match(sql, /ELSIF v_action IN \\('clear', 'delete', 'clear_all', 'delete_all'\\) THEN/i);
  assert.equal((sql.match(/WHERE user_id = auth\\.uid\\(\\)/gi) || []).length, 2);
  assert.match(sql, /SECURITY DEFINER[\\s\\S]*?SET search_path = public, auth, pg_temp/i);
  assert.match(sql, /REVOKE ALL ON FUNCTION public\\.scrl_manage_my_notifications\\(text\\) FROM PUBLIC, anon/i);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\\.scrl_manage_my_notifications\\(text\\) TO authenticated/i);
});
