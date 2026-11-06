'use strict';

/**
 * /api/cameras over a real Postgres and the real router: the public bbox read,
 * an anonymous «كاميرا هنا» report, confirm/dismiss, and the 503 when there is
 * no service. Authentication is faked (token → user id) so the test needs no
 * outings identity flow; the router only ever calls authenticate(token).
 *
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/cameras-route.test.js
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const crypto = require('crypto');
const express = require('express');
const { createPool, migrate } = require('./outings/db');
const { createCameras } = require('./cameras');
const { createCamerasRouter } = require('../routes/cameras');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_
  ? 'set SARY_TEST_DATABASE_URL to run'
  : !/test|localhost|127\.0\.0\.1/.test(URL_)
    ? 'refusing a non-test database'
    : false;

const BASE = { lat: 24.7136, lon: 46.6753 };
const near = (m) => ({ lat: BASE.lat + m / 111_320, lon: BASE.lon });

async function makeUser(pool, name) {
  const { rows } = await pool.query(
    `INSERT INTO sary.users (display_name, token_hash) VALUES ($1, $2) RETURNING id`,
    [name, crypto.randomBytes(32)],
  );
  return rows[0].id;
}

async function boot(t) {
  const pool = createPool(URL_);
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await migrate(pool);
  const cameras = createCameras({ pool });
  // token "u:<id>" → that user; anything else → null (anonymous)
  const authenticate = async (tok) => (tok?.startsWith('u:') ? { id: tok.slice(2) } : null);
  const app = express();
  app.use('/api/cameras', createCamerasRouter({ cameras, authenticate }));
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => {
    await new Promise((r) => server.close(r));
    await pool.end();
  });
  const api = async (method, path, { token, body } = {}) => {
    const res = await fetch(`${base}/api/cameras${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  return { pool, api };
}

test('GET /api/cameras needs a bbox and returns only in-box cameras', { skip }, async (t) => {
  const { pool, api } = await boot(t);
  const cams = createCameras({ pool });
  await cams.importFeatures([
    { lat: BASE.lat, lon: BASE.lon, source: 'osm', source_id: 'in', speed_limit: 120 },
    { lat: 25.9, lon: 43.0, source: 'osm', source_id: 'out' },
  ]);

  assert.equal((await api('GET', '')).status, 400); // no bbox

  const inside = await api('GET', '?bbox=46.6,24.6,46.8,24.8');
  assert.equal(inside.status, 200);
  assert.equal(inside.body.cameras.length, 1);
  assert.equal(inside.body.cameras[0].speed_limit, 120);
  assert.ok(!('source_id' in inside.body.cameras[0]));
});

test('POST /report promotes after three users, confirm and dismiss move confidence', { skip }, async (t) => {
  const { pool, api } = await boot(t);
  const u1 = await makeUser(pool, 'أ');
  const u2 = await makeUser(pool, 'ب');
  const u3 = await makeUser(pool, 'ج');

  const a = await api('POST', '/report', { token: `u:${u1}`, body: { ...BASE, kind: 'fixed' } });
  assert.equal(a.status, 201);
  assert.equal(a.body.report.status, 'pending');

  await api('POST', '/report', { token: `u:${u2}`, body: { ...near(15), kind: 'fixed' } });
  const c = await api('POST', '/report', { token: `u:${u3}`, body: { ...near(30), kind: 'fixed' } });
  assert.equal(c.body.promoted, true);
  const camId = c.body.camera_id;
  assert.ok(camId);

  // the layer now shows it
  const layer = await api('GET', '?bbox=46.6,24.6,46.8,24.8');
  assert.equal(layer.body.cameras.length, 1);
  const before = layer.body.cameras[0].confidence;

  const conf = await api('POST', `/${camId}/confirm`);
  assert.equal(conf.status, 200);
  assert.ok(conf.body.camera.confidence >= before);

  const dis = await api('POST', `/${camId}/dismiss`);
  assert.equal(dis.status, 200);

  assert.equal((await api('POST', `/00000000-0000-0000-0000-000000000000/confirm`)).status, 404);
});

test('an anonymous report with a bad coordinate is a 400 and stores nothing', { skip }, async (t) => {
  const { pool, api } = await boot(t);
  const r = await api('POST', '/report', { body: { lat: 'x', lon: 999 } });
  assert.equal(r.status, 400);
  assert.equal((await pool.query('SELECT count(*)::int n FROM sary.camera_reports')).rows[0].n, 0);
});

test('with no service the router answers 503 cameras_unconfigured', { skip: false }, async (t) => {
  const app = express();
  app.use('/api/cameras', createCamerasRouter({ cameras: null }));
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => server.close(r)));
  const res = await fetch(`http://127.0.0.1:${server.address().port}/api/cameras?bbox=1,1,2,2`);
  assert.equal(res.status, 503);
  assert.equal((await res.json()).error, 'cameras_unconfigured');
});
