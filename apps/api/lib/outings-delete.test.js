'use strict';

/**
 * «احذف حسابي» — DELETE /api/outings/me over a real Postgres, the real router
 * and real WebSockets.
 *
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-delete.test.js
 *
 * Runs in its own database (`<db>_sary_delete`, created on demand) so it can
 * run in parallel with outings-integration.test.js, which drops `sary`.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const crypto = require('crypto');
const express = require('express');
const WebSocket = require('ws');
const { Pool } = require('pg');
const { createPool, migrate } = require('./outings/db');
const { setupOutings } = require('./outings');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;

const RIYADH = { lat: 24.7136, lng: 46.6753 };
const fix = (i = 0) => ({ lat: RIYADH.lat + 0.001 * i, lng: RIYADH.lng + 0.001 * i, accuracy: 8, heading: 45, speed: 3, age_ms: 300 });

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_delete`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

test('account deletion — owned + joined outings, hand-over, token dead, others intact', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(await isolatedDb(URL_));
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  await migrate(pool);

  const outings = setupOutings({
    pool,
    autoMigrate: false,
    config: { minFixIntervalMs: 0, persistEveryMs: 0 },
    limits: { identityPerHour: 100, invitePer10Min: 100, deletePerHour: 4 },
  });
  const app = express();
  app.use(express.json());
  app.use('/api/outings', outings.router);
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  outings.attach(server);
  const port = server.address().port;
  t.after(async () => {
    await outings.close();
    await new Promise((r) => server.close(r));
    await pool.end();
  });
  const base = `http://127.0.0.1:${port}/api/outings`;
  const api = async (method, path, token, body) => {
    const res = await fetch(base + path, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  const upload = (token, outingId, buf) =>
    fetch(`${base}/${outingId}/clips`, {
      method: 'POST',
      headers: { 'content-type': 'audio/mp4', 'x-clip-duration-ms': '2000', authorization: `Bearer ${token}` },
      body: buf,
    }).then(async (r) => ({ status: r.status, body: await r.json().catch(() => null) }));
  const mp4 = () => Buffer.concat([Buffer.from([0, 0, 0, 0x18]), Buffer.from('ftypM4A '), Buffer.alloc(2000, 7)]);
  function live(token, outingId) {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/outings/live`);
    const inbox = [];
    ws.on('message', (d) => inbox.push(JSON.parse(String(d))));
    const closed = new Promise((r) => ws.on('close', (code) => r(code)));
    const opened = new Promise((r) => ws.on('open', r)).then(() => ws.send(JSON.stringify({ type: 'auth', token, outing_id: outingId })));
    const until = async (pred, ms = 4000) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        const hit = inbox.find(pred);
        if (hit) return hit;
        await new Promise((r) => setTimeout(r, 20));
      }
      throw new Error('timeout waiting for message');
    };
    return { ws, inbox, opened, closed, until };
  }
  const count = async (sql, params) => (await pool.query(sql, params)).rows[0].n;

  const A = (await api('POST', '/me', null, { display_name: 'أبو فهد' })).body;
  const B = (await api('POST', '/me', null, { display_name: 'سعد' })).body;
  const C = (await api('POST', '/me', null, { display_name: 'نورة' })).body;
  const D = (await api('POST', '/me', null, { display_name: 'خالد' })).body;
  const aId = A.user.id;

  /* O1: A owns an ACTIVE outing; B joined first, C later and is «مساعد» → C inherits. */
  const o1 = (await api('POST', '/', A.token, { name: 'طلعة الثمامة' })).body;
  await api('POST', '/invites/join', B.token, { token: o1.invite.token });
  await api('POST', '/invites/join', C.token, { token: o1.invite.token });
  assert.equal((await api('POST', `/${o1.outing_id}/members/${C.user.id}/co-leader`, A.token, { co_leader: true })).status, 200);
  assert.equal((await api('POST', `/${o1.outing_id}/status`, A.token, { action: 'start' })).status, 200);
  for (const [tok, i] of [[A.token, 0], [B.token, 1], [C.token, 2]]) {
    assert.equal((await api('POST', `/${o1.outing_id}/positions`, tok, { fix: fix(i) })).status, 200);
  }
  assert.equal((await api('POST', `/${o1.outing_id}/note`, A.token, { text: 'بوقف عند المحطة' })).status, 200);
  assert.equal((await api('POST', `/${o1.outing_id}/note`, B.token, { text: 'تمام' })).status, 200);
  assert.equal((await api('POST', `/${o1.outing_id}/sos`, A.token, { fix: null })).status, 200);
  const clipA = await upload(A.token, o1.outing_id, mp4());
  const clipB = await upload(B.token, o1.outing_id, mp4());
  assert.deepEqual([clipA.status, clipB.status], [201, 201]);

  /* O2: B owns, A joined (A is a plain member). */
  const o2 = (await api('POST', '/', B.token, { name: 'طلعة النفود' })).body;
  await api('POST', '/invites/join', A.token, { token: o2.invite.token });
  await api('POST', `/${o2.outing_id}/status`, B.token, { action: 'start' });
  await api('POST', `/${o2.outing_id}/positions`, A.token, { fix: fix(3) });

  /* O3: A owned it alone, ended → nobody else was ever in it: the outing goes too. */
  const o3 = (await api('POST', '/', A.token, { name: 'لحالي' })).body;
  await api('POST', `/${o3.outing_id}/status`, A.token, { action: 'start' });
  await api('POST', `/${o3.outing_id}/status`, A.token, { action: 'end' });

  /* O4: A owned it, D joined, ended; both shared a summary → D inherits, D's summary stays. */
  const o4 = (await api('POST', '/', A.token, { name: 'طلعة العُلا' })).body;
  await api('POST', '/invites/join', D.token, { token: o4.invite.token });
  await api('POST', `/${o4.outing_id}/status`, A.token, { action: 'start' });
  await api('POST', `/${o4.outing_id}/status`, A.token, { action: 'end' });
  const summary = { distance_m: 400, duration_s: 0, moving_s: 0 };
  assert.equal((await api('PUT', `/${o4.outing_id}/summary`, A.token, { summary })).status, 200);
  assert.equal((await api('PUT', `/${o4.outing_id}/summary`, D.token, { summary: { ...summary, distance_m: 300 } })).status, 200);

  /* O5: A owns it alone, not started → leaving ends it, then it is deleted. */
  const o5 = (await api('POST', '/', A.token, { name: 'مسودة' })).body;

  /* Device-bound records: a recovery code, a web push subscription, an APNs token. */
  assert.equal((await api('POST', '/me/recovery', A.token)).status, 201);
  await pool.query(
    `INSERT INTO sary.push_subscriptions (user_id, endpoint, p256dh, auth) VALUES ($1, $2, $3, $4)`,
    [aId, 'https://push.example/a-endpoint', 'p'.repeat(40), 'a'.repeat(16)],
  );
  await pool.query(
    `INSERT INTO sary.apns_tokens (user_id, token, environment, bundle_id) VALUES ($1, $2, 'sandbox', 'sa.sary.albarq')`,
    [aId, crypto.randomBytes(32).toString('hex')],
  );
  await pool.query(
    `INSERT INTO sary.apns_tokens (user_id, token, environment, bundle_id) VALUES ($1, $2, 'sandbox', 'sa.sary.albarq')`,
    [B.user.id, crypto.randomBytes(32).toString('hex')],
  );

  /* Live: B is watching O1, A has a socket open there too. */
  const lb = live(B.token, o1.outing_id);
  const la = live(A.token, o1.outing_id);
  await Promise.all([lb.opened, la.opened]);
  await lb.until((m) => m.type === 'ready');
  await la.until((m) => m.type === 'ready');

  /* --- no token / bad token --- */
  assert.equal((await api('DELETE', '/me', null)).status, 401);

  /* --- delete --- */
  const del = await api('DELETE', '/me', A.token);
  assert.deepEqual([del.status, del.body], [200, { ok: true }]);

  /* The same live events other members get when someone leaves. */
  const left = await lb.until((m) => m.type === 'member_left' && m.user_id === aId);
  assert.equal(left.reason, 'left');
  const owner = await lb.until((m) => m.type === 'owner_changed');
  assert.equal(owner.owner_id, C.user.id, 'the «مساعد» inherits, not the earliest joiner');
  assert.ok((await la.closed) >= 4000, "A's own socket is closed");

  /* --- the token is dead, and stays dead (idempotent: a repeat is 401, not 500) --- */
  assert.equal((await api('GET', '/me', A.token)).status, 401);
  assert.equal((await api('GET', '/', A.token)).status, 401);
  assert.equal((await api('DELETE', '/me', A.token)).status, 401);
  assert.equal((await api('POST', `/${o2.outing_id}/positions`, A.token, { fix: fix(4) })).status, 401);
  const wsAfter = live(A.token, o2.outing_id);
  assert.ok((await wsAfter.closed) >= 4000, 'socket auth refused too');

  /* --- nothing of A is left in the database --- */
  assert.equal(await count(`SELECT count(*)::int AS n FROM sary.users WHERE id = $1`, [aId]), 0, 'hard delete');
  for (const table of ['outing_members', 'member_positions', 'trip_summaries', 'push_subscriptions', 'apns_tokens']) {
    assert.equal(await count(`SELECT count(*)::int AS n FROM sary.${table} WHERE user_id = $1`, [aId]), 0, table);
  }
  assert.equal(await count(`SELECT count(*)::int AS n FROM sary.outings WHERE owner_id = $1 OR rally_set_by = $1`, [aId]), 0);
  assert.equal(await count(`SELECT count(*)::int AS n FROM sary.outing_invites WHERE created_by = $1`, [aId]), 0);
  assert.equal(await count(`SELECT count(*)::int AS n FROM sary.outings WHERE id = ANY($1::uuid[])`, [[o3.outing_id, o5.outing_id]]), 0, 'solo outings are gone');

  /* --- O1: handed over, still active, B's and C's data intact --- */
  const s1 = (await api('GET', `/${o1.outing_id}`, B.token)).body;
  assert.equal(s1.outing.status, 'active');
  assert.equal(s1.outing.owner_id, C.user.id);
  assert.deepEqual(s1.members.map((m) => m.user_id).sort(), [B.user.id, C.user.id].sort());
  assert.equal(s1.members.find((m) => m.user_id === C.user.id).role, 'owner');
  assert.deepEqual(s1.positions.map((p) => p.user_id).sort(), [B.user.id, C.user.id].sort(), 'others keep their fixes');
  assert.equal(s1.members.find((m) => m.user_id === B.user.id).note.text, 'تمام', "B's note stays");
  assert.deepEqual(s1.voice_clips.map((c) => c.id), [clipB.body.clip.id], "A's clip is gone, B's stays");
  assert.equal((await api('GET', `/${o1.outing_id}/clips/${clipA.body.clip.id}`, B.token)).status, 404);
  assert.equal(s1.members.some((m) => m.sos), false, "A's SOS is gone");
  assert.equal((await api('GET', `/${o1.outing_id}`, C.token)).body.me.role, 'owner');
  /* The group's invite link (created by A) keeps working, now under C. */
  const prev = await api('POST', '/invites/preview', null, { token: o1.invite.token });
  assert.equal(prev.status, 200);
  assert.equal(prev.body.invite.owner_name, 'نورة');
  assert.equal((await api('POST', '/invites/join', D.token, { token: o1.invite.token })).status, 200);

  /* --- O2: B's outing untouched apart from A's departure --- */
  const s2 = (await api('GET', `/${o2.outing_id}`, B.token)).body;
  assert.equal(s2.outing.status, 'active');
  assert.equal(s2.outing.owner_id, B.user.id);
  assert.deepEqual(s2.members.map((m) => m.user_id), [B.user.id]);

  /* --- O4: ended outing passes to D; D's summary stays, A's is gone --- */
  const s4 = (await api('GET', `/${o4.outing_id}`, D.token)).body;
  assert.equal(s4.outing.status, 'ended');
  assert.equal(s4.outing.owner_id, D.user.id);
  assert.deepEqual(s4.summaries.map((s) => [s.user_id, s.distance_m]), [[D.user.id, 300]]);

  /* --- other people's device records are intact --- */
  assert.equal(await count(`SELECT count(*)::int AS n FROM sary.apns_tokens WHERE user_id = $1`, [B.user.id]), 1);
  for (const who of [B, C, D]) assert.equal((await api('GET', '/me', who.token)).status, 200);

  /* --- rate limited like the other /me routes: 4/h per address in this test, this is the 5th --- */
  assert.equal((await api('DELETE', '/me', 'x'.repeat(43))).status, 401);
  assert.equal((await api('DELETE', '/me', B.token)).status, 429);
  assert.equal((await api('GET', '/me', B.token)).status, 200, 'a refused delete deletes nothing');

  lb.ws.close();
  wsAfter.ws.close();
});

