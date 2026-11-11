'use strict';

/**
 * Turn-by-turn routing proxy (lib/outings/routing.js): validation, identity,
 * rate limits, the exact Valhalla body, error mapping, disabled mode and
 * pass-through — against a fake gateway on 127.0.0.1. No database, no token.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');
const createOutingsRouter = require('../routes/outings');
const {
  createRoutingRouter,
  routingConfigFromEnv,
  parseRouteRequest,
  valhallaRouteBody,
  mapUpstreamError,
} = require('./outings/routing');

const RIYADH = { lat: 24.7136, lng: 46.6753 };
const DIRIYAH = { lat: 24.7343, lng: 46.5753 };
const FAKE_TOKEN = 'fake-gateway-token-for-tests';
const USERS = { 'tok-a': { id: 'user-a' }, 'tok-b': { id: 'user-b' } };
const authenticate = async (t) => USERS[t] || null;

const OSRM_OK = {
  code: 'Ok',
  routes: [{
    distance: 12345.6,
    duration: 900.1,
    geometry: 'abc_polyline6',
    weight: 950,
    weight_name: 'auto',
    legs: [{ distance: 12345.6, duration: 900.1, summary: 'طريق الملك خالد', steps: [{ name: 'طريق الملك خالد', bannerInstructions: [{ primary: { text: 'طريق الملك خالد' } }], voiceInstructions: [{ announcement: 'انعطف يمينًا' }] }] }],
  }],
  waypoints: [{ name: '', location: [46.6753, 24.7136] }, { name: '', location: [46.5753, 24.7343] }],
};

/* ---------------- fake gateway ---------------- */

function startGateway() {
  const seen = [];
  let reply = (_req, res) => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(OSRM_OK)); };
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      seen.push({ method: req.method, url: req.url, headers: req.headers, body: raw ? JSON.parse(raw) : null });
      reply(req, res);
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    origin: `http://127.0.0.1:${server.address().port}`,
    seen,
    setReply(fn) { reply = fn; },
    close: () => new Promise((r) => server.close(r)),
  })));
}

const json = (status, obj) => (_req, res) => { res.statusCode = status; res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(obj)); };

function startApp(router, mount = '/api/outings/routing') {
  const app = express();
  app.use(express.json({ limit: '48kb' }));
  app.use(mount, router);
  const server = http.createServer(app);
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    base: `http://127.0.0.1:${server.address().port}${mount}`,
    close: () => new Promise((r) => server.close(r)),
  })));
}

async function post(base, body, { token = 'tok-a', headers = {} } = {}) {
  const res = await fetch(`${base}/route`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json() };
}

const okBody = (extra = {}) => ({ locations: [RIYADH, DIRIYAH], ...extra });

/* ---------------- pure ---------------- */

test('config: both env vars required, https only (http only for localhost), names only in the log', () => {
  assert.deepEqual(routingConfigFromEnv({}).missing, ['VALHALLA_ORIGIN', 'VALHALLA_GATEWAY_TOKEN']);
  assert.equal(routingConfigFromEnv({}).enabled, false);
  assert.equal(routingConfigFromEnv({ VALHALLA_ORIGIN: 'https://gw.example.com' }).enabled, false);
  assert.deepEqual(routingConfigFromEnv({ VALHALLA_GATEWAY_TOKEN: 'x' }).missing, ['VALHALLA_ORIGIN']);
  const on = routingConfigFromEnv({ VALHALLA_ORIGIN: 'https://gw.example.com/', VALHALLA_GATEWAY_TOKEN: ' t ' });
  assert.equal(on.enabled, true);
  assert.equal(on.origin, 'https://gw.example.com');
  assert.equal(on.token, 't');
  assert.equal(routingConfigFromEnv({ VALHALLA_ORIGIN: 'http://gw.example.com', VALHALLA_GATEWAY_TOKEN: 't' }).reason, 'invalid_origin');
  assert.equal(routingConfigFromEnv({ VALHALLA_ORIGIN: 'not a url', VALHALLA_GATEWAY_TOKEN: 't' }).reason, 'invalid_origin');
  assert.equal(routingConfigFromEnv({ VALHALLA_ORIGIN: 'https://u:p@gw.example.com', VALHALLA_GATEWAY_TOKEN: 't' }).reason, 'invalid_origin');
  assert.equal(routingConfigFromEnv({ VALHALLA_ORIGIN: 'http://127.0.0.1:8002', VALHALLA_GATEWAY_TOKEN: 't' }).enabled, true);
});

