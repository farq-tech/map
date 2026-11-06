'use strict';

/**
 * «كاميرات الرصد» data layer: import idempotency, the bbox read (identity-free),
 * report promotion (dedupe + threshold), and confirm/dismiss.
 *
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/cameras.test.js
 *
 * Uses its own database (`<db>_sary_cameras`) so it runs in parallel with the
 * other DB-backed tests.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { Pool } = require('pg');
const { createPool, migrate } = require('./outings/db');
const { createCameras, haversine } = require('./cameras');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_
  ? 'set SARY_TEST_DATABASE_URL to run'
  : !/test|localhost|127\.0\.0\.1/.test(URL_)
    ? 'refusing a non-test database'
    : false;

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_cameras`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

async function freshPool(t) {
  const pool = createPool(await isolatedDb(URL_));
  t.after(() => pool.end());
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await migrate(pool);
  return pool;
}

/** A real signed-in user, so reports can carry a distinct identity. */
async function makeUser(pool, name) {
  const { rows } = await pool.query(
    `INSERT INTO sary.users (display_name, token_hash) VALUES ($1, $2) RETURNING id`,
    [name, crypto.randomBytes(32)],
  );
  return rows[0].id;
}

// A base point in Riyadh; small offsets keep us inside the 50 m promotion radius.
const BASE = { lat: 24.7136, lon: 46.6753 };
const near = (m) => ({ lat: BASE.lat + m / 111_320, lon: BASE.lon });

test('haversine is metres and symmetric', () => {
  const d = haversine(BASE.lat, BASE.lon, BASE.lat + 0.001, BASE.lon);
  assert.ok(Math.abs(d - 111.32) < 1, `~111 m, got ${d}`);
});

test('import is idempotent and upserts in place on (source, source_id)', { skip }, async (t) => {
  const pool = await freshPool(t);
  const cams = createCameras({ pool });

  const feats = [
    { lat: BASE.lat, lon: BASE.lon, kind: 'fixed', speed_limit: 120, source: 'osm', source_id: 'node/1' },
    { lat: 24.70, lon: 46.70, kind: 'red_light', source: 'official', source_id: 'moi/9' },
  ];
  const first = await cams.importFeatures(feats);
  assert.equal(first.upserted, 2);

  // Re-import: same keys → still two rows, not four.
  await cams.importFeatures(feats);
  const { rows } = await pool.query('SELECT count(*)::int n FROM sary.speed_cameras');
  assert.equal(rows[0].n, 2);

  // Changing a property updates the existing row.
  await cams.importFeatures([{ ...feats[0], speed_limit: 100 }]);
  const r = await pool.query(`SELECT speed_limit FROM sary.speed_cameras WHERE source='osm' AND source_id='node/1'`);
  assert.equal(r.rows[0].speed_limit, 100);

  // A feature with no source_id, or source 'user', is never imported.
  const bad = await cams.importFeatures([{ lat: BASE.lat, lon: BASE.lon, source: 'osm' }, { lat: BASE.lat, lon: BASE.lon, source: 'user', source_id: 'x' }]);
  assert.equal(bad.upserted, 0);
  assert.equal(bad.skipped, 2);
});

test('importGeoJSON reads a FeatureCollection', { skip }, async (t) => {
  const pool = await freshPool(t);
  const cams = createCameras({ pool });
  const fc = {
    type: 'FeatureCollection',
    features: [
      { type: 'Feature', id: 'node/42', geometry: { type: 'Point', coordinates: [46.6753, 24.7136] }, properties: { source: 'osm', camera_type: 'avg_speed', maxspeed: 140 } },
    ],
  };
  const out = await cams.importGeoJSON(fc);
  assert.equal(out.upserted, 1);
  const { rows } = await pool.query(`SELECT kind, speed_limit, source_id FROM sary.speed_cameras`);
  assert.deepEqual(rows[0], { kind: 'avg_speed', speed_limit: 140, source_id: 'node/42' });
});

test('inBBox returns only in-box cameras, with no identity fields', { skip }, async (t) => {
  const pool = await freshPool(t);
  const cams = createCameras({ pool });
  await cams.importFeatures([
    { lat: 24.7136, lon: 46.6753, source: 'osm', source_id: 'in' },
    { lat: 25.9, lon: 43.0, source: 'osm', source_id: 'out' },
  ]);
  const out = await cams.inBBox({ west: 46.6, south: 24.6, east: 46.8, north: 24.8 });
  assert.equal(out.ok, true);
  assert.equal(out.cameras.length, 1);
  const cam = out.cameras[0];
  assert.deepEqual(Object.keys(cam).sort(), ['bearing', 'confidence', 'id', 'kind', 'lat', 'lon', 'source', 'speed_limit'].sort());
  assert.ok(!('user_id' in cam) && !('source_id' in cam));
  assert.equal((await cams.inBBox({ west: 1, south: 1, east: 2, north: 2 })).cameras.length, 0);
  assert.equal((await cams.inBBox({ west: 9, south: 9, east: 1, north: 1 })).ok, false); // bad box
});

