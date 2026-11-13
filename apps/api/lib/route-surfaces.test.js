'use strict';

/**
 * Route surface split (lib/outings/route-surfaces.js + the opt-in `surfaces` flag of POST /routing/route).
 * Fixtures are shaped like Valhalla's native /route JSON (trip.legs[].maneuvers[] with `length` in km and the
 * `rough` / `highway` flags). They are hand-made, not captured from the Farq gateway: see the PR for what that means.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const express = require('express');
const {
  surfaceBody,
  breakdownFromTrip,
  attachSurfaces,
  classifyManeuver,
} = require('./outings/route-surfaces');
const { createRoutingRouter, parseRouteRequest, valhallaRouteBody } = require('./outings/routing');

const M = (length, extra = {}) => ({ length, type: 1, street_names: ['طريق الملك فهد'], ...extra });

/* 12 km asphalt, 2 km dirt (rough), 3 km unnamed way (maybe a track), 4 km named dirt, zero-length arrival. */
const TRIP = {
  status: 0,
  units: 'kilometers',
  legs: [{
    maneuvers: [
      M(7, { highway: true, rough: false }),
      M(5, { rough: false }),
      M(2, { rough: true, street_names: ['درب الطعس'] }),
      M(3, { rough: false, street_names: undefined }),
      M(4, { rough: true, street_names: undefined }),
      { length: 0, type: 4 },
    ],
  }],
};
const TOTAL_KM = 21;

const OSRM = {
  code: 'Ok',
  routes: [{ distance: TOTAL_KM * 1000, duration: 1800, geometry: 'abc', legs: [{ steps: [] }] }],
  waypoints: [],
};

test('classify: rough → unpaved; named or highway → paved; unnamed unflagged → unknown (never asphalt)', () => {
  assert.equal(classifyManeuver(M(1, { rough: true })), 'unpaved');
  assert.equal(classifyManeuver(M(1, { rough: false })), 'paved');
  assert.equal(classifyManeuver(M(1, { highway: true, street_names: [] })), 'paved');
  assert.equal(classifyManeuver({ length: 1, rough: false }), 'unknown');
  assert.equal(classifyManeuver({ length: 1, street_names: ['  '] }), 'unknown');
});

test('breakdown: ordered segments, merged neighbours, totals, known share, zero-length skipped', () => {
  const b = breakdownFromTrip(TRIP);
  assert.equal(b.source, 'valhalla-maneuvers');
  assert.equal(b.granularity, 'maneuver');
  assert.equal(b.flag_present, true);
  assert.equal(b.total_km, TOTAL_KM);
  assert.deepEqual(b.segments, [
    { kind: 'paved', from_km: 0, to_km: 12, km: 12 }, // 7 + 5 merged
    { kind: 'unpaved', from_km: 12, to_km: 14, km: 2 },
    { kind: 'unknown', from_km: 14, to_km: 17, km: 3 },
    { kind: 'unpaved', from_km: 17, to_km: 21, km: 4 },
  ]);
  assert.deepEqual(b.totals_km, { paved: 12, unpaved: 6, offroad: 0, unknown: 3 });
  assert.equal(b.known_share, round(18 / 21));
  /* Segments tile the route with no gap or overlap. */
  for (let i = 1; i < b.segments.length; i++) assert.equal(b.segments[i].from_km, b.segments[i - 1].to_km);
});

function round(v) { return Math.round(v * 1000) / 1000; }

test('breakdown: Valhalla never sent the rough flag → known_share 0 and flag_present false (not read as all paved)', () => {
  const trip = { legs: [{ maneuvers: [{ length: 10, street_names: ['A'] }, { length: 5, street_names: ['B'] }] }] };
  const b = breakdownFromTrip(trip);
  assert.equal(b.flag_present, false);
  assert.equal(b.known_share, 0);
  assert.equal(b.total_km, 15);
});