test('validate: locations 2..10, finite, inside the GCC box', () => {
  assert.equal(parseRouteRequest(okBody()).ok, true);
  assert.equal(parseRouteRequest(null).reason, 'invalid_request');
  assert.equal(parseRouteRequest([]).reason, 'invalid_request');
  assert.equal(parseRouteRequest({}).reason, 'invalid_locations');
  assert.equal(parseRouteRequest({ locations: [RIYADH] }).reason, 'invalid_locations');
  assert.equal(parseRouteRequest({ locations: Array.from({ length: 11 }, () => RIYADH) }).reason, 'invalid_locations');
  assert.equal(parseRouteRequest({ locations: Array.from({ length: 10 }, () => RIYADH) }).ok, true);
  assert.equal(parseRouteRequest({ locations: [RIYADH, { lat: '24.7', lng: 46.6 }] }).reason, 'invalid_locations', 'string');
  assert.equal(parseRouteRequest({ locations: [RIYADH, { lat: NaN, lng: 46.6 }] }).reason, 'invalid_locations');
  assert.equal(parseRouteRequest({ locations: [RIYADH, { lat: Infinity, lng: 46.6 }] }).reason, 'invalid_locations');
  assert.equal(parseRouteRequest({ locations: [RIYADH, null] }).reason, 'invalid_locations');
  assert.equal(parseRouteRequest({ locations: [RIYADH, { lat: 24.7, lon: 46.6 }] }).reason, 'invalid_locations', 'lon is not lng');
  assert.equal(parseRouteRequest({ locations: [RIYADH, { lat: 95, lng: 46.6 }] }).reason, 'invalid_locations');
  const cairo = parseRouteRequest({ locations: [RIYADH, { lat: 30.04, lng: 31.24 }] });
  assert.deepEqual([cairo.status, cairo.reason], [422, 'out_of_area']);
  assert.equal(parseRouteRequest({ locations: [RIYADH, { lat: 11.9, lng: 45 }] }).reason, 'out_of_area');
  assert.equal(parseRouteRequest({ locations: [RIYADH, { lat: 33.1, lng: 45 }] }).reason, 'out_of_area');
  assert.equal(parseRouteRequest({ locations: [RIYADH, { lat: 20, lng: 60.1 }] }).reason, 'out_of_area');
  assert.equal(parseRouteRequest({ locations: [{ lat: 12, lng: 34 }, { lat: 33, lng: 60 }] }).ok, true, 'box edges are inside');
});

test('validate: costing, options, alternates, language, depart_at', () => {
  const now = Date.parse('2026-11-04T10:00:00Z');
  const p = (extra) => parseRouteRequest(okBody(extra), { now });
  assert.equal(p({}).value.costing, 'auto');
  assert.equal(p({}).value.language, 'ar-SA');
  assert.equal(p({}).value.alternates, 0);
  assert.equal(p({ costing: 'truck' }).value.costing, 'truck');
  assert.equal(p({ costing: 'bicycle' }).reason, 'invalid_costing');
  assert.equal(p({ options: { avoid_tolls: 'yes' } }).reason, 'invalid_options');
  assert.equal(p({ options: [] }).reason, 'invalid_options');
  assert.equal(p({ options: { use_tracks: 1.5 } }).reason, 'invalid_options');
  assert.equal(p({ options: { use_tracks: -0.1 } }).reason, 'invalid_options');
  assert.deepEqual(p({ options: { avoid_unpaved: true, use_tracks: 0.3, unknown: 1 } }).value.options, { avoid_unpaved: true, use_tracks: 0.3 });
  assert.equal(p({ alternates: 3 }).reason, 'invalid_alternates');
  assert.equal(p({ alternates: 1.5 }).reason, 'invalid_alternates');
  assert.equal(p({ alternates: 2 }).value.alternates, 2);
  assert.equal(p({ language: 'fr-FR' }).reason, 'invalid_language');
  assert.equal(p({ language: 'en-US' }).value.language, 'en-US');
  assert.equal(p({ depart_at: '2026-11-04T12:00:00Z' }).value.departAt, Date.parse('2026-11-04T12:00:00Z'));
  assert.equal(p({ depart_at: 'tomorrow' }).reason, 'invalid_depart_at');
  assert.equal(p({ depart_at: 1730000000 }).reason, 'invalid_depart_at');
  assert.equal(p({ depart_at: '2026-11-04T07:00:00Z' }).reason, 'invalid_depart_at', 'hours in the past');
  assert.equal(p({ depart_at: '2027-01-04T12:00:00Z' }).reason, 'invalid_depart_at', 'months ahead');
});

