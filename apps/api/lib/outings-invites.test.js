'use strict';

/**
 * «دعوة شخصية» — personal, single-use invites, over a real Postgres and the
 * real router (HTTP), next to the legacy open group link.
 *
 *   SARY_TEST_DATABASE_URL=postgres://… node --test apps/api/lib/outings-invites.test.js
 *
 * Uses its own database (`<db>_sary_invites`) so it can run in parallel with
 * the other outings tests. Skipped without that variable.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');
const { Pool } = require('pg');
const { createPool, migrate } = require('./outings/db');
const { setupOutings } = require('./outings');
const { inviteStatus, phoneDigest, last4 } = require('./outings/invites');
const v = require('./outings/validate');

const URL_ = process.env.SARY_TEST_DATABASE_URL;
const skip = !URL_ ? 'set SARY_TEST_DATABASE_URL to run' : !/test|localhost|127\.0\.0\.1/.test(URL_) ? 'refusing a non-test database' : false;

test('invite status and phone helpers (pure)', () => {
  const t = Date.parse('2026-11-05T10:00:00Z');
  const base = { expires_at: '2026-11-06T10:00:00Z' };
  assert.equal(inviteStatus(base, t), 'sent');
  assert.equal(inviteStatus({ ...base, opened_at: '2026-11-05T10:01:00Z' }, t), 'opened');
  assert.equal(inviteStatus({ ...base, consumed_at: '2026-11-05T10:02:00Z' }, t), 'joined');
  assert.equal(inviteStatus({ ...base, consumed_at: 'x', revoked_at: 'y' }, t), 'joined', 'a used invite stays «انضم» after revoke');
  assert.equal(inviteStatus({ ...base, revoked_at: 'y' }, t), 'revoked');
  assert.equal(inviteStatus({ expires_at: '2026-11-05T09:00:00Z' }, t), 'expired');
  assert.equal(last4('+966501234567'), '4567');
  assert.notEqual(phoneDigest('a', '+966501234567'), phoneDigest('b', '+966501234567'), 'salted per trip');
  assert.equal(v.phone('+966 0501234567'), '+966501234567', 'contacts often keep the 0 after +966');
  assert.equal(v.phone('٠٥٠١٢٣٤٥٦٧'), '+966501234567');
});

async function isolatedDb(url) {
  const u = new URL(url);
  const name = `${u.pathname.replace(/^\//, '') || 'postgres'}_sary_invites`.replace(/[^a-z0-9_]/gi, '_');
  const admin = new Pool({ connectionString: url, max: 1 });
  const { rows } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [name]);
  if (!rows.length) await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  u.pathname = `/${name}`;
  return u.toString();
}

test('personal invites — single use, rejoin, other identity, revoke, resend, expiry, legacy open links', { skip, timeout: 60_000 }, async (t) => {
  const pool = createPool(await isolatedDb(URL_));
  await pool.query('DROP SCHEMA IF EXISTS sary CASCADE');
  const applied = await migrate(pool);
  assert.ok(applied.includes('011_sary_personal_invites.sql'));

  const outings = setupOutings({ pool, autoMigrate: false, config: { minFixIntervalMs: 0, persistEveryMs: 0 }, limits: { invitePer10Min: 1000, identityPerHour: 1000 } });
  const app = express();
  app.use(express.json());
  app.use('/api/outings', outings.router);
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  outings.attach(server);
  const base = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => {
    outings.close();
    await new Promise((r) => server.close(r));
    await pool.end();
  });

  async function api(method, path, token, body) {
    const res = await fetch(`${base}/api/outings${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json().catch(() => null) };
  }
  async function person(name) {
    const r = await api('POST', '/me', null, { display_name: name });
    assert.equal(r.status, 201, JSON.stringify(r.body));
    return { token: r.body.token, id: r.body.user.id };
  }

  const leader = await person('أبو فهد');
  const fahd = await person('جوس');
  const stranger = await person('أبو مدري مين');
  const saad = await person('سعد');

  /* A new-client trip: personal only, no open link. */
  const made = await api('POST', '/', leader.token, { name: 'طلعة الثمامة', invites: 'personal' });
  assert.equal(made.status, 201);
  assert.equal(made.body.invite, null, 'no open link is minted');
  assert.equal(made.body.open_links, false);
  const oid = made.body.outing_id;
  await api('POST', `/${oid}/status`, leader.token, { action: 'start' });

  /* Only a leader invites; the name is required, the phone is normalised. */
  assert.equal((await api('POST', `/${oid}/invites/personal`, leader.token, { name: '' })).body.error, 'invalid_invitee_name');
  assert.equal((await api('POST', `/${oid}/invites/personal`, leader.token, { name: 'فهد', phone: '123' })).body.error, 'invalid_phone');
  const inv = await api('POST', `/${oid}/invites/personal`, leader.token, { name: 'فهد أخوي', phone: '0501234567' });
  assert.equal(inv.status, 201, JSON.stringify(inv.body));
  const fahdInvite = inv.body.invite;
  assert.equal(fahdInvite.invitee_name, 'فهد أخوي');
  assert.equal(fahdInvite.phone_last4, '4567');
  assert.equal(fahdInvite.status, 'sent');
  assert.ok(v.isSecretShaped(fahdInvite.token));
  const stored = (await pool.query(`SELECT invitee_phone_hash, invitee_phone_last4, kind FROM sary.outing_invites WHERE id = $1`, [fahdInvite.id])).rows[0];
  assert.equal(stored.kind, 'personal');
  assert.match(stored.invitee_phone_hash, /^[0-9a-f]{64}$/, 'only a digest of the number');
  const dump = JSON.stringify((await pool.query(`SELECT * FROM sary.outing_invites`)).rows);
  assert.ok(!dump.includes('0501234567') && !dump.includes('966501234567'), 'the full number is never stored');

  /* The open group link is off for this trip: old-client «رابط جديد» refuses. */
  assert.equal((await api('POST', `/${oid}/invites`, leader.token, {})).body.error, 'open_links_disabled');

  /* The leader looking at their own link does not mark it opened, nor use it. */
  const own = await api('POST', '/invites/preview', leader.token, { token: fahdInvite.token });
  assert.equal(own.body.invite.already_member, true);
  assert.equal((await api('POST', '/invites/join', leader.token, { token: fahdInvite.token })).body.already, true);
  let list = (await api('GET', `/${oid}/invites/personal`, leader.token)).body.invites;
  assert.equal(list[0].status, 'sent', 'still «أُرسلت»');

  /* Fahd opens it (anonymous preview, like the web page) → «فتحها». */
  const pv = await api('POST', '/invites/preview', null, { token: fahdInvite.token });
  assert.equal(pv.status, 200);
  assert.equal(pv.body.invite.kind, 'personal');
  assert.equal(pv.body.invite.invitee_name, 'فهد أخوي');
  assert.equal(pv.body.invite.claim, 'open');
  list = (await api('GET', `/${oid}/invites/personal`, leader.token)).body.invites;
  assert.equal(list[0].status, 'opened');

  /* Fahd joins: he is «فهد أخوي» in this trip, his own name is the nickname. */
  const j = await api('POST', '/invites/join', fahd.token, { token: fahdInvite.token });
  assert.equal(j.status, 200, JSON.stringify(j.body));
  assert.equal(j.body.already, false);
  let snap = (await api('GET', `/${oid}`, leader.token)).body;
  const fm = snap.members.find((m) => m.user_id === fahd.id);
  assert.equal(fm.display_name, 'فهد أخوي');
  assert.equal(fm.nickname, 'جوس');
  assert.equal(fm.invited, true);
  assert.equal(fm.phone_last4, '4567');
  assert.equal(snap.personal_invites[0].status, 'joined');
  assert.equal(snap.personal_invites[0].member_user_id, fahd.id);
  assert.equal(snap.invite.open_links, false);
  assert.equal(snap.invite.active, false);
  const leaderRow = snap.members.find((m) => m.user_id === leader.id);
  assert.equal(leaderRow.display_name, 'أبو فهد');
  assert.equal(leaderRow.invited, false);

  /* Members (not only the leader) see the same name; non-leaders get no invite list. */
  const fahdView = (await api('GET', `/${oid}`, fahd.token)).body;
  assert.equal(fahdView.members.find((m) => m.user_id === fahd.id).display_name, 'فهد أخوي');
  assert.equal(fahdView.personal_invites, null);
  assert.equal((await api('GET', `/${oid}/invites/personal`, fahd.token)).body.error, 'leader_only');

  /* Renaming himself changes only the nickname inside this trip. */
  await api('PATCH', '/me', fahd.token, { display_name: 'فهودي' });
  snap = (await api('GET', `/${oid}`, leader.token)).body;
  assert.deepEqual(
    (({ display_name, nickname }) => ({ display_name, nickname }))(snap.members.find((m) => m.user_id === fahd.id)),
    { display_name: 'فهد أخوي', nickname: 'فهودي' },
  );

  /* Single use: someone else with the same link → «هذه الدعوة لشخص آخر». */
  const taken = await api('POST', '/invites/join', stranger.token, { token: fahdInvite.token });
  assert.equal(taken.status, 409);
  assert.equal(taken.body.error, 'invite_taken');
  assert.equal((await api('POST', '/invites/preview', stranger.token, { token: fahdInvite.token })).body.invite.claim, 'taken');
  assert.equal((await api('POST', '/invites/preview', fahd.token, { token: fahdInvite.token })).body.invite.claim, 'yours');
  assert.equal((await api('POST', '/invites/preview', null, { token: fahdInvite.token })).body.invite.claim, 'claimed');

  /* Rejoin: same identity re-opens → fine; after leaving → back in, still «فهد أخوي». */
  assert.equal((await api('POST', '/invites/join', fahd.token, { token: fahdInvite.token })).body.already, true);
  assert.equal((await api('POST', `/${oid}/leave`, fahd.token)).status, 200);
  const back = await api('POST', '/invites/join', fahd.token, { token: fahdInvite.token });
  assert.equal(back.status, 200, JSON.stringify(back.body));
  assert.equal(back.body.already, false);
  snap = (await api('GET', `/${oid}`, leader.token)).body;
  assert.equal(snap.members.find((m) => m.user_id === fahd.id).display_name, 'فهد أخوي');
  assert.equal(snap.members.filter((m) => m.user_id === fahd.id).length, 1);
  const uses = (await pool.query(`SELECT uses, consumed_by FROM sary.outing_invites WHERE id = $1`, [fahdInvite.id])).rows[0];
  assert.equal(uses.consumed_by, fahd.id);
  assert.equal(uses.uses, 2);

  /* A used invite cannot be re-sent. */
  assert.equal((await api('POST', `/${oid}/invites/personal/${fahdInvite.id}/resend`, leader.token, {})).body.error, 'invite_used');

  /* Revoke: an unused invite stops working at once. */
  const saadInv = (await api('POST', `/${oid}/invites/personal`, leader.token, { name: 'سعد ولد عمي', phone: '+966 55 000 1111' })).body.invite;
  const rv = await api('DELETE', `/${oid}/invites/personal/${saadInv.id}`, leader.token);
  assert.equal(rv.body.invite.status, 'revoked');
  assert.equal((await api('POST', '/invites/join', saad.token, { token: saadInv.token })).body.error, 'invite_revoked');
  assert.equal((await api('POST', '/invites/preview', null, { token: saadInv.token })).status, 410);

  /* Resend: a fresh token for the same person; the old one is dead; one line in the list. */
  const rs = await api('POST', `/${oid}/invites/personal/${saadInv.id}/resend`, leader.token, {});
  assert.equal(rs.status, 201, JSON.stringify(rs.body));
  assert.notEqual(rs.body.invite.token, saadInv.token);
  assert.equal(rs.body.invite.invitee_name, 'سعد ولد عمي');
  assert.equal(rs.body.invite.phone_last4, '1111');
  assert.equal(rs.body.invite.status, 'sent');
  assert.equal((await api('POST', `/${oid}/invites/personal/${saadInv.id}/resend`, leader.token, {})).body.error, 'invite_replaced');
  list = (await api('GET', `/${oid}/invites/personal`, leader.token)).body.invites;
  assert.equal(list.filter((i) => i.invitee_name === 'سعد ولد عمي').length, 1, 'one line per person');

  /* Inviting the same number again supersedes the unused link. */
  const again = (await api('POST', `/${oid}/invites/personal`, leader.token, { name: 'سعد', phone: '0550001111' })).body;
  assert.equal(again.replaced, rs.body.invite.id);
  assert.equal((await api('POST', '/invites/join', saad.token, { token: rs.body.invite.token })).body.error, 'invite_revoked');

  /* Expiry (existing rules): an expired unused invite is refused. */
  const exp = (await api('POST', `/${oid}/invites/personal`, leader.token, { name: 'ناصر', ttl_hours: 1 })).body.invite;
  assert.equal(exp.phone_last4, null, 'the phone is optional');
  await pool.query(`UPDATE sary.outing_invites SET expires_at = now() - interval '1 minute' WHERE id = $1`, [exp.id]);
  assert.equal((await api('POST', '/invites/join', saad.token, { token: exp.token })).body.error, 'invite_expired');
  list = (await api('GET', `/${oid}/invites/personal`, leader.token)).body.invites;
  const expRow = list.find((i) => i.id === exp.id);
  assert.equal(expRow.status, 'expired');
  assert.equal(expRow.opened, false, '«لم يفتحها»');
  /* …but its owner, already in, is not thrown out by expiry: Fahd re-opening his
   * (now expired) link is still «already». */
  await pool.query(`UPDATE sary.outing_invites SET expires_at = now() - interval '1 minute' WHERE id = $1`, [fahdInvite.id]);
  assert.equal((await api('POST', '/invites/join', fahd.token, { token: fahdInvite.token })).body.already, true);
  assert.equal((await api('POST', '/invites/join', stranger.token, { token: fahdInvite.token })).body.error, 'invite_taken');

  /* The join lock covers personal invites too. */
  const lockInv = (await api('POST', `/${oid}/invites/personal`, leader.token, { name: 'سعد' })).body.invite;
  await api('POST', `/${oid}/lock`, leader.token, { locked: true });
  assert.equal((await api('POST', '/invites/join', saad.token, { token: lockInv.token })).body.error, 'join_locked');
  await api('POST', `/${oid}/lock`, leader.token, { locked: false });
  assert.equal((await api('POST', '/invites/join', saad.token, { token: lockInv.token })).status, 200);

  /* ---- Legacy: a build 9–11 trip with an open group link keeps working. ---- */
  const legacy = await api('POST', '/', leader.token, { name: 'طلعة قديمة' });
  assert.ok(legacy.body.invite?.token, 'open link as before');
  const lid = legacy.body.outing_id;
  const groupTok = legacy.body.invite.token;
  const gp = await api('POST', '/invites/preview', null, { token: groupTok });
  assert.equal(gp.body.invite.kind, 'group');
  assert.equal(gp.body.invite.claim, 'open');
  assert.equal((await api('POST', '/invites/join', stranger.token, { token: groupTok })).status, 200);
  assert.equal((await api('POST', '/invites/join', saad.token, { token: groupTok })).status, 200, 'open links are multi-use');
  snap = (await api('GET', `/${lid}`, leader.token)).body;
  const sm = snap.members.find((m) => m.user_id === stranger.id);
  assert.equal(sm.display_name, 'أبو مدري مين', 'open-link joiners keep their own name');
  assert.equal(sm.invited, false);
  assert.equal(snap.invite.open_links, true);
  assert.equal(snap.invite.active, true);

  /* Personal invites live beside the open link; rotating the open link leaves them alone. */
  const pIn = (await api('POST', `/${lid}/invites/personal`, leader.token, { name: 'فهد أخوي' })).body.invite;
  const rot = await api('POST', `/${lid}/invites`, leader.token, {});
  assert.equal(rot.status, 201);
  assert.equal((await api('POST', '/invites/preview', null, { token: groupTok })).body.error, 'invite_revoked');
  assert.equal((await api('POST', '/invites/preview', null, { token: pIn.token })).status, 200, 'personal untouched by rotate');
  await api('DELETE', `/${lid}/invites`, leader.token);
  assert.equal((await api('POST', '/invites/preview', null, { token: pIn.token })).status, 200, 'personal untouched by «إيقاف الرابط»');

  /* The leader turns open links off: the open link dies, personal invites still work. */
  const rot2 = (await api('POST', `/${lid}/invites`, leader.token, {})).body.invite;
  assert.equal((await api('PATCH', `/${lid}/invites/settings`, stranger.token, { open_links: false })).body.error, 'leader_only');
  assert.equal((await api('PATCH', `/${lid}/invites/settings`, leader.token, { open_links: 'no' })).body.error, 'invalid_open_links');
  assert.deepEqual((await api('PATCH', `/${lid}/invites/settings`, leader.token, { open_links: false })).body, { ok: true, open_links: false });
  const late = await person('متأخر');
  assert.equal((await api('POST', '/invites/join', late.token, { token: rot2.token })).body.error, 'invite_revoked');
  assert.equal((await api('POST', '/invites/join', late.token, { token: pIn.token })).status, 200);
  snap = (await api('GET', `/${lid}`, leader.token)).body;
  assert.equal(snap.members.find((m) => m.user_id === late.id).display_name, 'فهد أخوي');
  /* …and back on: a new open link can be made again. */
  await api('PATCH', `/${lid}/invites/settings`, leader.token, { open_links: true });
  assert.equal((await api('POST', `/${lid}/invites`, leader.token, {})).status, 201);

  /* A row from before 011 (no kind column then) is a group link: still works,
   * unless the trip's open links are off. */
  const oldTok = v.newSecret();
  await pool.query(
    `INSERT INTO sary.outing_invites (outing_id, token_hash, created_by, expires_at) VALUES ($1, $2, $3, now() + interval '1 hour')`,
    [lid, v.digest(oldTok), leader.id],
  );
  assert.equal((await api('POST', '/invites/preview', null, { token: oldTok })).body.invite.kind, 'group');
  await api('PATCH', `/${lid}/invites/settings`, leader.token, { open_links: false });
  assert.equal((await api('POST', '/invites/preview', null, { token: oldTok })).body.error, 'invite_revoked');

  /* Ending the trip ends every invite. */
  await api('POST', `/${oid}/status`, leader.token, { action: 'end' });
  const afterEnd = await person('بعد النهاية');
  assert.equal((await api('POST', '/invites/join', afterEnd.token, { token: again.invite.token })).body.error, 'invite_revoked');
  assert.equal((await api('POST', `/${oid}/invites/personal`, leader.token, { name: 'أحد' })).body.error, 'outing_ended');

  /* Deleting the consumer's account does not free the link for someone else. */
  const t3 = await api('POST', '/', leader.token, { name: 'ثالثة', invites: 'personal' });
  const i3 = (await api('POST', `/${t3.body.outing_id}/invites/personal`, leader.token, { name: 'مؤقت' })).body.invite;
  const temp = await person('مؤقت');
  assert.equal((await api('POST', '/invites/join', temp.token, { token: i3.token })).status, 200);
  assert.equal((await api('DELETE', '/me', temp.token)).status, 200);
  assert.equal((await api('POST', '/invites/join', stranger.token, { token: i3.token })).body.error, 'invite_taken');
});
