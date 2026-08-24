#!/usr/bin/env node
'use strict';

/**
 * Lightweight Farq Map data-quality monitor.
 * Read-only. Never merges places. Never invents coordinates.
 *
 *   npm run map:quality
 */

const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../../.env.local') });
require('dotenv').config({ path: path.join(__dirname, '../../../.env') });
require('dotenv').config({ path: path.join(__dirname, '../../.env') });

const { qualityHealth, mapHealth } = require('../lib/comparison-map');

async function main() {
  const [health, quality] = await Promise.all([mapHealth(), qualityHealth()]);
  const report = {
    at: new Date().toISOString(),
    health,
    quality,
  };
  console.log(JSON.stringify(report, null, 2));
  if (!health.ok || !quality.ok) process.exitCode = 2;
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