test('translate: the exact Valhalla /route body (snapshot)', () => {
  const now = Date.parse('2026-11-04T10:00:00Z');
  const body = valhallaRouteBody(parseRouteRequest(okBody({
    options: { avoid_unpaved: true, avoid_tolls: true, avoid_highways: true, use_tracks: 0.2 },
    alternates: 2,
  }), { now }).value);
  assert.deepEqual(body, {
    locations: [
      { lat: 24.7136, lon: 46.6753, type: 'break' },
      { lat: 24.7343, lon: 46.5753, type: 'break' },
    ],
    costing: 'auto',
    costing_options: { auto: { use_tolls: 0, use_highways: 0, use_tracks: 0.2, exclude_unpaved: true } },
    language: 'ar-SA',
    units: 'kilometers',
    directions_type: 'instructions',
    format: 'osrm',
    banner_instructions: true,
    voice_instructions: true,
    shape_format: 'polyline6',
    alternates: 2,
  });

  const plain = valhallaRouteBody(parseRouteRequest(okBody({ costing: 'truck', language: 'en-US', options: { avoid_tolls: false } })).value);
  assert.deepEqual(plain.costing_options, { truck: {} }, 'false avoid_* keeps Valhalla defaults');
  assert.equal(plain.language, 'en-US');
  assert.equal('alternates' in plain, false);
  assert.equal('date_time' in plain, false);

  const three = valhallaRouteBody(parseRouteRequest({ locations: [RIYADH, DIRIYAH, RIYADH], alternates: 2 }).value);
  assert.equal('alternates' in three, false, 'Valhalla has no alternates on multipoint routes');

  const timed = valhallaRouteBody(parseRouteRequest(okBody({ depart_at: '2026-11-04T12:30:00Z', alternates: 1 }), { now }).value);
  assert.deepEqual(timed.date_time, { type: 1, value: '2026-11-04T15:30' }, 'local GCC time (UTC+3), no offset');
  assert.equal('alternates' in timed, false, 'nor on time-dependent ones');
});

test('exclude_polygons: validated, passed to Valhalla only when present', () => {
  const ring = [[46.6, 25.2], [46.7, 25.2], [46.7, 25.3], [46.6, 25.3], [46.6, 25.2]];
  const p = (extra) => parseRouteRequest(okBody(extra));
  assert.equal(p({}).value.excludePolygons, undefined);
  assert.equal('exclude_polygons' in valhallaRouteBody(p({}).value), false);
  assert.deepEqual(valhallaRouteBody(p({ exclude_polygons: [ring] }).value).exclude_polygons, [ring]);
  assert.equal(p({ exclude_polygons: 'x' }).reason, 'invalid_exclude_polygons');
  assert.equal(p({ exclude_polygons: [ring, ring, ring, ring, ring] }).reason, 'invalid_exclude_polygons');
  assert.equal(p({ exclude_polygons: [[[46.6, 25.2]]] }).reason, 'invalid_exclude_polygons');
  assert.equal(p({ exclude_polygons: [[[46.6, 'a'], [1, 2], [3, 4], [5, 6]]] }).reason, 'invalid_exclude_polygons');
});

test('error mapping: Valhalla json codes, OSRM codes, gateway statuses', () => {
  assert.deepEqual(mapUpstreamError(400, { error_code: 442, error: 'No path could be found for input' }), { status: 422, code: 'no_route' });
  assert.deepEqual(mapUpstreamError(400, { error_code: 170 }), { status: 422, code: 'no_route' });
  assert.deepEqual(mapUpstreamError(400, { error_code: 171 }), { status: 422, code: 'out_of_area' });
  assert.deepEqual(mapUpstreamError(400, { error_code: 154 }), { status: 422, code: 'route_too_long' });
  assert.deepEqual(mapUpstreamError(400, { code: 'NoRoute', message: 'x' }), { status: 422, code: 'no_route' });
  assert.deepEqual(mapUpstreamError(400, { code: 'NoSegment' }), { status: 422, code: 'out_of_area' });
  assert.deepEqual(mapUpstreamError(401, { error: 'unauthorized' }), { status: 503, code: 'routing_unavailable' });
  assert.deepEqual(mapUpstreamError(429, null), { status: 429, code: 'rate_limited' });
  assert.deepEqual(mapUpstreamError(502, { error: 'routing service unavailable' }), { status: 503, code: 'routing_unavailable' });
  assert.deepEqual(mapUpstreamError(400, { error_code: 999 }), { status: 502, code: 'routing_failed' });
});

