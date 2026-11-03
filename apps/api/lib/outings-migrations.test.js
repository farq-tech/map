'use strict';

/**
 * Every outings migration (001–007) applies in order on an empty database and
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

test('the migrations folder holds exactly 001–007', () => {
  assert.deepEqual(fs.readdirSync(DIR).filter((f) => f.endsWith('.sql')).sort(), ALL);
});

test('001–007 apply in order on an empty database, then on a 001–002 (production) database', { skip, timeout: 60_000 }, async (t) => {
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

  assert.deepEqual(await migrate(pool), ALL.slice(2), 'only 003–007 are new');
  assert.deepEqual((await pool.query('SELECT name FROM sary.schema_migrations ORDER BY name')).rows.map((r) => r.name), ALL);

  /* Existing rows survive and pick up the new columns' defaults. */
  const row = (await pool.query('SELECT name, join_locked, rally_lat FROM sary.outings WHERE id = $1', [o.id])).rows[0];
  assert.deepEqual(row, { name: 'طلعة', join_locked: false, rally_lat: null });
  const mem = (await pool.query('SELECT co_leader FROM sary.outing_members WHERE outing_id = $1', [o.id])).rows[0];
  assert.equal(mem.co_leader, false);
  for (const table of ['push_subscriptions', 'trip_summaries']) {
    const { rows } = await pool.query(`SELECT to_regclass('sary.' || $1) AS t`, [table]);
    assert.ok(rows[0].t, `${table} exists`);
  }
});
