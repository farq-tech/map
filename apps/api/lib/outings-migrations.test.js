'use strict';

/**
 * Every outings migration (001–017) applies in order on an empty database and
 * on one in today's production state (001–002 already applied, with data).
 *
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-migrations.test.js
 *
 * Uses its own database (`<db>_sary_migrations`) so it can run in parallel
 * with the other outings tests.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { Pool } = require('pg');
const { createPool, migrate } = require('./outings/db');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;

const DIR = path.join(__dirname, '..', 'migrations');
const ALL = [
  '001_sary_outings.sql',
  '002_sary_member_phone.sql',
  '003_sary_field_diagnostics.sql',
  '004_sary_accounts.sql',
  '005_sary_trip_summary.sql',
  '006_sary_push_subscriptions.sql',
  '007_sary_safety.sql',
  '008_sary_apns_tokens.sql',
  '009_sary_outing_features.sql',
  '010_sary_ptt_tokens.sql',
  '011_sary_personal_invites.sql',
  '012_sary_trip_chat.sql',
  '013_sary_ptt_channels.sql',
  '014_sary_group_audio.sql',
  '015_sary_ptt_voice_notes.sql',
  '016_sary_outing_legs.sql',
  '017_sary_hidden_location.sql',
  '018_sary_speed_cameras.sql',
];

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_migrations`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

test('the migrations folder holds exactly 001–017 + 018', () => {
  assert.deepEqual(fs.readdirSync(DIR).filter((f) => f.endsWith('.sql')).sort(), ALL);
});

test('001–017 apply in order on an empty database, then on a 001–002 (production) database', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(await isolatedDb(URL_));
  t.after(() => pool.end());

  /* Empty database. */
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  assert.deepEqual(await migrate(pool), ALL);
  assert.deepEqual(await migrate(pool), [], 'idempotent');

  /* Production today: only 001 and 002, recorded the way migrate() records them, with live rows. */
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await pool.query('CREATE SCHEMA sary');
  await pool.query(`CREATE TABLE sary.schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  for (const f of ALL.slice(0, 2)) {
    await pool.query(fs.readFileSync(path.join(DIR, f), 'utf8'));
    await pool.query('INSERT INTO sary.schema_migrations (name) VALUES ($1)', [f]);
  }
  const [u] = (await pool.query(`INSERT INTO sary.users (display_name, token_hash) VALUES ('أبو فهد', $1) RETURNING id`, [crypto.randomBytes(32)])).rows;
  const [o] = (await pool.query(`INSERT INTO sary.outings (name, owner_id, status) VALUES ('طلعة', $1, 'active') RETURNING id`, [u.id])).rows;
  await pool.query(`INSERT INTO sary.outing_members (outing_id, user_id, role) VALUES ($1, $2, 'owner')`, [o.id, u.id]);

  assert.deepEqual(await migrate(pool), ALL.slice(2), 'only 003–009 are new');
  assert.deepEqual((await pool.query('SELECT name FROM sary.schema_migrations ORDER BY name')).rows.map((r) => r.name), ALL);

  /* Existing rows survive and pick up the new columns' defaults. */
  const row = (await pool.query('SELECT name, join_locked, rally_lat FROM sary.outings WHERE id = $1', [o.id])).rows[0];
  assert.deepEqual(row, { name: 'طلعة', join_locked: false, rally_lat: null });
  const mem = (await pool.query('SELECT co_leader FROM sary.outing_members WHERE outing_id = $1', [o.id])).rows[0];
  assert.equal(mem.co_leader, false);
  for (const table of ['push_subscriptions', 'trip_summaries', 'apns_tokens']) {
    const { rows } = await pool.query(`SELECT to_regclass('sary.' || $1) AS t`, [table]);
    assert.ok(rows[0].t, `${table} exists`);
  }
});

test('008 on a database at the current level (001–007 applied, with data): only 008 (and 009) are new, RLS on, rules hold', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(await isolatedDb(URL_));
  t.after(() => pool.end());
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await pool.query('CREATE SCHEMA sary');
  await pool.query(`CREATE TABLE sary.schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  for (const f of ALL.slice(0, 7)) {
    await pool.query(fs.readFileSync(path.join(DIR, f), 'utf8'));
    await pool.query('INSERT INTO sary.schema_migrations (name) VALUES ($1)', [f]);
  }
  const [u] = (await pool.query(`INSERT INTO sary.users (display_name, token_hash) VALUES ('سعد', $1) RETURNING id`, [crypto.randomBytes(32)])).rows;
  await pool.query(`INSERT INTO sary.push_subscriptions (user_id, endpoint, p256dh, auth) VALUES ($1, 'https://fcm.googleapis.com/fcm/send/x', $2, $3)`, [u.id, 'p'.repeat(87), 'a'.repeat(22)]);

  assert.deepEqual(await migrate(pool), ['008_sary_apns_tokens.sql', '009_sary_outing_features.sql', '010_sary_ptt_tokens.sql', '011_sary_personal_invites.sql', '012_sary_trip_chat.sql', '013_sary_ptt_channels.sql', '014_sary_group_audio.sql', '015_sary_ptt_voice_notes.sql', '016_sary_outing_legs.sql', '017_sary_hidden_location.sql', '018_sary_speed_cameras.sql']);
  assert.deepEqual(await migrate(pool), [], 'idempotent');
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM sary.push_subscriptions')).rows[0].n, 1, 'web push rows untouched');

  const { rows: [rls] } = await pool.query(`SELECT relrowsecurity FROM pg_class WHERE oid = 'sary.apns_tokens'::regclass`);
  assert.equal(rls.relrowsecurity, true);
  const { rows: pol } = await pool.query(`SELECT 1 FROM pg_policies WHERE schemaname = 'sary' AND tablename = 'apns_tokens'`);
  assert.equal(pol.length, 0, 'no policies');

  const tok = 'ab'.repeat(32);
  await pool.query(`INSERT INTO sary.apns_tokens (user_id, token, environment, bundle_id) VALUES ($1, $2, 'sandbox', 'sa.sary.albarq')`, [u.id, tok]);
  const bad = async (sqlTok, env) => assert.rejects(pool.query(`INSERT INTO sary.apns_tokens (user_id, token, environment, bundle_id) VALUES ($1, $2, $3, 'sa.sary.albarq')`, [u.id, sqlTok, env]));
  await bad(tok, 'production'); // unique per token
  await bad('AB'.repeat(32), 'sandbox'); // stored lower-case only
  await bad('a'.repeat(63), 'sandbox');
  await bad('cd'.repeat(32), 'development');
  const row = (await pool.query('SELECT created_at, updated_at FROM sary.apns_tokens WHERE token = $1', [tok])).rows[0];
  assert.ok(row.created_at && row.updated_at);
  await pool.query('DELETE FROM sary.users WHERE id = $1', [u.id]);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM sary.apns_tokens')).rows[0].n, 0, 'cascades with the identity');
});

