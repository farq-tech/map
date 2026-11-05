'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const http = require('http');
const http2 = require('http2');
const express = require('express');
const {
  apnsConfigFromEnv,
  signApnsJwt,
  parseApnsRegistration,
  apnsRequestFor,
  createApnsSender,
  createApnsNotifier,
  combineNotifiers,
  normalizePem,
  APNS_ORIGINS,
  _resetLoggedOffForTests,
} = require('./outings/apns');
const { pushPayloadFor, createPushNotifier, pushConfigFromEnv } = require('./outings/push');
const createOutingsRouter = require('../routes/outings');

/* A throwaway P-256 key, generated per run: never a real Apple key. */
const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const PEM = privateKey.export({ type: 'pkcs8', format: 'pem' });
const ENV = { APNS_KEY_ID: 'ABC123DEFG', APNS_TEAM_ID: 'MH7J92HV9N', APNS_PRIVATE_KEY: PEM, APNS_BUNDLE_ID: 'sa.sary.albarq' };
const TOKEN = 'a'.repeat(64);
const OUTING = '11111111-1111-4111-8111-111111111111';
const SENDER = '00000000-0000-4000-8000-00000000000a';

function verifyJwt(jwt) {
  const [h, c, s] = jwt.split('.');
  const ok = crypto.verify('sha256', Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url'));
  return { ok, header: JSON.parse(Buffer.from(h, 'base64url')), claims: JSON.parse(Buffer.from(c, 'base64url')) };
}

/* A pool answering the notifier's queries from fixed rows; records every call. */
function fakePool(rows) {
  const calls = [];
  return {
    calls,
    query: async (text, params) => {
      calls.push({ text: text.replace(/\s+/g, ' ').trim(), params });
      if (/^SELECT t\.id/.test(calls.at(-1).text)) return { rows };
      return { rows: [] };
    },
  };
}

/* An h2c stand-in for APNs: answers with whatever `reply` says, records every request. */
async function fakeApns(t, reply) {
  const seen = [];
  const server = http2.createServer();
  server.on('stream', (stream, headers) => {
    let body = '';
    stream.setEncoding('utf8');
    stream.on('data', (c) => (body += c));
    stream.on('end', () => {
      const jwt = String(headers.authorization || '').replace(/^bearer /, '');
      const rec = { headers, body: body ? JSON.parse(body) : null, jwt, token: headers[':path'].split('/').pop() };
      seen.push(rec);
      const r = reply(rec, seen.length);
      stream.respond({ ':status': r.status, 'apns-id': 'id-' + seen.length, ...(r.reason ? { 'content-type': 'application/json' } : {}) });
      stream.end(r.reason ? JSON.stringify({ reason: r.reason }) : undefined);
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => server.close(r)));
  return { seen, origin: `http://127.0.0.1:${server.address().port}` };
}

test('config: off unless all four APNS_* are set and the key is a P-256 private key', () => {
  assert.equal(apnsConfigFromEnv({}).enabled, false);
  assert.deepEqual(apnsConfigFromEnv({}).missing, ['APNS_KEY_ID', 'APNS_TEAM_ID', 'APNS_PRIVATE_KEY', 'APNS_BUNDLE_ID']);
  for (const k of Object.keys(ENV)) {
    const c = apnsConfigFromEnv({ ...ENV, [k]: '' });
    assert.equal(c.enabled, false, `${k} missing`);
    assert.equal(c.key, null, 'no half-config keeps the key');
  }
  assert.equal(apnsConfigFromEnv({ ...ENV, APNS_PRIVATE_KEY: 'not a key' }).reason, 'invalid_key');
  const rsa = crypto.generateKeyPairSync('rsa', { modulusLength: 1024 }).privateKey.export({ type: 'pkcs8', format: 'pem' });
  assert.equal(apnsConfigFromEnv({ ...ENV, APNS_PRIVATE_KEY: rsa }).reason, 'invalid_key', 'only EC P-256');
  assert.equal(apnsConfigFromEnv({ ...ENV, APNS_KEY_ID: 'short' }).reason, 'invalid');
  const on = apnsConfigFromEnv(ENV);
  assert.deepEqual([on.enabled, on.keyId, on.teamId, on.bundleId], [true, 'ABC123DEFG', 'MH7J92HV9N', 'sa.sary.albarq']);
});

test('config: the .p8 may arrive \\n-escaped, quoted, or as a bare base64 body', () => {
  const escaped = PEM.trim().replace(/\n/g, '\\n');
  assert.equal(apnsConfigFromEnv({ ...ENV, APNS_PRIVATE_KEY: escaped }).enabled, true);
  assert.equal(apnsConfigFromEnv({ ...ENV, APNS_PRIVATE_KEY: `"${escaped}"` }).enabled, true);
  const bare = PEM.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  assert.equal(apnsConfigFromEnv({ ...ENV, APNS_PRIVATE_KEY: bare }).enabled, true);
  assert.equal(normalizePem(''), '');
});

test('JWT: ES256, kid + iss + iat, verifiable with the public key', () => {
  const cfg = apnsConfigFromEnv(ENV);
  const jwt = signApnsJwt(cfg, 1_700_000_000);
  const v = verifyJwt(jwt);
  assert.equal(v.ok, true, 'signature verifies (raw r||s, 64 bytes)');
  assert.equal(Buffer.from(jwt.split('.')[2], 'base64url').length, 64);
  assert.deepEqual(v.header, { alg: 'ES256', kid: 'ABC123DEFG' });
  assert.deepEqual(v.claims, { iss: 'MH7J92HV9N', iat: 1_700_000_000 });
});

test('JWT cache: reused under 50 min, renewed after, forced renewal deduplicated', () => {
  let clock = 1_700_000_000_000;
  const s = createApnsSender(apnsConfigFromEnv(ENV), { now: () => clock });
  const a = s.providerToken();
  clock += 49 * 60_000;
  assert.equal(s.providerToken(), a, 'cached');
  clock += 60_000;
  const b = s.providerToken();
  assert.notEqual(b, a, 'renewed at 50 min (< 60)');
  assert.equal(verifyJwt(b).claims.iat, Math.floor(clock / 1000));
  const c = s.providerToken({ force: true, stale: b });
  assert.notEqual(c, b);
  assert.equal(s.providerToken({ force: true, stale: b }), c, 'a second failure on the old token does not sign again');
  assert.equal(s.stats.jwtSigned, 3);
});

test('registration: 64+ hex token, sandbox|production, bundle must match', () => {
  const b = { bundleId: 'sa.sary.albarq' };
  assert.deepEqual(parseApnsRegistration({ token: TOKEN.toUpperCase(), environment: 'Production' }, b), { token: TOKEN, environment: 'production', bundle_id: 'sa.sary.albarq' });
  assert.equal(parseApnsRegistration({ token: 'f'.repeat(160), environment: 'sandbox' }, b).environment, 'sandbox', 'longer tokens are fine');
  assert.equal(parseApnsRegistration({ token: 'a'.repeat(63), environment: 'sandbox' }, b).error, 'invalid_token');
  assert.equal(parseApnsRegistration({ token: 'g'.repeat(64), environment: 'sandbox' }, b).error, 'invalid_token');
  assert.equal(parseApnsRegistration({ token: 'a'.repeat(201), environment: 'sandbox' }, b).error, 'invalid_token');
  assert.equal(parseApnsRegistration({ token: 123, environment: 'sandbox' }, b).error, 'invalid_token');
  assert.equal(parseApnsRegistration(null, b).error, 'invalid_token');
  assert.equal(parseApnsRegistration({ token: TOKEN }, b).error, 'invalid_environment');
  assert.equal(parseApnsRegistration({ token: TOKEN, environment: 'development' }, b).error, 'invalid_environment');
  assert.equal(parseApnsRegistration({ token: TOKEN, environment: 'sandbox', bundle_id: 'com.other.app' }, b).error, 'invalid_bundle_id');
  assert.equal(parseApnsRegistration({ token: TOKEN, environment: 'sandbox', bundle_id: 'sa.sary.albarq' }, b).token, TOKEN);
});

test('payloads: Arabic texts from the web push, SOS time-sensitive, the rest passive, collapse by tag', () => {
  const at = Date.parse('2026-11-04T10:00:00Z');
  const opts = { now: at, bundleId: 'sa.sary.albarq' };
  const sosP = pushPayloadFor({ type: 'sos', user_id: SENDER, text: 'علقنا في الرمل' }, { senderName: 'أبو فهد', outingName: 'طلعة النفود' });
  const sos = apnsRequestFor(sosP, OUTING, opts);
  const sb = JSON.parse(sos.body);
  assert.deepEqual(sb.aps.alert, { title: '🆘 أبو فهد يطلب المساعدة · طلعة النفود', body: 'علقنا في الرمل' });
  assert.equal(sb.aps['interruption-level'], 'time-sensitive');
  assert.notEqual(sb.aps['interruption-level'], 'critical');
  assert.equal(sb.aps.sound, 'default');
  assert.equal(sb.aps['thread-id'], `sary-outing-${OUTING}`);
  assert.deepEqual([sb.type, sb.outing_id, sb.url, sb.v], ['sos', OUTING, `/outings/${OUTING}`, 1]);
  assert.equal(sos.headers['apns-priority'], '10');
  assert.equal(sos.headers['apns-push-type'], 'alert');
  assert.equal(sos.headers['apns-topic'], 'sa.sary.albarq');
  assert.equal(sos.headers['apns-collapse-id'], `sary-sos-${SENDER}`);
  assert.equal(sos.headers['apns-expiration'], String(at / 1000 + 3600));

  const clear = apnsRequestFor(pushPayloadFor({ type: 'sos', user_id: SENDER, sos: null }, { senderName: 'أبو فهد' }), OUTING, opts);
  const cb = JSON.parse(clear.body);
  assert.equal(cb.type, 'sos_clear');
  assert.equal(cb.aps.alert.title, 'أبو فهد بخير');
  assert.equal(cb.aps.alert.body, 'ألغى نداء الاستغاثة.');
  assert.equal(cb.aps['interruption-level'], 'passive');
  assert.equal(cb.aps.sound, undefined);
  assert.equal(clear.headers['apns-collapse-id'], sos.headers['apns-collapse-id'], '«أنا بخير» replaces the SOS');

  const note = apnsRequestFor(pushPayloadFor({ type: 'member_note', user_id: SENDER, note: { text: 'بوقف عند المحطة' } }, { senderName: 'سعد' }), OUTING, opts);
  const nb = JSON.parse(note.body);
  assert.deepEqual(nb.aps.alert, { title: 'سعد', body: 'بوقف عند المحطة' });
  assert.equal(nb.aps['interruption-level'], 'passive');
  assert.equal(nb.aps.sound, undefined);
  assert.equal(note.headers['apns-priority'], '5');
  assert.equal(note.headers['apns-collapse-id'], `sary-note-${SENDER}`);

  const clipP = pushPayloadFor({ type: 'voice_clip', clip: { id: 'c'.repeat(32), user_id: SENDER, duration_ms: 4200, expires_at: new Date(Date.now() + 600_000).toISOString() } }, {});
  const clip = JSON.parse(apnsRequestFor(clipP, OUTING, opts).body);
  assert.equal(clip.type, 'voice_clip');
  assert.match(clip.aps.alert.body, /رسالة صوتية \(4 ث\)/);
  assert.equal(clip.aps['interruption-level'], 'passive');

  const long = apnsRequestFor({ type: 'x', tag: 'ط'.repeat(60) }, OUTING, opts);
  assert.ok(Buffer.byteLength(long.headers['apns-collapse-id']) <= 64, 'collapse id within 64 bytes');
});

test('sender: HTTP/2 to the right host per environment, 200 delivered, 410 / BadDeviceToken reported', async (t) => {
  const prod = await fakeApns(t, (r) => (r.token === 'b'.repeat(64) ? { status: 410, reason: 'Unregistered' } : { status: 200 }));
  const sandbox = await fakeApns(t, () => ({ status: 400, reason: 'BadDeviceToken' }));
  const s = createApnsSender(apnsConfigFromEnv(ENV), { origins: { production: prod.origin, sandbox: sandbox.origin } });
  t.after(() => s.close());
  const req = apnsRequestFor({ type: 'note', title: 'سعد', body: 'هلا', tag: 'sary-note-x' }, OUTING, { bundleId: 'sa.sary.albarq' });

  const ok = await s.send({ token: TOKEN, environment: 'production' }, req);
  assert.deepEqual(ok, { status: 200, reason: null, apnsId: 'id-1' });
  const got = prod.seen[0];
  assert.equal(got.headers[':method'], 'POST');
  assert.equal(got.headers[':path'], `/3/device/${TOKEN}`);
  assert.equal(got.headers['apns-topic'], 'sa.sary.albarq');
  assert.equal(got.headers['apns-push-type'], 'alert');
  assert.equal(got.headers['apns-collapse-id'], 'sary-note-x');
  assert.equal(verifyJwt(got.jwt).ok, true);
  assert.equal(got.body.aps.alert.body, 'هلا');

  assert.deepEqual(await s.send({ token: 'b'.repeat(64), environment: 'production' }, req), { status: 410, reason: 'Unregistered', apnsId: 'id-2' });
  const bad = await s.send({ token: TOKEN, environment: 'sandbox' }, req);
  assert.equal(bad.reason, 'BadDeviceToken');
  assert.equal(sandbox.seen.length, 1, 'sandbox tokens go to the sandbox host');
  assert.equal(prod.seen.length, 2);
  assert.equal(prod.seen[1].jwt, prod.seen[0].jwt, 'the provider token is cached across requests');
  assert.equal(APNS_ORIGINS.production, 'https://api.push.apple.com');
  assert.equal(APNS_ORIGINS.sandbox, 'https://api.sandbox.push.apple.com');
});

test('sender: 403 ExpiredProviderToken → a fresh JWT and one retry', async (t) => {
  let clock = 1_700_000_000_000;
  const rejected = new Set();
  const apns = await fakeApns(t, (r, n) => {
    if (n === 1) {
      rejected.add(r.jwt);
      return { status: 403, reason: 'ExpiredProviderToken' };
    }
    return rejected.has(r.jwt) ? { status: 403, reason: 'ExpiredProviderToken' } : { status: 200 };
  });
  const s = createApnsSender(apnsConfigFromEnv(ENV), { origins: { production: apns.origin, sandbox: apns.origin }, now: () => (clock += 1000) });
  t.after(() => s.close());
  const r = await s.send({ token: TOKEN, environment: 'production' }, apnsRequestFor({ type: 'sos', urgency: 'high' }, OUTING));
  assert.equal(r.status, 200);
  assert.equal(apns.seen.length, 2, 'exactly one retry');
  assert.notEqual(apns.seen[1].jwt, apns.seen[0].jwt);
  assert.equal(verifyJwt(apns.seen[1].jwt).ok, true);
  assert.equal(s.stats.jwtSigned, 2);

  /* A 403 for another reason is not retried. */
  const other = await fakeApns(t, () => ({ status: 403, reason: 'MissingTopic' }));
  const s2 = createApnsSender(apnsConfigFromEnv(ENV), { origins: { production: other.origin, sandbox: other.origin } });
  t.after(() => s2.close());
  assert.equal((await s2.send({ token: TOKEN, environment: 'production' }, apnsRequestFor({}, OUTING))).reason, 'MissingTopic');
  assert.equal(other.seen.length, 1);
});

test('sender: an unreachable host rejects instead of hanging', async () => {
  const s = createApnsSender(apnsConfigFromEnv(ENV), { origins: { production: 'http://127.0.0.1:1', sandbox: 'http://127.0.0.1:1' }, log: () => {} });
  await assert.rejects(s.send({ token: TOKEN, environment: 'production' }, apnsRequestFor({}, OUTING)));
  s.close();
});

test('notifier: same recipients as web push, gone tokens deleted, failures counted, never logged', async () => {
  const rows = [
    { id: 'r1', user_id: 'u-ok', token: TOKEN, environment: 'production' },
    { id: 'r2', user_id: 'u-gone', token: 'b'.repeat(64), environment: 'production' },
    { id: 'r3', user_id: 'u-bad', token: 'c'.repeat(64), environment: 'sandbox' },
    { id: 'r4', user_id: 'u-err', token: 'd'.repeat(64), environment: 'production' },
    { id: 'r5', user_id: 'u-watch', token: 'e'.repeat(64), environment: 'production' },
  ];
  const pool = fakePool(rows);
  const sent = [];
  const logs = [];
  const sender = {
    async send(device, req) {
      sent.push({ device, req });
      if (device.token === 'b'.repeat(64)) return { status: 410, reason: 'Unregistered' };
      if (device.token === 'c'.repeat(64)) return { status: 400, reason: 'BadDeviceToken' };
      if (device.token === 'd'.repeat(64)) return { status: 500, reason: 'InternalServerError' };
      return { status: 200 };
    },
  };
  const n = createApnsNotifier({ pool, config: apnsConfigFromEnv(ENV), sender, viewers: () => new Set(['u-watch']), log: (...a) => logs.push(a.join(' ')) });
  assert.equal(n.enabled, true);
  const r = await n.notifyMembers(OUTING, SENDER, { type: 'note', title: 'سعد', body: 'هلا', tag: 't' });
  assert.deepEqual(r, { sent: 1, removed: 2, failed: 1, skipped: 1 });
  const select = pool.calls.find((c) => /^SELECT t\.id/.test(c.text));
  assert.match(select.text, /m\.status = 'active' AND \(\$4::boolean OR o\.status <> 'ended'\)/);
  assert.match(select.text, /t\.user_id <> \$2::uuid/, 'never the sender');
  assert.deepEqual(select.params, [OUTING, SENDER, 'sa.sary.albarq', false, null, []]);
  const del = pool.calls.find((c) => /^DELETE FROM sary\.apns_tokens WHERE id = ANY/.test(c.text));
  assert.deepEqual(del.params[0].sort(), ['r2', 'r3']);
  const upd = pool.calls.find((c) => /^UPDATE sary\.apns_tokens SET last_used_at/.test(c.text));
  assert.deepEqual(upd.params[0], ['r1']);
  assert.ok(!logs.some((l) => /[0-9a-f]{64}/.test(l)), 'device tokens never reach the log');

  /* SOS (`always`) also reaches someone looking at the outing. */
  sent.length = 0;
  const s = await n.notifyMembers(OUTING, SENDER, { type: 'sos', urgency: 'high', always: true, title: 't', body: 'b' });
  assert.equal(s.skipped, 0);
  assert.ok(sent.some((x) => x.device.token === 'e'.repeat(64)));
  assert.equal(JSON.parse(sent[0].req.body).aps['interruption-level'], 'time-sensitive');
});

test('notifier: register upserts, caps per person, unregister only my own valid token', async () => {
  const pool = fakePool([]);
  const n = createApnsNotifier({ pool, config: apnsConfigFromEnv(ENV), sender: { send: async () => ({ status: 200 }) }, maxPerUser: 3 });
  assert.deepEqual(await n.register({ id: 'u1' }, { token: 'zz', environment: 'production' }), { ok: false, error: 'invalid_token' });
  assert.deepEqual(await n.register({ id: 'u1' }, { token: TOKEN, environment: 'prod' }), { ok: false, error: 'invalid_environment' });
  assert.equal(pool.calls.length, 0, 'nothing written for invalid input');
  assert.deepEqual(await n.register({ id: 'u1' }, { token: TOKEN.toUpperCase(), environment: 'sandbox' }), { ok: true });
  assert.match(pool.calls[0].text, /ON CONFLICT \(token\) DO UPDATE/);
  assert.deepEqual(pool.calls[0].params, ['u1', TOKEN, 'sandbox', 'sa.sary.albarq']);
  assert.deepEqual(pool.calls[1].params, ['u1', 3]);
  assert.deepEqual(await n.unregister({ id: 'u1' }, 'nope'), { removed: 0 });
  await n.unregister({ id: 'u1' }, TOKEN);
  assert.deepEqual(pool.calls.at(-1).params, ['u1', TOKEN]);
});

test('disabled when unconfigured: logged once, nothing queried or sent, no errors', async () => {
  _resetLoggedOffForTests();
  const lines = [];
  const pool = fakePool([]);
  let sent = 0;
  const sender = { send: async () => { sent += 1; return { status: 200 }; } };
  const a = createApnsNotifier({ pool, config: apnsConfigFromEnv({ APNS_TEAM_ID: 'MH7J92HV9N' }), sender, info: (l) => lines.push(l) });
  const b = createApnsNotifier({ pool, config: apnsConfigFromEnv({}), sender, info: (l) => lines.push(l) });
  assert.equal(a.enabled, false);
  assert.equal(b.enabled, false);
  assert.equal(lines.length, 1, 'logged once');
  assert.match(lines[0], /APNS_KEY_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID not set/);
  assert.deepEqual(a.publicConfig(), { enabled: false, bundle_id: null });
  assert.deepEqual(await a.register({ id: 'u' }, { token: TOKEN, environment: 'production' }), { ok: false, error: 'apns_disabled' });
  assert.deepEqual(await a.notifyMembers(OUTING, null, { type: 'sos' }), { sent: 0, removed: 0, failed: 0, skipped: 0 });
  assert.equal(pool.calls.length, 0);
  assert.equal(sent, 0);
  a.close();
});

test('combined fan-out: web push and APNs both get the same call, sums add up', async () => {
  const calls = [];
  const fake = (name, enabled) => ({ enabled, notifyMembers: async (...a) => (calls.push([name, ...a]), { sent: 1, removed: 0, failed: 0, skipped: 2 }) });
  const both = combineNotifiers(fake('web', true), fake('apns', true));
  assert.equal(both.enabled, true);
  assert.deepEqual(await both.notifyMembers('o', 'u', { type: 'note' }), { sent: 2, removed: 0, failed: 0, skipped: 4 });
  assert.deepEqual(calls.map((c) => c.slice(0, 3)), [['web', 'o', 'u'], ['apns', 'o', 'u']]);
  calls.length = 0;
  const one = combineNotifiers(fake('web', false), fake('apns', true));
  assert.equal(one.enabled, true, 'APNs alone is enough to push');
  await one.notifyMembers('o', 'u', {});
  assert.deepEqual(calls.map((c) => c[0]), ['apns']);
  assert.equal(combineNotifiers(fake('web', false), fake('apns', false)).enabled, false);
});

async function router(t, apns) {
  const user = { id: '00000000-0000-4000-8000-000000000001' };
  const service = { authenticate: async (tok) => (tok === 'good-token' ? user : null) };
  const app = express();
  app.use('/api/outings', createOutingsRouter({ service, hub: null, push: createPushNotifier({ pool: fakePool([]), config: pushConfigFromEnv({}) }), apns }));
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise((r) => server.close(r)));
  const base = `http://127.0.0.1:${server.address().port}/api/outings`;
  return async (method, path, token, body) => {
    const res = await fetch(`${base}${path}`, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, body: await res.json() };
  };
}

test('routes: disabled → GET says off, POST is 503, DELETE is harmless', async (t) => {
  const api = await router(t, createApnsNotifier({ pool: fakePool([]), config: apnsConfigFromEnv({}), info: () => {} }));
  assert.deepEqual((await api('GET', '/push/apns')).body, { ok: true, enabled: false, bundle_id: null });
  const r = await api('POST', '/push/apns', 'good-token', { token: TOKEN, environment: 'production' });
  assert.deepEqual([r.status, r.body.error], [503, 'apns_disabled']);
  assert.deepEqual((await api('DELETE', '/push/apns', 'good-token', { token: TOKEN })).body, { ok: true, removed: 0 });
});

test('routes: auth exactly like /push/subscribe, then validation', async (t) => {
  const pool = fakePool([]);
  const api = await router(t, createApnsNotifier({ pool, config: apnsConfigFromEnv(ENV), sender: { send: async () => ({ status: 200 }) } }));
  assert.deepEqual((await api('GET', '/push/apns')).body, { ok: true, enabled: true, bundle_id: 'sa.sary.albarq' });
  for (const [method, tok] of [['POST', null], ['POST', 'bad-token'], ['DELETE', null], ['DELETE', 'bad-token']]) {
    const r = await api(method, '/push/apns', tok, { token: TOKEN, environment: 'production' });
    assert.deepEqual([r.status, r.body.error], [401, 'unauthorized'], `${method} ${tok}`);
  }
  assert.equal(pool.calls.length, 0, 'nothing written without auth');
  assert.deepEqual((await api('POST', '/push/apns', 'good-token', { token: 'xyz', environment: 'production' })).body, { ok: false, error: 'invalid_token' });
  assert.equal((await api('POST', '/push/apns', 'good-token', { token: TOKEN, environment: 'dev' })).status, 400);
  assert.equal((await api('POST', '/push/apns', 'good-token', { token: TOKEN, environment: 'sandbox', bundle_id: 'com.x.y' })).body.error, 'invalid_bundle_id');
  const ok = await api('POST', '/push/apns', 'good-token', { token: TOKEN, environment: 'production', bundle_id: 'sa.sary.albarq' });
  assert.deepEqual([ok.status, ok.body], [201, { ok: true }]);
  assert.deepEqual((await api('DELETE', '/push/apns', 'good-token', { token: TOKEN })).body, { ok: true, removed: 0 });
});