/* ---------------- HTTP, fake gateway ---------------- */

test('route: auth, pass-through, headers, disabled mode, errors, size cap, timeout, rate limits', async (t) => {
  const gw = await startGateway();
  const config = routingConfigFromEnv({ VALHALLA_ORIGIN: gw.origin, VALHALLA_GATEWAY_TOKEN: FAKE_TOKEN });
  const app = await startApp(createRoutingRouter({ authenticate, config, limits: { routesPerMinute: 1000, routesPerDay: 1000, routesPerMinutePerIp: 1000, routesPerDayPerIp: 1000 }, timeoutMs: 300, maxBytes: 64 * 1024 }));
  t.after(async () => { await app.close(); await gw.close(); });

  await t.test('status is public', async () => {
    const r = await fetch(`${app.base}/status`);
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), { ok: true, enabled: true, provider: 'farq-valhalla' });
  });

  await t.test('identity required', async () => {
    assert.deepEqual(await post(app.base, okBody(), { token: null }), { status: 401, body: { ok: false, error: 'unauthorized' } });
    assert.equal((await post(app.base, okBody(), { token: 'nope' })).status, 401);
    assert.equal(gw.seen.length, 0, 'nothing reaches the gateway');
  });

  await t.test('validation answers before the gateway', async () => {
    assert.deepEqual(await post(app.base, { locations: [RIYADH] }), { status: 400, body: { ok: false, error: 'invalid_locations' } });
    assert.deepEqual(await post(app.base, { locations: [RIYADH, { lat: 30.04, lng: 31.24 }] }), { status: 422, body: { ok: false, error: 'out_of_area' } });
    assert.equal(gw.seen.length, 0);
  });

  await t.test('pass-through + provider; only our headers go upstream', async () => {
    const r = await post(app.base, okBody({ alternates: 1 }), { headers: { cookie: 'session=secret', 'x-forwarded-for': '203.0.113.9', 'x-client': 'ios' } });
    assert.equal(r.status, 200);
    assert.deepEqual(r.body, { ...OSRM_OK, provider: 'farq-valhalla' });
    const call = gw.seen.at(-1);
    assert.equal(call.method, 'POST');
    assert.equal(call.url, '/route');
    assert.equal(call.headers.authorization, `Bearer ${FAKE_TOKEN}`, 'server-side token, not the identity token');
    assert.equal(call.headers['content-type'], 'application/json');
    for (const h of ['cookie', 'x-forwarded-for', 'x-client']) assert.equal(call.headers[h], undefined, `${h} not forwarded`);
    assert.equal(call.body.format, 'osrm');
    assert.equal(call.body.language, 'ar-SA');
    assert.equal(call.body.alternates, 1);
    assert.ok(Buffer.byteLength(JSON.stringify(call.body)) < 64 * 1024, 'fits the gateway 64 KB cap');
  });

  await t.test('errors map to clean codes', async () => {
    const cases = [
      [json(400, { code: 'NoRoute', message: 'Impossible route between points' }), 422, 'no_route'],
      [json(400, { error_code: 442, error: 'No path could be found for input', status_code: 400 }), 422, 'no_route'],
      [json(400, { error_code: 171, error: 'No suitable edges near location', status_code: 400 }), 422, 'out_of_area'],
      [json(400, { code: 'NoSegment', message: 'x' }), 422, 'out_of_area'],
      [json(401, { error: 'unauthorized' }), 503, 'routing_unavailable'],
      [json(502, { error: 'routing service unavailable' }), 503, 'routing_unavailable'],
      [json(429, { error: 'slow down' }), 429, 'rate_limited'],
      [json(200, { code: 'NoRoute', routes: [] }), 422, 'no_route'],
      [json(200, { hello: 'world' }), 502, 'routing_failed'],
      [(_q, res) => { res.setHeader('content-type', 'text/html'); res.end('<html>oops</html>'); }, 502, 'routing_failed'],
      [json(200, { code: 'Ok', routes: [], waypoints: [], pad: 'x'.repeat(70 * 1024) }), 502, 'routing_failed'],
    ];
    for (const [reply, status, error] of cases) {
      gw.setReply(reply);
      const r = await post(app.base, okBody());
      assert.deepEqual(r, { status, body: { ok: false, error } }, error);
      assert.equal(JSON.stringify(r.body).includes(FAKE_TOKEN), false);
    }
  });

  await t.test('timeout → routing_unavailable', async () => {
    gw.setReply(() => { /* never answers */ });
    const r = await post(app.base, okBody());
    assert.deepEqual(r, { status: 503, body: { ok: false, error: 'routing_unavailable' } });
    gw.setReply(json(200, OSRM_OK));
  });

  await t.test('gateway down → routing_unavailable', async () => {
    const down = routingConfigFromEnv({ VALHALLA_ORIGIN: 'http://127.0.0.1:1', VALHALLA_GATEWAY_TOKEN: FAKE_TOKEN });
    const a = await startApp(createRoutingRouter({ authenticate, config: down }));
    try {
      assert.deepEqual(await post(a.base, okBody()), { status: 503, body: { ok: false, error: 'routing_unavailable' } });
    } finally {
      await a.close();
    }
  });

  await t.test('rate limits: per identity per minute / day and per address', async () => {
    const before = gw.seen.length;
    const a = await startApp(createRoutingRouter({ authenticate, config, limits: { routesPerMinute: 2, routesPerDay: 3, routesPerMinutePerIp: 100, routesPerDayPerIp: 100 } }));
    try {
      assert.equal((await post(a.base, okBody())).status, 200);
      assert.equal((await post(a.base, okBody())).status, 200);
      assert.deepEqual(await post(a.base, okBody()), { status: 429, body: { ok: false, error: 'rate_limited' } });
      assert.equal((await post(a.base, okBody(), { token: 'tok-b' })).status, 200, 'another identity has its own budget');
      assert.equal(gw.seen.length - before, 3);
    } finally {
      await a.close();
    }
    const b = await startApp(createRoutingRouter({ authenticate, config, limits: { routesPerMinute: 100, routesPerDay: 100, routesPerMinutePerIp: 2, routesPerDayPerIp: 100 } }));
    try {
      assert.equal((await post(b.base, okBody(), { token: 'tok-a' })).status, 200);
      assert.equal((await post(b.base, okBody(), { token: 'tok-b' })).status, 200);
      assert.equal((await post(b.base, okBody(), { token: 'tok-a' })).status, 429, 'same address, new identity, still limited');
    } finally {
      await b.close();
    }
    const c = await startApp(createRoutingRouter({ authenticate, config, limits: { routesPerMinute: 100, routesPerDay: 2, routesPerMinutePerIp: 100, routesPerDayPerIp: 100 } }));
    try {
      assert.equal((await post(c.base, okBody())).status, 200);
      assert.equal((await post(c.base, okBody())).status, 200);
      assert.equal((await post(c.base, okBody())).status, 429, 'daily cap');
    } finally {
      await c.close();
    }
  });
});

