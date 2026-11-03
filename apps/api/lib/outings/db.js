'use strict';

/**
 * The outings pool. Writes live data, so it is kept apart from the comparison
 * read pool: SARY_DATABASE_URL first, then the same URL the rest of the API
 * already uses (one Supabase project serves both today).
 */

const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');
const { comparisonDbUrl } = require('../comparison-pool');

let pool = null;

function outingsDbUrl(env = process.env) {
  const raw = env.SARY_DATABASE_URL || comparisonDbUrl();
  if (!raw) return null;
  return String(raw)
    .replace(/([?&])sslmode=[^&]*/i, '$1')
    .replace(/[?&]$/, '')
    .replace(/\?&/, '?');
}

function needsSsl(url) {
  return !/@(localhost|127\.0\.0\.1)(:|\/)/.test(url) && process.env.SARY_DATABASE_SSL !== '0';
}

function createPool(url) {
  const p = new Pool({
    connectionString: url,
    ssl: needsSsl(url) ? { rejectUnauthorized: false } : false,
    max: Number(process.env.SARY_DB_POOL_MAX || 8),
    idleTimeoutMillis: 60_000,
    connectionTimeoutMillis: 10_000,
  });
  /* Never log the query or its parameters: they may hold coordinates. */
  p.on('error', (err) => console.warn('[outings-db]', err.code || err.message));
  return p;
}

function getOutingsPool() {
  if (pool) return pool;
  const url = outingsDbUrl();
  if (!url) return null;
  pool = createPool(url);
  return pool;
}

const MIGRATIONS_DIR = path.join(__dirname, '..', '..', 'migrations');

/**
 * Applies every migrations/*.sql not yet recorded, in name order, each in its
 * own transaction. Additive files only — nothing here drops data.
 */
async function migrate(p, { log = () => {} } = {}) {
  await p.query(`CREATE SCHEMA IF NOT EXISTS sary`);
  await p.query(`CREATE TABLE IF NOT EXISTS sary.schema_migrations (
    name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  await p.query(`ALTER TABLE sary.schema_migrations ENABLE ROW LEVEL SECURITY`);
  const files = fs.readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort();
  const done = new Set((await p.query('SELECT name FROM sary.schema_migrations')).rows.map((r) => r.name));
  const applied = [];
  for (const file of files) {
    if (done.has(file)) continue;
    const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8');
    const client = await p.connect();
    try {
      await client.query('BEGIN');
      await client.query(sql);
      await client.query('INSERT INTO sary.schema_migrations (name) VALUES ($1)', [file]);
      await client.query('COMMIT');
      applied.push(file);
      log(`[outings-db] applied ${file}`);
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  }
  return applied;
}

module.exports = { outingsDbUrl, getOutingsPool, createPool, migrate };