test('breakdown: unusable input → null', () => {
  assert.equal(breakdownFromTrip(null), null);
  assert.equal(breakdownFromTrip({}), null);
  assert.equal(breakdownFromTrip({ legs: [{ maneuvers: [] }] }), null);
  assert.equal(breakdownFromTrip({ legs: [{ maneuvers: [{ length: 'x' }] }] }), null);
  assert.equal(breakdownFromTrip({ legs: [{ maneuvers: [{ length: -1 }] }] }), null);
  assert.equal(breakdownFromTrip({ legs: [{ maneuvers: [{ length: 0 }] }] }), null);
});

test('attach: adds surface_breakdown only; every other field and route stays byte-identical', () => {
  const out = attachSurfaces(OSRM, { trip: TRIP });
  assert.ok(out.routes[0].surface_breakdown);
  const { surface_breakdown: _s, ...rest } = out.routes[0];
  assert.deepEqual(rest, OSRM.routes[0]);
  assert.deepEqual({ ...out, routes: OSRM.routes }, OSRM);
});

test('attach: alternates line up by index; a route with no matching trip is left alone', () => {
  const osrm = { ...OSRM, routes: [OSRM.routes[0], { ...OSRM.routes[0], distance: 10_000 }, { ...OSRM.routes[0] }] };
  const alt = { legs: [{ maneuvers: [M(10, { rough: true })] }] };
  const out = attachSurfaces(osrm, { trip: TRIP, alternates: [{ trip: alt }] });
  assert.equal(out.routes[0].surface_breakdown.total_km, TOTAL_KM);
  assert.equal(out.routes[1].surface_breakdown.totals_km.unpaved, 10);
  assert.equal('surface_breakdown' in out.routes[2], false);
});

test('attach: a second answer that is a different length (> 5%) is ignored', () => {
  const osrm = { ...OSRM, routes: [{ ...OSRM.routes[0], distance: 30_000 }] };
  assert.equal('surface_breakdown' in attachSurfaces(osrm, { trip: TRIP }).routes[0], false);
});

test('attach: garbage never throws', () => {
  assert.deepEqual(attachSurfaces(OSRM, null), OSRM);
  assert.deepEqual(attachSurfaces(OSRM, { trip: 'x' }), OSRM);
  assert.deepEqual(attachSurfaces({ routes: null }, { trip: TRIP }), { routes: null });
});

test('surfaceBody: same route, native JSON, maneuvers only, no voice / banner / polyline', () => {
  const req = parseRouteRequest({ locations: [{ lat: 24.7, lng: 46.6 }, { lat: 24.8, lng: 46.7 }], options: { avoid_unpaved: false, use_tracks: 0.8 }, alternates: 1 }).value;
  const body = valhallaRouteBody(req);
  const sb = surfaceBody(body);
  assert.equal(sb.format, 'json');
  assert.equal(sb.directions_type, 'maneuvers');
  for (const k of ['banner_instructions', 'voice_instructions', 'shape_format']) assert.equal(k in sb, false);
  for (const k of ['locations', 'costing', 'costing_options', 'language', 'units', 'alternates']) assert.deepEqual(sb[k], body[k]);
  /* The original body is not mutated. */
  assert.equal(body.format, 'osrm');
});

test('validate: surfaces must be a boolean and is off by default (old clients unchanged)', () => {
  const base = { locations: [{ lat: 24.7, lng: 46.6 }, { lat: 24.8, lng: 46.7 }] };
  assert.equal(parseRouteRequest(base).value.surfaces, undefined);
  assert.equal(parseRouteRequest({ ...base, surfaces: true }).value.surfaces, true);
  assert.equal(parseRouteRequest({ ...base, surfaces: false }).value.surfaces, undefined);
  assert.equal(parseRouteRequest({ ...base, surfaces: 'yes' }).reason, 'invalid_surfaces');
});

/* ---------------- the route endpoint against a fake gateway ---------------- */

function startGateway(handler) {
  const seen = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      seen.push(body);
      handler(body, res);
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    origin: `http://127.0.0.1:${server.address().port}`,
    seen,
    close: () => new Promise((r) => server.close(r)),
  })));
}