test('disabled: env vars missing → status enabled:false, route 503 routing_unavailable, nothing sent', async () => {
  let calls = 0;
  const fetchImpl = async () => { calls += 1; throw new Error('must not be called'); };
  const app = await startApp(createRoutingRouter({ authenticate, config: routingConfigFromEnv({}), fetchImpl }));
  try {
    const s = await fetch(`${app.base}/status`);
    assert.deepEqual(await s.json(), { ok: true, enabled: false, provider: 'farq-valhalla' });
    assert.deepEqual(await post(app.base, okBody()), { status: 503, body: { ok: false, error: 'routing_unavailable' } });
    assert.equal((await post(app.base, okBody(), { token: null })).status, 401, 'identity still checked first');
    assert.equal(calls, 0);
  } finally {
    await app.close();
  }
});

test('mounted in the outings router: status works without a database, route needs one', async () => {
  const app = await startApp(createOutingsRouter({ service: null, routing: { config: routingConfigFromEnv({}) } }), '/api/outings');
  try {
    const s = await fetch(`${app.base}/routing/status`);
    assert.equal(s.status, 200);
    assert.equal((await s.json()).enabled, false);
    assert.equal(s.headers.get('cache-control'), 'no-store');
    const r = await post(`${app.base}/routing`, okBody());
    assert.deepEqual(r, { status: 503, body: { ok: false, error: 'outings_unconfigured' } });
    const other = await fetch(`${app.base}/`);
    assert.equal(other.status, 503, 'the rest of outings is unchanged');
  } finally {
    await app.close();
  }
});