test('account deletion — a lone owner of an active outing ends it, members of nothing just go', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(await isolatedDb(URL_));
  await migrate(pool);
  const outings = setupOutings({ pool, autoMigrate: false, limits: { identityPerHour: 100, invitePer10Min: 100 } });
  const app = express();
  app.use('/api/outings', outings.router);
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(async () => {
    await outings.close();
    await new Promise((r) => server.close(r));
    await pool.end();
  });
  const api = async (method, path, token, body) => {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/api/outings${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  };

  /* Nothing at all: just the identity. */
  const N = (await api('POST', '/me', null, { display_name: 'جديد' })).body;
  assert.deepEqual((await api('DELETE', '/me', N.token)).body, { ok: true });
  assert.equal((await api('GET', '/me', N.token)).status, 401);

  /* Owner with a member who already left: the outing ends; the ended record passes to the leaver. */
  const P = (await api('POST', '/me', null, { display_name: 'صاحب' })).body;
  const Q = (await api('POST', '/me', null, { display_name: 'زائر' })).body;
  const o = (await api('POST', '/', P.token, { name: 'قصيرة' })).body;
  await api('POST', '/invites/join', Q.token, { token: o.invite.token });
  await api('POST', `/${o.outing_id}/status`, P.token, { action: 'start' });
  await api('POST', `/${o.outing_id}/leave`, Q.token);
  assert.deepEqual((await api('DELETE', '/me', P.token)).body, { ok: true });
  const [row] = (await pool.query(`SELECT status, owner_id FROM sary.outings WHERE id = $1`, [o.outing_id])).rows;
  assert.equal(row.status, 'ended', 'nobody was left, so it ended');
  assert.equal(row.owner_id, Q.user.id);
  const [mq] = (await pool.query(`SELECT role, status FROM sary.outing_members WHERE outing_id = $1 AND user_id = $2`, [o.outing_id, Q.user.id])).rows;
  assert.deepEqual(mq, { role: 'member', status: 'left' }, 'a former member does not become an owner in their own history');
  const hist = (await api('GET', '/', Q.token)).body;
  assert.equal(hist.history.length, 1);
  assert.equal(hist.current.length, 0);
});