async function post(app, body) {
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/route`, {
      method: 'POST',
      headers: { authorization: 'Bearer tok', 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    return { status: res.status, json: await res.json() };
  } finally {
    await new Promise((r) => server.close(r));
  }
}

function appFor(gw, extra = {}) {
  const app = express();
  app.use(express.json());
  app.use(createRoutingRouter({
    authenticate: async () => ({ id: 'u' }),
    config: { enabled: true, origin: gw.origin, token: 't' },
    ...extra,
  }));
  return app;
}

const REQ = { locations: [{ lat: 24.7, lng: 46.6 }, { lat: 24.8, lng: 46.7 }] };
const reply = (body, res) => {
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify(body.format === 'json' ? { trip: TRIP } : OSRM));
};

test('endpoint: without `surfaces` exactly one request goes out and the answer has no breakdown', async () => {
  const gw = await startGateway(reply);
  try {
    const r = await post(appFor(gw), REQ);
    assert.equal(r.status, 200);
    assert.equal(gw.seen.length, 1);
    assert.equal(gw.seen[0].format, 'osrm');
    assert.equal('surface_breakdown' in r.json.routes[0], false);
  } finally { await gw.close(); }
});

test('endpoint: with `surfaces` a second JSON request runs and the breakdown is added', async () => {
  const gw = await startGateway(reply);
  try {
    const r = await post(appFor(gw), { ...REQ, surfaces: true });
    assert.equal(r.status, 200);
    assert.equal(gw.seen.length, 2);
    assert.deepEqual(gw.seen.map((b) => b.format).sort(), ['json', 'osrm']);
    assert.equal(r.json.routes[0].surface_breakdown.totals_km.unpaved, 6);
    assert.equal(r.json.routes[0].distance, TOTAL_KM * 1000);
    assert.equal(r.json.provider, 'farq-valhalla');
  } finally { await gw.close(); }
});

test('endpoint: the surface request failing (500, junk, timeout) never fails or changes the route', async () => {
  for (const mode of ['500', 'junk', 'slow']) {
    const gw = await startGateway((body, res) => {
      if (body.format === 'osrm') return reply(body, res);
      if (mode === '500') { res.statusCode = 500; return res.end('{}'); }
      if (mode === 'junk') return res.end('not json');
      /* slow: never answer within the surface timeout */
      setTimeout(() => res.end(JSON.stringify({ trip: TRIP })), 400);
    });
    try {
      const t0 = Date.now();
      const r = await post(appFor(gw, { surfaceTimeoutMs: 80 }), { ...REQ, surfaces: true });
      assert.equal(r.status, 200, mode);
      assert.equal('surface_breakdown' in r.json.routes[0], false, mode);
      assert.deepEqual({ ...r.json, provider: undefined }, { ...OSRM, provider: undefined }, mode);
      if (mode === 'slow') assert.ok(Date.now() - t0 < 350, 'bounded by the surface timeout, not the slow answer');
    } finally { await gw.close(); }
  }
});

test('endpoint: the route request failing still fails the route (surfaces never mask an error)', async () => {
  const gw = await startGateway((body, res) => {
    if (body.format === 'osrm') { res.statusCode = 429; return res.end('{}'); }
    reply(body, res);
  });
  try {
    const r = await post(appFor(gw), { ...REQ, surfaces: true });
    assert.equal(r.status, 429);
    assert.equal(r.json.error, 'rate_limited');
  } finally { await gw.close(); }
});

test('endpoint: ROUTING_SURFACES=0 switch ignores the flag (kill switch)', async () => {
  const gw = await startGateway(reply);
  try {
    const r = await post(appFor(gw, { surfaces: false }), { ...REQ, surfaces: true });
    assert.equal(r.status, 200);
    assert.equal(gw.seen.length, 1);
    assert.equal('surface_breakdown' in r.json.routes[0], false);
  } finally { await gw.close(); }
});
