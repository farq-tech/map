#!/usr/bin/env node
/**
 * Bundle budget — fails the build when the map gets heavier than a phone
 * on 4G should carry. Sizes are gzip, measured on apps/web/dist/assets.
 *
 *   mapbox chunk   ≤ 600 KB   (mapbox-gl itself; lazy, only on the map route)
 *   entry chunk    ≤ 120 KB   (React + router + shell, needed before anything paints)
 *   total JS       ≤ 850 KB
 */
import { gzipSync } from 'node:zlib';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const dir = new URL('../apps/web/dist/assets/', import.meta.url).pathname;
const BUDGET = { mapbox: 600 * 1024, entry: 120 * 1024, total: 850 * 1024 };

let files;
try {
  files = readdirSync(dir).filter((f) => f.endsWith('.js'));
} catch {
  console.error('bundle budget: apps/web/dist/assets not found — run the build first');
  process.exit(2);
}

const sizes = files.map((f) => ({ f, gz: gzipSync(readFileSync(join(dir, f))).length, raw: statSync(join(dir, f)).size }));
const kb = (n) => `${Math.round(n / 1024)} KB`;
const mapbox = sizes.filter((s) => /farq-mapbox|mapbox/.test(s.f)).reduce((a, s) => a + s.gz, 0);
const entry = sizes.filter((s) => /^index-/.test(s.f)).reduce((a, s) => a + s.gz, 0);
const total = sizes.reduce((a, s) => a + s.gz, 0);

const rows = [
  ['mapbox chunk', mapbox, BUDGET.mapbox],
  ['entry chunk', entry, BUDGET.entry],
  ['total JS', total, BUDGET.total],
];
let failed = false;
for (const [name, got, max] of rows) {
  const ok = got <= max;
  if (!ok) failed = true;
  console.log(`${ok ? 'ok  ' : 'OVER'} ${name.padEnd(13)} ${kb(got).padStart(8)} / ${kb(max)}`);
}
for (const s of sizes.sort((a, b) => b.gz - a.gz).slice(0, 6)) console.log(`     ${s.f.padEnd(40)} ${kb(s.gz).padStart(8)} gz  (${kb(s.raw)} raw)`);
process.exit(failed ? 1 : 0);
