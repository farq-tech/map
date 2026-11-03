'use strict';

/**
 * Recovery codes, co-leaders («مساعد») and the join lock — over a real
 * Postgres, the real router and real WebSockets.
 *
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-accounts.test.js
 *
 * Runs in its own database (`<db>_sary_accounts`, created on demand) so it can
 * run in parallel with outings-integration.test.js, which drops `sary`.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');
const WebSocket = require('ws');
const { Pool } = require('pg');
const { createPool, migrate } = require('./outings/db');
const { setupOutings } = require('./outings');
const { canLead } = require('./outings/service');
const v = require('./outings/validate');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;

test('recovery codes — shape and parsing', () => {
  const code = v.newRecoveryCode();
  assert.match(code, /^([0-9A-HJKMNP-TV-Z]{4}-){6}[0-9A-HJKMNP-TV-Z]{4}$/);
  const p = v.recoveryCode(code);
  assert.equal(p.selector.length, 8);
  assert.equal(p.verifier.length, 20);
  assert.deepEqual(v.recoveryCode(` ${code.toLowerCase().replace(/-/g, ' ')} `), p, 'spaces and case are forgiven');
  assert.deepEqual(v.recoveryCode(code.replace(/0/g, 'O').replace(/1/g, 'I')), p, 'O/0 and I/1 look-alikes');
  assert.equal(v.recoveryCode(code.slice(0, -1)), null, 'too short');
  assert.equal(v.recoveryCode(`${code}A`), null, 'too long');
  assert.equal(v.recoveryCode(code.replace(/^./, 'U')), null, 'U is not in the alphabet');
  assert.equal(v.recoveryCode(12), null);
  assert.notEqual(v.newRecoveryCode(), v.newRecoveryCode());
  assert.equal(v.sameDigest(v.digest('a'), v.digest('a')), true);
  assert.equal(v.sameDigest(v.digest('a'), v.digest('b')), false);
  assert.equal(v.sameDigest(v.digest('a'), Buffer.alloc(3)), false, 'length mismatch is just false');
});

test('canLead', () => {
  assert.equal(canLead({ status: 'active', role: 'owner', co_leader: false }), true);
  assert.equal(canLead({ status: 'active', role: 'member', co_leader: true }), true);
  assert.equal(canLead({ status: 'active', role: 'member', co_leader: false }), false);
  assert.equal(canLead({ status: 'left', role: 'member', co_leader: true }), false);
  assert.equal(canLead(null), false);
});

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_accounts`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

test('accounts, co-leaders and join lock', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(await isolatedDb(URL_));
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  const applied = await migrate(pool);
  assert.ok(applied.includes('004_sary_accounts.sql'));

  const outings = setupOutings({
    pool,
    autoMigrate: false,
    config: { minFixIntervalMs: 0, persistEveryMs: 0 },
    limits: { recoverPer15Min: 6 },
  });
  const app = express();
  app.use(express.json());
  app.use('/api/outings', outings.router);
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  outings.attach(server);
  const base = `http://127.0.0.1:${server.address().port}`;
  const wsUrl = `ws://127.0.0.1:${server.address().port}/api/outings/live`;
  t.after(async () => {
    outings.close();
    await new Promise((r) => server.close(r));
    await pool.end();
  });

  let ip = 0;
  async function api(method, path, token, body, { from } = {}) {
    const res = await fetch(`${base}/api/outings${path}`, {
      method,
      headers: {
        'content-type': 'application/json',
        /* A distinct client per call unless a test pins one, so per-IP limits do not leak between steps. */
        'x-forwarded-for': from || `10.0.0.${(ip += 1) % 250}`,
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  }

  function live(token, outingId) {
    const ws = new WebSocket(wsUrl);
    const inbox = [];
    ws.on('message', (d) => inbox.push(JSON.parse(String(d))));
    const closed = new Promise((r) => ws.on('close', (code) => r({ code })));
    const opened = new Promise((r) => ws.on('open', r)).then(() => ws.send(JSON.stringify({ type: 'auth', token, outing_id: outingId })));
    const next = async (pred, ms = 4000) => {
      const until = Date.now() + ms;
      while (Date.now() < until) {
        const i = inbox.findIndex(pred);
        if (i >= 0) return inbox.splice(i, 1)[0];
        await new Promise((r) => setTimeout(r, 20));
      }
      throw new Error('timeout waiting for message');
    };
    return { ws, closed, opened, next };
  }

  /* ---------------- recovery ---------------- */
  const a = await api('POST', '/me', null, { display_name: 'أبو فهد' });
  const A0 = a.body.token;
  const aId = a.body.user.id;
  assert.deepEqual((await api('GET', '/me', A0)).body.recovery, { active: false, created_at: null });

  const made = await api('POST', '/me/recovery', A0);
  assert.equal(made.status, 201);
  const code = made.body.recovery.code;
  assert.match(code, /^[0-9A-Z]{4}(-[0-9A-Z]{4}){6}$/);
  assert.equal((await api('GET', '/me', A0)).body.recovery.active, true);
  assert.equal((await api('POST', '/me/recovery', null)).status, 401, 'needs the device token');

  /* Only the selector and a digest are stored — never the code. */
  const [stored] = (await pool.query('SELECT recovery_selector, recovery_hash FROM sary.users WHERE id = $1', [aId])).rows;
  const parsed = v.recoveryCode(code);
  assert.equal(stored.recovery_selector, parsed.selector);
  assert.equal(stored.recovery_hash.length, 32);
  assert.ok(!stored.recovery_hash.equals(Buffer.from(parsed.verifier)));
  const dump = JSON.stringify((await pool.query('SELECT * FROM sary.users')).rows);
  assert.ok(!dump.includes(parsed.verifier), 'verifier is not in the table');

  /* An outing A owns, with B in it, to prove recovery keeps memberships. */
  const created = await api('POST', '/', A0, { name: 'طلعة الثمامة' });
  const outingId = created.body.outing_id;
  const b = await api('POST', '/me', null, { display_name: 'خويي سعد' });
  const B = b.body.token;
  const bId = b.body.user.id;
  assert.equal((await api('POST', '/invites/join', B, { token: created.body.invite.token })).status, 200);

  /* The old device is live on the outing when the code is redeemed elsewhere. */
  const oldDevice = live(A0, outingId);
  await oldDevice.opened;
  await oldDevice.next((m) => m.type === 'ready');

  /* Wrong codes: right selector + wrong verifier, unknown selector, garbage. */
  const wrong = `${parsed.selector}${'0'.repeat(20)}`;
  assert.deepEqual((await api('POST', '/me/recover', null, { code: wrong })).body, { ok: false, error: 'recovery_invalid' });
  assert.equal((await api('POST', '/me/recover', null, { code: v.newRecoveryCode() })).status, 400);
  assert.equal((await api('POST', '/me/recover', null, { code: 'hello' })).status, 400);
  assert.equal((await api('GET', '/me', A0)).status, 200, 'failed attempts change nothing');

  const rec = await api('POST', '/me/recover', null, { code: code.toLowerCase() });
  assert.equal(rec.status, 200);
  assert.equal(rec.body.user.id, aId, 'same person');
  assert.equal(rec.body.user.display_name, 'أبو فهد');
  const A = rec.body.token;
  assert.notEqual(A, A0);
  assert.equal((await api('GET', '/me', A0)).status, 401, 'old device token is revoked at once');
  assert.equal((await oldDevice.closed).code, 4401, 'old device socket is dropped');
  assert.equal((await api('GET', `/${outingId}`, A)).body.me.role, 'owner', 'memberships carry over');
  assert.equal((await api('POST', '/me/recover', null, { code })).status, 400, 'a code works once');
  assert.equal((await api('GET', '/me', A)).body.recovery.active, false, 'consumed; save a new one');

  /* A new code replaces the old one. */
  const c1 = (await api('POST', '/me/recovery', A)).body.recovery.code;
  const c2 = (await api('POST', '/me/recovery', A)).body.recovery.code;
  assert.equal((await api('POST', '/me/recover', null, { code: c1 })).status, 400, 'replaced code is dead');

  /* Rate limit per client (6 here): the 7th try is refused even with the right code. */
  for (let i = 0; i < 6; i += 1) await api('POST', '/me/recover', null, { code: v.newRecoveryCode() }, { from: '203.0.113.9' });
  assert.equal((await api('POST', '/me/recover', null, { code: c2 }, { from: '203.0.113.9' })).status, 429);
  assert.equal((await api('GET', '/me', A)).status, 200, 'a refused attempt does not rotate anything');

  /* ---------------- co-leader ---------------- */
  const c = await api('POST', '/me', null, { display_name: 'ثالث' });
  const C = c.body.token;
  const cId = c.body.user.id;
  const inv = (await api('POST', `/${outingId}/invites`, A)).body.invite.token;
  assert.equal((await api('POST', '/invites/join', C, { token: inv })).status, 200);

  assert.equal((await api('POST', `/${outingId}/status`, B, { action: 'start' })).status, 403, 'a plain member cannot start');
  assert.equal((await api('POST', `/${outingId}/invites`, B)).status, 403);
  assert.equal((await api('GET', `/${outingId}`, B)).body.invite, null, 'members do not see invite state');
  assert.equal((await api('POST', `/${outingId}/members/${cId}/co-leader`, B, { co_leader: true })).status, 403, 'only the owner appoints');
  assert.equal((await api('POST', `/${outingId}/members/${aId}/co-leader`, A, { co_leader: true })).status, 400, 'owner is already the leader');
  assert.equal((await api('POST', `/${outingId}/members/${bId}/co-leader`, A, { co_leader: 'yes' })).status, 400);

  const lc = live(C, outingId);
  await lc.opened;
  await lc.next((m) => m.type === 'ready');
  const made2 = await api('POST', `/${outingId}/members/${bId}/co-leader`, A, { co_leader: true });
  assert.deepEqual(made2.body, { ok: true, user_id: bId, co_leader: true });
  assert.deepEqual(await lc.next((m) => m.type === 'member_role'), { type: 'member_role', user_id: bId, co_leader: true });

  const snapB = (await api('GET', `/${outingId}`, B)).body;
  assert.equal(snapB.me.co_leader, true);
  assert.equal(snapB.me.can_lead, true);
  assert.equal(snapB.me.role, 'member', 'role keeps its meaning');
  assert.ok(snapB.invite, 'co-leader sees invite state');
  assert.equal(snapB.members.find((m) => m.user_id === bId).co_leader, true);

  const started = await api('POST', `/${outingId}/status`, B, { action: 'start' });
  assert.equal(started.body.outing.status, 'active', 'co-leader starts the outing');
  assert.equal((await lc.next((m) => m.type === 'outing_status')).status, 'active');
  assert.equal((await api('POST', `/${outingId}/status`, B, { action: 'pause' })).body.outing.status, 'paused');
  assert.equal((await api('POST', `/${outingId}/status`, B, { action: 'resume' })).body.outing.status, 'active');
  assert.equal((await api('POST', `/${outingId}/status`, B, { action: 'end' })).status, 403, 'ending stays with the owner');
  const rotated = await api('POST', `/${outingId}/invites`, B);
  assert.equal(rotated.status, 201, 'co-leader rotates the link');
  assert.equal((await api('POST', '/invites/preview', null, { token: inv })).status, 410, 'old link died');
  assert.equal((await api('DELETE', `/${outingId}/invites`, B)).body.revoked, 1, 'co-leader revokes');
  assert.equal((await api('DELETE', `/${outingId}/members/${cId}`, B)).status, 403, 'removing stays with the owner');
  assert.equal((await api('POST', `/${outingId}/lock`, B, { locked: true })).status, 403, 'locking stays with the owner');
  /* Rally point (#24) uses the same leader rule: a co-leader may place it, a plain member may not. */
  const rallyB = await api('PUT', `/${outingId}/rally`, B, { lat: 24.8, lng: 46.7, label: 'عند الطلح' });
  assert.equal(rallyB.status, 200, 'co-leader sets the rally point');
  assert.equal(rallyB.body.rally.set_by, bId);
  assert.equal((await lc.next((m) => m.type === 'rally')).rally.label, 'عند الطلح', 'members hear it');
  assert.equal((await api('PUT', `/${outingId}/rally`, C, { lat: 24.8, lng: 46.7 })).status, 403, 'members still cannot');
  assert.equal((await api('DELETE', `/${outingId}/rally`, B)).status, 200, 'co-leader clears it');

  /* Taking it back: B is a member again, server-side, at once. */
  await api('POST', `/${outingId}/members/${bId}/co-leader`, A, { co_leader: false });
  assert.equal((await api('POST', `/${outingId}/status`, B, { action: 'pause' })).status, 403);
  assert.equal((await api('PUT', `/${outingId}/rally`, B, { lat: 24.8, lng: 46.7 })).status, 403, 'no longer a leader: no rally point');

  /* ---------------- join lock ---------------- */
  const link = (await api('POST', `/${outingId}/invites`, A)).body.invite.token;
  const d = await api('POST', '/me', null, { display_name: 'متأخر' });
  const D = d.body.token;
  const locked = await api('POST', `/${outingId}/lock`, A, { locked: true });
  assert.deepEqual(locked.body, { ok: true, join_locked: true });
  assert.equal((await lc.next((m) => m.type === 'outing_lock')).join_locked, true);
  assert.equal((await api('GET', `/${outingId}`, C)).body.outing.join_locked, true);
  assert.equal((await api('POST', `/${outingId}/lock`, A, { locked: 'yes' })).status, 400);

  const pv = await api('POST', '/invites/preview', null, { token: link });
  assert.equal(pv.status, 200);
  assert.equal(pv.body.invite.join_locked, true, 'the invitee learns why before typing a name');
  assert.deepEqual((await api('POST', '/invites/join', D, { token: link })).body, { ok: false, error: 'join_locked' });
  assert.equal((await api('POST', '/invites/join', C, { token: link })).body.already, true, 'members already in are unaffected');
  /* Leaving and coming back is a new join, so the lock holds against it too. */
  await api('POST', `/${outingId}/leave`, C);
  assert.equal((await api('POST', '/invites/join', C, { token: link })).status, 403);

  await api('POST', `/${outingId}/lock`, A, { locked: false });
  assert.equal((await api('POST', '/invites/join', D, { token: link })).status, 200, 'unlocked: joins again');

  /* ---------------- succession prefers a co-leader ---------------- */
  const dId = d.body.user.id;
  await api('POST', `/${outingId}/members/${dId}/co-leader`, A, { co_leader: true });
  assert.equal((await api('POST', `/${outingId}/leave`, A)).body.owner, dId, 'the co-leader inherits, not the earliest member');
  const snapD = (await api('GET', `/${outingId}`, D)).body;
  assert.equal(snapD.me.role, 'owner');
  assert.equal(snapD.me.co_leader, false, 'owner is not also flagged co-leader');
  lc.ws.close();
});
