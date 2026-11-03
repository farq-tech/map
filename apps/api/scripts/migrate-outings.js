'use strict';

/* node apps/api/scripts/migrate-outings.js — applies apps/api/migrations/*.sql. */
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../.env') });
require('dotenv').config({ path: path.join(__dirname, '../../../.env') });
require('dotenv').config({ path: path.join(__dirname, '../../../.env.local') });
const { getOutingsPool, migrate } = require('../lib/outings/db');

(async () => {
  const pool = getOutingsPool();
  if (!pool) {
    console.error('No database URL: set SARY_DATABASE_URL (or DATABASE_URL).');
    process.exit(2);
  }
  try {
    const applied = await migrate(pool, { log: console.log });
    console.log(applied.length ? `applied ${applied.length} migration(s)` : 'up to date');
  } catch (err) {
    console.error('migration failed:', err.message);
    process.exitCode = 1;
  } finally {
    await pool.end();
  }
})();