test('009 on a database at 008 (with data): only 009 is new, existing rows keep working, RLS on, rules hold', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(await isolatedDb(URL_));
  t.after(() => pool.end());
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await pool.query('CREATE SCHEMA sary');
  await pool.query(`CREATE TABLE sary.schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  for (const f of ALL.slice(0, 8)) {
    await pool.query(fs.readFileSync(path.join(DIR, f), 'utf8'));
    await pool.query('INSERT INTO sary.schema_migrations (name) VALUES ($1)', [f]);
  }
  const [u] = (await pool.query(`INSERT INTO sary.users (display_name, token_hash) VALUES ('سعد', $1) RETURNING id`, [crypto.randomBytes(32)])).rows;
  const [o] = (await pool.query(`INSERT INTO sary.outings (name, owner_id, status, rally_lat, rally_lng) VALUES ('طلعة', $1, 'active', 24.7, 46.6) RETURNING id`, [u.id])).rows;
  await pool.query(`INSERT INTO sary.outing_members (outing_id, user_id, role) VALUES ($1, $2, 'owner')`, [o.id, u.id]);

  assert.deepEqual(await migrate(pool), ['009_sary_outing_features.sql', '010_sary_ptt_tokens.sql', '011_sary_personal_invites.sql', '012_sary_trip_chat.sql', '013_sary_ptt_channels.sql', '014_sary_group_audio.sql', '015_sary_ptt_voice_notes.sql', '016_sary_outing_legs.sql', '017_sary_hidden_location.sql', '018_sary_speed_cameras.sql']);
  assert.deepEqual(await migrate(pool), [], 'idempotent');
  /* Re-running the file itself is harmless too (IF NOT EXISTS everywhere). */
  await pool.query(fs.readFileSync(path.join(DIR, '009_sary_outing_features.sql'), 'utf8'));

  const row = (await pool.query('SELECT name, rally_lat, convoy_lead_user_id, convoy_max_gap_m, plan_route, plan_notes, plan_destination FROM sary.outings WHERE id = $1', [o.id])).rows[0];
  assert.deepEqual(row, { name: 'طلعة', rally_lat: 24.7, convoy_lead_user_id: null, convoy_max_gap_m: 1000, plan_route: null, plan_notes: null, plan_destination: null });

  for (const table of ['return_timers', 'watch_tokens', 'watch_subscriptions', 'outing_waypoints', 'outing_checklist']) {
    const { rows: [rls] } = await pool.query(`SELECT relrowsecurity FROM pg_class WHERE oid = ('sary.' || $1)::regclass`, [table]);
    assert.equal(rls.relrowsecurity, true, `${table} RLS on`);
    const { rows: pol } = await pool.query(`SELECT 1 FROM pg_policies WHERE schemaname = 'sary' AND tablename = $1`, [table]);
    assert.equal(pol.length, 0, `${table}: no policies`);
  }

  const due = new Date(Date.now() + 3600_000);
  const [tm] = (await pool.query(`INSERT INTO sary.return_timers (outing_id, user_id, due_at, contact_name) VALUES ($1, $2, $3, 'أمي') RETURNING id`, [o.id, u.id, due])).rows;
  /* One live timer per person per outing. */
  await assert.rejects(pool.query(`INSERT INTO sary.return_timers (outing_id, user_id, due_at, contact_name) VALUES ($1, $2, $3, 'أبوي')`, [o.id, u.id, due]));
  /* An armed timer can never hold a position snapshot. */
  await assert.rejects(pool.query(`UPDATE sary.return_timers SET last_known = '[]'::jsonb WHERE id = $1`, [tm.id]));
  await assert.rejects(pool.query(`INSERT INTO sary.watch_tokens (token_hash, timer_id) VALUES ($1, $2)`, [crypto.randomBytes(16), tm.id]), 'digest is 32 bytes');
  await pool.query(`INSERT INTO sary.watch_tokens (token_hash, timer_id) VALUES ($1, $2)`, [crypto.randomBytes(32), tm.id]);
  await assert.rejects(pool.query(`UPDATE sary.outings SET convoy_max_gap_m = 100 WHERE id = $1`, [o.id]));
  await assert.rejects(pool.query(`INSERT INTO sary.outing_waypoints (outing_id, user_id, kind, title, lat, lng) VALUES ($1, $2, 'volcano', 'x', 1, 1)`, [o.id, u.id]));
  await assert.rejects(pool.query(`INSERT INTO sary.outing_waypoints (outing_id, user_id, kind, title, lat, lng, photo) VALUES ($1, $2, 'camp', 'x', 1, 1, 'data:image/png;base64,AAAA')`, [o.id, u.id]));
  await pool.query(`INSERT INTO sary.outing_waypoints (outing_id, user_id, kind, title, lat, lng) VALUES ($1, $2, 'camp', 'المخيم', 24.1, 46.1)`, [o.id, u.id]);
  await pool.query(`INSERT INTO sary.outing_checklist (outing_id, title, created_by, assignee_user_id) VALUES ($1, 'حطب', $2, $2)`, [o.id, u.id]);

  /* Deleting the outing takes its features; deleting the identity takes its timers + waypoints. */
  await pool.query(`DELETE FROM sary.outings WHERE id = $1`, [o.id]);
  for (const table of ['return_timers', 'watch_tokens', 'outing_waypoints', 'outing_checklist']) {
    assert.equal((await pool.query(`SELECT count(*)::int AS n FROM sary.${table}`)).rows[0].n, 0, `${table} cascades with the outing`);
  }
});

test('010 on a database at 009 (with data): only 010 is new, RLS on, tokens cascade with the outing and the identity', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(await isolatedDb(URL_));
  t.after(() => pool.end());
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await pool.query('CREATE SCHEMA sary');
  await pool.query(`CREATE TABLE sary.schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  for (const f of ALL.slice(0, 9)) {
    await pool.query(fs.readFileSync(path.join(DIR, f), 'utf8'));
    await pool.query('INSERT INTO sary.schema_migrations (name) VALUES ($1)', [f]);
  }
  const [u] = (await pool.query(`INSERT INTO sary.users (display_name, token_hash) VALUES ('سعد', $1) RETURNING id`, [crypto.randomBytes(32)])).rows;
  const [u2] = (await pool.query(`INSERT INTO sary.users (display_name, token_hash) VALUES ('فهد', $1) RETURNING id`, [crypto.randomBytes(32)])).rows;
  const [o] = (await pool.query(`INSERT INTO sary.outings (name, owner_id, status) VALUES ('طلعة', $1, 'active') RETURNING id`, [u.id])).rows;

  assert.deepEqual(await migrate(pool), ['010_sary_ptt_tokens.sql', '011_sary_personal_invites.sql', '012_sary_trip_chat.sql', '013_sary_ptt_channels.sql', '014_sary_group_audio.sql', '015_sary_ptt_voice_notes.sql', '016_sary_outing_legs.sql', '017_sary_hidden_location.sql', '018_sary_speed_cameras.sql']);
  assert.deepEqual(await migrate(pool), [], 'idempotent');
  await pool.query(fs.readFileSync(path.join(DIR, '010_sary_ptt_tokens.sql'), 'utf8'));
  const { rows: [rls] } = await pool.query(`SELECT relrowsecurity FROM pg_class WHERE oid = 'sary.ptt_tokens'::regclass`);
  assert.equal(rls.relrowsecurity, true);
  assert.equal((await pool.query(`SELECT 1 FROM pg_policies WHERE schemaname = 'sary' AND tablename = 'ptt_tokens'`)).rows.length, 0);

  const ins = (user, token, env = 'sandbox') => pool.query(`INSERT INTO sary.ptt_tokens (user_id, outing_id, token, environment, bundle_id) VALUES ($1, $2, $3, $4, 'sa.sary.albarq')`, [user, o.id, token, env]);
  await assert.rejects(ins(u.id, 'NOT-HEX'));
  await assert.rejects(ins(u.id, 'a'.repeat(64), 'dev'));
  await ins(u.id, 'a'.repeat(64));
  await assert.rejects(ins(u2.id, 'a'.repeat(64)), 'a token is unique');
  await ins(u2.id, 'b'.repeat(64));
  await pool.query(`DELETE FROM sary.users WHERE id = $1`, [u2.id]);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM sary.ptt_tokens')).rows[0].n, 1, 'cascades with the identity');
  await pool.query(`DELETE FROM sary.outings WHERE id = $1`, [o.id]);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM sary.ptt_tokens')).rows[0].n, 0, 'cascades with the outing');
});