test('three distinct reporters within 50 m promote to a user camera', { skip }, async (t) => {
  const pool = await freshPool(t);
  const cams = createCameras({ pool });
  const u1 = await makeUser(pool, 'أ');
  const u2 = await makeUser(pool, 'ب');
  const u3 = await makeUser(pool, 'ج');

  const r1 = await cams.report({ userId: u1, lat: BASE.lat, lon: BASE.lon, kind: 'mobile' });
  assert.equal(r1.report.status, 'pending');
  const r2 = await cams.report({ userId: u2, ...near(20), kind: 'mobile' });
  assert.equal(r2.report.status, 'pending');
  assert.equal((await pool.query('SELECT count(*)::int n FROM sary.speed_cameras')).rows[0].n, 0);

  const r3 = await cams.report({ userId: u3, ...near(35), kind: 'mobile' });
  assert.equal(r3.promoted, true);
  assert.ok(r3.camera_id);

  const cam = (await pool.query('SELECT * FROM sary.speed_cameras')).rows;
  assert.equal(cam.length, 1);
  assert.equal(cam[0].source, 'user');
  assert.equal(cam[0].kind, 'mobile');
  assert.ok(cam[0].confirmations >= 3);
  const promoted = (await pool.query(`SELECT count(*)::int n FROM sary.camera_reports WHERE status='promoted'`)).rows[0].n;
  assert.equal(promoted, 3);
});

test('the same reporter tapping repeatedly does not promote', { skip }, async (t) => {
  const pool = await freshPool(t);
  const cams = createCameras({ pool });
  const u1 = await makeUser(pool, 'أ');
  for (let i = 0; i < 5; i++) {
    await cams.report({ userId: u1, clientId: 'dev-1', lat: BASE.lat, lon: BASE.lon });
  }
  assert.equal((await pool.query('SELECT count(*)::int n FROM sary.speed_cameras')).rows[0].n, 0);
  // one report row (idempotent on user+client_id), so one reporter, no promotion
  assert.equal((await pool.query('SELECT count(*)::int n FROM sary.camera_reports')).rows[0].n, 1);
});

test('a report landing on an existing camera attaches and raises confidence, no new camera', { skip }, async (t) => {
  const pool = await freshPool(t);
  const cams = createCameras({ pool });
  await cams.importFeatures([{ lat: BASE.lat, lon: BASE.lon, source: 'osm', source_id: 'node/7', confidence: 0.6 }]);
  const u1 = await makeUser(pool, 'أ');
  const out = await cams.report({ userId: u1, ...near(10) });
  assert.equal(out.promoted, false);
  assert.equal(out.report.status, 'duplicate');
  const cam = (await pool.query('SELECT * FROM sary.speed_cameras')).rows;
  assert.equal(cam.length, 1);
  assert.equal(cam[0].confirmations, 1);
  assert.ok(cam[0].confidence > 0.6);
});

test('confirm raises confidence; dismiss lowers it and retires a crowd camera at the floor', { skip }, async (t) => {
  const pool = await freshPool(t);
  const cams = createCameras({ pool });
  // a user camera at confidence 0.5
  const { rows } = await pool.query(`INSERT INTO sary.speed_cameras (lat, lon, source, confidence) VALUES ($1,$2,'user',0.5) RETURNING id`, [BASE.lat, BASE.lon]);
  const id = rows[0].id;

  const c = await cams.confirm(id);
  assert.ok(Math.abs(c.camera.confidence - 0.6) < 1e-6);

  // dismiss repeatedly: 0.6 → 0.4 → 0.2 → 0.0 → removed
  await cams.dismiss(id);
  await cams.dismiss(id);
  const last = await cams.dismiss(id);
  assert.equal(last.removed, true);
  assert.equal((await pool.query('SELECT count(*)::int n FROM sary.speed_cameras')).rows[0].n, 0);

  assert.equal((await cams.confirm('00000000-0000-0000-0000-000000000000')).ok, false);
});

test('a bad coordinate is refused before touching the database', { skip }, async (t) => {
  const pool = await freshPool(t);
  const cams = createCameras({ pool });
  const out = await cams.report({ lat: 999, lon: 'x' });
  assert.equal(out.ok, false);
  assert.equal((await pool.query('SELECT count(*)::int n FROM sary.camera_reports')).rows[0].n, 0);
});
