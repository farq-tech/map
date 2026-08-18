'use strict';

const { Pool } = require('pg');

let pool = null;

function comparisonDbUrl() {
  return (
    process.env.SUPABASE_COMPARISON_DB_URL ||
    process.env.COMPARISONS_DB_URL ||
    null
  );
}

function getComparisonPool() {
  if (pool) return pool;
  const url = comparisonDbUrl();
  if (!url) return null;
  pool = new Pool({
    connectionString: url,
    ssl: { rejectUnauthorized: false },
    max: 8,
    idleTimeoutMillis: 60_000,
    connectionTimeoutMillis: 12_000,
  });
  pool.on('error', (err) => {
    console.warn('[comparison-pool]', err.message);
  });
  return pool;
}

async function comparisonQuery(text, params) {
  const p = getComparisonPool();
  if (!p) {
    throw Object.assign(new Error('comparison DB not configured'), {
      code: 'COMPARISON_UNCONFIGURED',
    });
  }
  const res = await p.query(text, params);
  return res.rows;
}

module.exports = {
  comparisonDbUrl,
  getComparisonPool,
  comparisonQuery,
};