test('011 on a database at 010 (with live group links): only 011 is new, old links stay open group links', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(await isolatedDb(URL_));
  t.after(() => pool.end());
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await pool.query('CREATE SCHEMA sary');
  await pool.query(`CREATE TABLE sary.schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  for (const f of ALL.slice(0, 10)) {
    await pool.query(fs.readFileSync(path.join(DIR, f), 'utf8'));
    await pool.query('INSERT INTO sary.schema_migrations (name) VALUES ($1)', [f]);
  }
  const [u] = (await pool.query(`INSERT INTO sary.users (display_name, token_hash) VALUES ('سعد', $1) RETURNING id`, [crypto.randomBytes(32)])).rows;
  const [o] = (await pool.query(`INSERT INTO sary.outings (name, owner_id, status) VALUES ('طلعة', $1, 'active') RETURNING id`, [u.id])).rows;
  await pool.query(`INSERT INTO sary.outing_members (outing_id, user_id, role) VALUES ($1, $2, 'owner')`, [o.id, u.id]);
  const [inv] = (await pool.query(
    `INSERT INTO sary.outing_invites (outing_id, token_hash, created_by, expires_at, uses) VALUES ($1, $2, $3, now() + interval '1 day', 3) RETURNING id`,
    [o.id, crypto.randomBytes(32), u.id],
  )).rows;

  assert.deepEqual(await migrate(pool), ['011_sary_personal_invites.sql', '012_sary_trip_chat.sql', '013_sary_ptt_channels.sql', '014_sary_group_audio.sql', '015_sary_ptt_voice_notes.sql', '016_sary_outing_legs.sql', '017_sary_hidden_location.sql', '018_sary_speed_cameras.sql']);
  assert.deepEqual(await migrate(pool), [], 'idempotent');
  await pool.query(fs.readFileSync(path.join(DIR, '011_sary_personal_invites.sql'), 'utf8'));

  const row = (await pool.query(`SELECT kind, uses, invitee_name, consumed_at, revoked_at FROM sary.outing_invites WHERE id = $1`, [inv.id])).rows[0];
  assert.deepEqual(row, { kind: 'group', uses: 3, invitee_name: null, consumed_at: null, revoked_at: null });
  assert.equal((await pool.query(`SELECT open_links FROM sary.outings WHERE id = $1`, [o.id])).rows[0].open_links, true, 'existing trips keep their open link');
  const mem = (await pool.query(`SELECT invited_name, invite_id FROM sary.outing_members WHERE outing_id = $1`, [o.id])).rows[0];
  assert.deepEqual(mem, { invited_name: null, invite_id: null });

  const bad = (sql, params) => assert.rejects(pool.query(sql, params));
  await bad(`INSERT INTO sary.outing_invites (outing_id, token_hash, created_by, expires_at, kind) VALUES ($1, $2, $3, now(), 'personal')`, [o.id, crypto.randomBytes(32), u.id]);
  await bad(`INSERT INTO sary.outing_invites (outing_id, token_hash, created_by, expires_at, kind) VALUES ($1, $2, $3, now(), 'vip')`, [o.id, crypto.randomBytes(32), u.id]);
  await bad(`INSERT INTO sary.outing_invites (outing_id, token_hash, created_by, expires_at, kind, invitee_name, invitee_phone_last4) VALUES ($1, $2, $3, now(), 'personal', 'فهد', '12345')`, [o.id, crypto.randomBytes(32), u.id]);
  const [p] = (await pool.query(
    `INSERT INTO sary.outing_invites (outing_id, token_hash, created_by, expires_at, kind, invitee_name, invitee_phone_last4) VALUES ($1, $2, $3, now(), 'personal', 'فهد', '4567') RETURNING id`,
    [o.id, crypto.randomBytes(32), u.id],
  )).rows;
  await pool.query(`UPDATE sary.outing_members SET invite_id = $2, invited_name = 'فهد' WHERE outing_id = $1`, [o.id, p.id]);
  await pool.query(`DELETE FROM sary.outing_invites WHERE id = $1`, [p.id]);
  const after = (await pool.query(`SELECT invited_name, invite_id FROM sary.outing_members WHERE outing_id = $1`, [o.id])).rows[0];
  assert.deepEqual(after, { invited_name: 'فهد', invite_id: null }, 'sweeping an old invite keeps the member and their name');
});

test('012 on a database at 011 (with data): only 012 is new, additive, RLS on, chat cascades with identity and outing', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(await isolatedDb(URL_));
  t.after(() => pool.end());
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await pool.query('CREATE SCHEMA sary');
  await pool.query(`CREATE TABLE sary.schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  for (const f of ALL.slice(0, 11)) {
    await pool.query(fs.readFileSync(path.join(DIR, f), 'utf8'));
    await pool.query('INSERT INTO sary.schema_migrations (name) VALUES ($1)', [f]);
  }
  const user = async (n) => (await pool.query(`INSERT INTO sary.users (display_name, token_hash) VALUES ($1, $2) RETURNING id`, [n, crypto.randomBytes(32)])).rows[0];
  const a = await user('سعد');
  const b = await user('فهد');
  const [o] = (await pool.query(`INSERT INTO sary.outings (name, owner_id, status) VALUES ('طلعة', $1, 'active') RETURNING id`, [a.id])).rows;

  assert.deepEqual(await migrate(pool), ['012_sary_trip_chat.sql', '013_sary_ptt_channels.sql', '014_sary_group_audio.sql', '015_sary_ptt_voice_notes.sql', '016_sary_outing_legs.sql', '017_sary_hidden_location.sql', '018_sary_speed_cameras.sql'], 'only 012 (and 013–016) are new');
  assert.deepEqual(await migrate(pool), [], 'idempotent');
  await pool.query(fs.readFileSync(path.join(DIR, '012_sary_trip_chat.sql'), 'utf8'));

  assert.equal((await pool.query(`SELECT chat_seq FROM sary.outings WHERE id = $1`, [o.id])).rows[0].chat_seq, '0');
  assert.equal((await pool.query(`SELECT chat_push FROM sary.users WHERE id = $1`, [a.id])).rows[0].chat_push, true, 'existing people: notifications on');
  for (const table of ['chat_messages', 'chat_reads']) {
    const { rows } = await pool.query(`SELECT relrowsecurity FROM pg_class WHERE oid = ('sary.' || $1)::regclass`, [table]);
    assert.equal(rows[0].relrowsecurity, true, `${table}: RLS on`);
  }
  const dm = [a.id, b.id].sort().join(':');
  const ins = (seq, conv, sender, recipient, extra = {}) =>
    pool.query(
      `INSERT INTO sary.chat_messages (outing_id, seq, conv, sender_id, recipient_id, client_id, kind, body) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [o.id, seq, conv, sender, recipient, extra.cid || `c${seq}`, extra.kind || 'text', extra.body ?? 'هلا'],
    );
  await ins(1, 'group', a.id, null);
  await ins(2, dm, a.id, b.id);
  await ins(3, 'group', b.id, null);
  const bad = (p) => assert.rejects(p);
  await bad(ins(1, 'group', a.id, null, { cid: 'dup-seq' }));
  await bad(ins(4, 'group', a.id, null, { cid: 'c1' }));
  await bad(ins(5, 'group', a.id, b.id));
  await bad(ins(6, dm, a.id, null));
  await bad(ins(7, 'group', a.id, null, { kind: 'photo' }));
  await bad(ins(8, 'group', a.id, null, { body: 'x'.repeat(1001) }));
  await pool.query(`INSERT INTO sary.chat_reads (outing_id, user_id, conv, last_seq) VALUES ($1, $2, 'group', 3)`, [o.id, b.id]);
  await pool.query(`DELETE FROM sary.users WHERE id = $1`, [b.id]);
  const left = (await pool.query(`SELECT seq FROM sary.chat_messages ORDER BY seq`)).rows.map((r) => Number(r.seq));
  assert.deepEqual(left, [1], 'their messages and the DMs to them go with the identity');
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM sary.chat_reads')).rows[0].n, 0);
  await pool.query(`DELETE FROM sary.outings WHERE id = $1`, [o.id]);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM sary.chat_messages')).rows[0].n, 0, 'cascades with the outing');
});

test('013 on a database at 012 (with a live trip): only 013 is new, RLS on, private channels cascade with the trip and the identity', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(await isolatedDb(URL_));
  t.after(() => pool.end());
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await pool.query('CREATE SCHEMA sary');
  await pool.query(`CREATE TABLE sary.schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  for (const f of ALL.filter((f) => f < '013')) {
    await pool.query(fs.readFileSync(path.join(DIR, f), 'utf8'));
    await pool.query('INSERT INTO sary.schema_migrations (name) VALUES ($1)', [f]);
  }
  const user = async (n) => (await pool.query(`INSERT INTO sary.users (display_name, token_hash) VALUES ($1, $2) RETURNING id`, [n, crypto.randomBytes(32)])).rows[0].id;
  const [a, b] = [await user('أبو فهد'), await user('سعد')];
  const [o] = (await pool.query(`INSERT INTO sary.outings (name, owner_id, status) VALUES ('طلعة', $1, 'active') RETURNING id`, [a])).rows;
  for (const [u, role] of [[a, 'owner'], [b, 'member']]) await pool.query(`INSERT INTO sary.outing_members (outing_id, user_id, role) VALUES ($1, $2, $3)`, [o.id, u, role]);

  assert.deepEqual(await migrate(pool), ['013_sary_ptt_channels.sql', '014_sary_group_audio.sql', '015_sary_ptt_voice_notes.sql', '016_sary_outing_legs.sql', '017_sary_hidden_location.sql', '018_sary_speed_cameras.sql']);
  assert.deepEqual(await migrate(pool), [], 'idempotent');
  await pool.query(fs.readFileSync(path.join(DIR, '013_sary_ptt_channels.sql'), 'utf8'));
  /* Nothing existing changed: the trip and its members are as they were. */
  assert.equal((await pool.query(`SELECT count(*)::int AS n FROM sary.outing_members WHERE outing_id = $1 AND status = 'active'`, [o.id])).rows[0].n, 2);

  for (const table of ['ptt_channels', 'ptt_channel_members']) {
    const { rows: [rls] } = await pool.query(`SELECT relrowsecurity FROM pg_class WHERE oid = ('sary.' || $1)::regclass`, [table]);
    assert.equal(rls.relrowsecurity, true, `${table} RLS on`);
    assert.equal((await pool.query(`SELECT 1 FROM pg_policies WHERE schemaname = 'sary' AND tablename = $1`, [table])).rows.length, 0);
  }
  await assert.rejects(pool.query(`INSERT INTO sary.ptt_channels (outing_id, name, created_by) VALUES ($1, '', $2)`, [o.id, a]), 'empty name');
  await assert.rejects(pool.query(`INSERT INTO sary.ptt_channels (outing_id, kind, name) VALUES ($1, 'secret', 'x')`, [o.id]), 'unknown kind');
  const [c] = (await pool.query(`INSERT INTO sary.ptt_channels (outing_id, name, created_by) VALUES ($1, 'الأمامية', $2) RETURNING id, kind`, [o.id, a])).rows;
  assert.equal(c.kind, 'private', 'private by default');
  for (const u of [a, b]) await pool.query(`INSERT INTO sary.ptt_channel_members (channel_id, user_id, added_by) VALUES ($1, $2, $3)`, [c.id, u, a]);
  await assert.rejects(pool.query(`INSERT INTO sary.ptt_channel_members (channel_id, user_id) VALUES ($1, $2)`, [c.id, b]), 'once per person');

  /* Deleting the identity takes their invitations; the creator going keeps the channel (created_by → NULL). */
  await pool.query(`DELETE FROM sary.users WHERE id = $1`, [b]);
  assert.equal((await pool.query(`SELECT count(*)::int AS n FROM sary.ptt_channel_members`)).rows[0].n, 1);
  await pool.query(`DELETE FROM sary.outings WHERE id = $1`, [o.id]);
  assert.equal((await pool.query(`SELECT count(*)::int AS n FROM sary.ptt_channels`)).rows[0].n, 0, 'cascades with the trip');
  assert.equal((await pool.query(`SELECT count(*)::int AS n FROM sary.ptt_channel_members`)).rows[0].n, 0);
});

test('014 on a database at 013: only 014 is new, RLS on, the row goes with the outing', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(await isolatedDb(URL_));
  t.after(() => pool.end());
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await pool.query(`CREATE SCHEMA sary`);
  await pool.query(`CREATE TABLE sary.schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  for (const f of ALL.filter((x) => x !== '014_sary_group_audio.sql' && x !== '015_sary_ptt_voice_notes.sql' && x !== '016_sary_outing_legs.sql' && x !== '017_sary_hidden_location.sql' && x !== '018_sary_speed_cameras.sql')) {
    await pool.query(fs.readFileSync(path.join(DIR, f), 'utf8'));
    await pool.query('INSERT INTO sary.schema_migrations (name) VALUES ($1)', [f]);
  }
  const [u] = (await pool.query(`INSERT INTO sary.users (display_name, token_hash) VALUES ('سعد', $1) RETURNING id`, [crypto.randomBytes(32)])).rows;
  const [o] = (await pool.query(`INSERT INTO sary.outings (name, owner_id) VALUES ('طلعة', $1) RETURNING id`, [u.id])).rows;
  assert.deepEqual(await migrate(pool), ['014_sary_group_audio.sql', '015_sary_ptt_voice_notes.sql', '016_sary_outing_legs.sql', '017_sary_hidden_location.sql', '018_sary_speed_cameras.sql']);
  assert.deepEqual(await migrate(pool), [], 'idempotent');
  await pool.query(fs.readFileSync(path.join(DIR, '014_sary_group_audio.sql'), 'utf8'));
  const [rls] = (await pool.query(`SELECT relrowsecurity FROM pg_class WHERE oid = 'sary.group_audio'::regclass`)).rows;
  assert.equal(rls.relrowsecurity, true);
  await pool.query(`INSERT INTO sary.group_audio (outing_id, state) VALUES ($1, '{"item":null}')`, [o.id]);
  await pool.query(`DELETE FROM sary.outings WHERE id = $1`, [o.id]);
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM sary.group_audio')).rows[0].n, 0, 'cascades with the outing');
});
