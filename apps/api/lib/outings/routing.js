'use strict';

/**
 * Turn-by-turn routing for the Sary Albarq app over Farq's own Valhalla
 * (GCC graph), behind the Farq Valhalla gateway. The phone never holds a
 * secret: it calls us with its outing identity, we call the gateway with the
 * server-side token.
 *
 *   VALHALLA_ORIGIN         gateway origin, e.g. https://<gateway host> (no path)
 *   VALHALLA_GATEWAY_TOKEN  bearer token the gateway expects
 *
 * Either unset (or an origin that is not https) → routing is off: it says so
 * once in the log, GET /routing/status answers enabled:false and
 * POST /routing/route answers 503 routing_unavailable — like APNs without APNS_*.
 *
 * The gateway allows only route, optimized_route, isochrone and
 * sources_to_targets; we use /route. trace_route (map matching) is blocked
 * there and needs a one-line allowlist change in the gateway first.
 *
 * Valhalla is asked for OSRM-shaped output (format: osrm + banner/voice
 * instructions + polyline6), which is what the Mapbox Navigation SDK decodes
 * as a Directions response. Parameters checked against Valhalla 3.9
 * (docs: valhalla.github.io/valhalla/api/route/api-reference/; the ar-SA
 * narrative locale ships in locales/ar-SA.json from 3.9.0).
 */

const express = require('express');
const { asyncHandler } = require('../async-handler');
const { createRateLimiter } = require('./rate-limit');

const REQUEST_TIMEOUT_MS = 20_000;
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
const MAX_LOCATIONS = 10;
const MAX_EXCLUDE_RINGS = 4;
const MAX_EXCLUDE_POINTS = 400;
/* Generous GCC box: Yemen/Oman in the south, Kuwait/north Saudi in the north. */
const GCC_BOX = Object.freeze({ minLat: 12, maxLat: 33, minLng: 34, maxLng: 60 });
const COSTINGS = new Set(['auto', 'truck']);
const LANGUAGES = new Set(['ar-SA', 'en-US']);
const MAX_DEPART_AHEAD_MS = 30 * 24 * 60 * 60_000;
const MAX_DEPART_BEHIND_MS = 60 * 60_000;
/* Valhalla's date_time.value is local time at the origin. Every GCC state is
 * UTC+3 or UTC+4 with no DST; we use Riyadh (UTC+3). Off by one hour for a
 * UAE/Oman departure, which only nudges historical speeds. */
const DEPART_TZ_OFFSET_MIN = 180;

/* Valhalla numeric error codes (json format) and OSRM codes (format: osrm). */
const NO_ROUTE_CODES = new Set([170, 172, 442, 443, 444, 445]);
const OUT_OF_AREA_CODES = new Set([171]);
const TOO_LONG_CODES = new Set([150, 151, 152, 153, 154, 155, 156, 157, 158]);
const OSRM_NO_ROUTE = new Set(['NoRoute', 'NoMatch', 'NoTrips']);
const OSRM_OUT_OF_AREA = new Set(['NoSegment']);
const OSRM_TOO_LONG = new Set(['TooBig', 'DistanceExceeded']);

let loggedOff = false;

class RoutingError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

function routingConfigFromEnv(env = process.env) {
  const rawOrigin = String(env.VALHALLA_ORIGIN || '').trim();
  const token = String(env.VALHALLA_GATEWAY_TOKEN || '').trim();
  const missing = [!rawOrigin && 'VALHALLA_ORIGIN', !token && 'VALHALLA_GATEWAY_TOKEN'].filter(Boolean);
  const off = (reason) => ({ enabled: false, reason, missing, origin: null, token: null });
  if (missing.length) return off('missing');
  let url;
  try {
    url = new URL(rawOrigin);
  } catch {
    return off('invalid_origin');
  }
  const local = url.hostname === 'localhost' || url.hostname === '127.0.0.1' || url.hostname === '[::1]';
  if (!(url.protocol === 'https:' || (url.protocol === 'http:' && local))) return off('invalid_origin');
  if (url.username || url.password || url.search || url.hash) return off('invalid_origin');
  return { enabled: true, reason: null, missing: [], origin: url.origin + url.pathname.replace(/\/+$/, ''), token };
}

function logOffOnce(config) {
  if (loggedOff || config.enabled) return;
  loggedOff = true;
  const detail = config.reason === 'missing' ? `missing ${config.missing.join(', ')}` : config.reason;
  console.log(`[routing] off (${detail}) — POST /api/outings/routing/route answers 503 routing_unavailable`);
}

const finite = (n) => typeof n === 'number' && Number.isFinite(n);
const fail = (reason, status = 400) => ({ ok: false, status, reason });

/** Client body → { ok, value } with clean, bounded fields, or { ok:false, status, reason }. */
function parseRouteRequest(raw, { now = Date.now() } = {}) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return fail('invalid_request');
  const locs = raw.locations;
  if (!Array.isArray(locs) || locs.length < 2 || locs.length > MAX_LOCATIONS) return fail('invalid_locations');
  const locations = [];
  for (const p of locs) {
    if (!p || typeof p !== 'object' || !finite(p.lat) || !finite(p.lng)) return fail('invalid_locations');
    if (p.lat < -90 || p.lat > 90 || p.lng < -180 || p.lng > 180) return fail('invalid_locations');
    if (p.lat < GCC_BOX.minLat || p.lat > GCC_BOX.maxLat || p.lng < GCC_BOX.minLng || p.lng > GCC_BOX.maxLng) return fail('out_of_area', 422);
    locations.push({ lat: p.lat, lng: p.lng });
  }

  const costing = raw.costing == null ? 'auto' : raw.costing;
  if (!COSTINGS.has(costing)) return fail('invalid_costing');

  const o = raw.options == null ? {} : raw.options;
  if (typeof o !== 'object' || Array.isArray(o)) return fail('invalid_options');
  const options = {};
  for (const k of ['avoid_unpaved', 'avoid_tolls', 'avoid_highways']) {
    if (o[k] == null) continue;
    if (typeof o[k] !== 'boolean') return fail('invalid_options');
    options[k] = o[k];
  }
  if (o.use_tracks != null) {
    if (!finite(o.use_tracks) || o.use_tracks < 0 || o.use_tracks > 1) return fail('invalid_options');
    options.use_tracks = o.use_tracks;
  }

  let alternates = 0;
  if (raw.alternates != null) {
    if (!Number.isInteger(raw.alternates) || raw.alternates < 0 || raw.alternates > 2) return fail('invalid_alternates');
    alternates = raw.alternates;
  }

  const language = raw.language == null ? 'ar-SA' : raw.language;
  if (!LANGUAGES.has(language)) return fail('invalid_language');

  let departAt = null;
  if (raw.depart_at != null) {
    const t = typeof raw.depart_at === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(raw.depart_at) ? Date.parse(raw.depart_at) : NaN;
    if (!Number.isFinite(t) || t < now - MAX_DEPART_BEHIND_MS || t > now + MAX_DEPART_AHEAD_MS) return fail('invalid_depart_at');
    departAt = t;
  }

  /* Rings the route must not enter (the app's restricted airports / military zones, issue #187). */
  let excludePolygons = null;
  if (raw.exclude_polygons != null) {
    const rings = raw.exclude_polygons;
    if (!Array.isArray(rings) || rings.length > MAX_EXCLUDE_RINGS) return fail('invalid_exclude_polygons');
    excludePolygons = [];
    for (const ring of rings) {
      if (!Array.isArray(ring) || ring.length < 4 || ring.length > MAX_EXCLUDE_POINTS) return fail('invalid_exclude_polygons');
      const out = [];
      for (const pt of ring) {
        if (!Array.isArray(pt) || pt.length !== 2 || !finite(pt[0]) || !finite(pt[1])) return fail('invalid_exclude_polygons');
        if (pt[1] < GCC_BOX.minLat || pt[1] > GCC_BOX.maxLat || pt[0] < GCC_BOX.minLng || pt[0] > GCC_BOX.maxLng) return fail('invalid_exclude_polygons');
        out.push([pt[0], pt[1]]);
      }
      excludePolygons.push(out);
    }
  }

  const value = { locations, costing, options, alternates, language, departAt };
  if (excludePolygons && excludePolygons.length) value.excludePolygons = excludePolygons;
  return { ok: true, value };
}

/** "YYYY-MM-DDThh:mm" at the GCC departure offset. */
function localDateTime(ms) {
  return new Date(ms + DEPART_TZ_OFFSET_MIN * 60_000).toISOString().slice(0, 16);
}

/** Parsed request → the exact JSON body Valhalla's /route gets. */
function valhallaRouteBody(req) {
  const co = {};
  if (req.options.avoid_tolls) co.use_tolls = 0;
  if (req.options.avoid_highways) co.use_highways = 0;
  if (req.options.use_tracks != null) co.use_tracks = req.options.use_tracks;
  if (req.options.avoid_unpaved) co.exclude_unpaved = true;
  const body = {
    locations: req.locations.map((p) => ({ lat: p.lat, lon: p.lng, type: 'break' })),
    costing: req.costing,
    costing_options: { [req.costing]: co },
    language: req.language,
    units: 'kilometers',
    directions_type: 'instructions',
    format: 'osrm',
    banner_instructions: true,
    voice_instructions: true,
    shape_format: 'polyline6',
  };
  /* Valhalla supports alternates only for two-location, non-time-dependent routes. */
  if (req.alternates > 0 && req.locations.length === 2 && req.departAt == null) body.alternates = req.alternates;
  if (req.excludePolygons) body.exclude_polygons = req.excludePolygons;
  if (req.departAt != null) body.date_time = { type: 1, value: localDateTime(req.departAt) };
  return body;
}

/** A gateway / Valhalla failure → { status, code } for the app. */
function mapUpstreamError(status, json) {
  const ec = Number(json?.error_code);
  const osrm = typeof json?.code === 'string' ? json.code : '';
  if (status === 429) return { status: 429, code: 'rate_limited' };
  if (status === 401 || status === 403 || status === 404 || status === 415) return { status: 503, code: 'routing_unavailable' };
  if (NO_ROUTE_CODES.has(ec) || OSRM_NO_ROUTE.has(osrm)) return { status: 422, code: 'no_route' };
  if (OUT_OF_AREA_CODES.has(ec) || OSRM_OUT_OF_AREA.has(osrm)) return { status: 422, code: 'out_of_area' };
  if (TOO_LONG_CODES.has(ec) || OSRM_TOO_LONG.has(osrm)) return { status: 422, code: 'route_too_long' };
  if (status >= 500) return { status: 503, code: 'routing_unavailable' };
  return { status: 502, code: 'routing_failed' };
}

async function readCapped(res, max) {
  const len = Number(res.headers.get('content-length'));
  if (Number.isFinite(len) && len > max) {
    await res.body?.cancel().catch(() => {});
    return null;
  }
  if (!res.body) return Buffer.alloc(0);
  const chunks = [];
  let total = 0;
  for await (const chunk of res.body) {
    total += chunk.length;
    if (total > max) return null;
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

/** POST <origin>/route with only our own headers. Resolves the OSRM JSON or throws RoutingError. */
async function fetchRoute(config, body, { fetchImpl = globalThis.fetch, timeoutMs = REQUEST_TIMEOUT_MS, maxBytes = MAX_RESPONSE_BYTES } = {}) {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  timer.unref?.();
  let res;
  let buf;
  try {
    res = await fetchImpl(`${config.origin}/route`, {
      method: 'POST',
      headers: { authorization: `Bearer ${config.token}`, 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify(body),
      redirect: 'error',
      signal: ac.signal,
    });
    buf = await readCapped(res, maxBytes);
  } catch (e) {
    console.warn('[routing] upstream', ac.signal.aborted ? 'timeout' : e.cause?.code || e.code || e.name);
    throw new RoutingError(503, 'routing_unavailable');
  } finally {
    clearTimeout(timer);
  }
  if (buf == null) {
    console.warn('[routing] upstream response too large');
    throw new RoutingError(502, 'routing_failed');
  }
  let json = null;
  try {
    json = JSON.parse(buf.toString('utf8'));
  } catch {
    /* handled below */
  }
  if (!res.ok) {
    const m = mapUpstreamError(res.status, json);
    if (m.code === 'routing_unavailable' || m.code === 'routing_failed') console.warn('[routing] upstream status', res.status, json?.error_code ?? json?.code ?? '');
    throw new RoutingError(m.status, m.code);
  }
  if (!json || typeof json !== 'object' || Array.isArray(json)) throw new RoutingError(502, 'routing_failed');
  if (typeof json.code === 'string' && json.code !== 'Ok') {
    const m = mapUpstreamError(422, json);
    throw new RoutingError(m.status, m.code);
  }
  if (!Array.isArray(json.routes)) throw new RoutingError(502, 'routing_failed');
  return json;
}

function clientKey(req) {
  const fwd = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
  return fwd || req.socket.remoteAddress || 'unknown';
}

/**
 * Mounted at /api/outings/routing by routes/outings.js.
 * `authenticate(token) → user|null` is the outings identity check (null service → 503 outings_unconfigured).
 */
function createRoutingRouter({ authenticate, config = routingConfigFromEnv(), limits = {}, fetchImpl, timeoutMs, maxBytes } = {}) {
  logOffOnce(config);
  const router = express.Router();
  const userMinute = createRateLimiter({ limit: limits.routesPerMinute ?? 30, windowMs: 60_000 });
  const userDay = createRateLimiter({ limit: limits.routesPerDay ?? 300, windowMs: 24 * 60 * 60_000 });
  /* Per address a little looser: a carrier NAT puts many phones behind one IP. */
  const ipMinute = createRateLimiter({ limit: limits.routesPerMinutePerIp ?? 60, windowMs: 60_000 });
  const ipDay = createRateLimiter({ limit: limits.routesPerDayPerIp ?? 600, windowMs: 24 * 60 * 60_000 });

  router.get('/status', (_req, res) => {
    res.json({ ok: true, enabled: Boolean(config.enabled), provider: 'farq-valhalla' });
  });

  router.post('/route', asyncHandler(async (req, res) => {
    if (!authenticate) return res.status(503).json({ ok: false, error: 'outings_unconfigured' });
    const m = /^Bearer\s+(\S+)$/i.exec(String(req.headers.authorization || ''));
    const user = m ? await authenticate(m[1]) : null;
    if (!user) return res.status(401).json({ ok: false, error: 'unauthorized' });
    const ip = clientKey(req);
    /* Count every limiter (no short-circuit) so a flood is charged on both keys. */
    const allowed = [userMinute(user.id), userDay(user.id), ipMinute(ip), ipDay(ip)].every(Boolean);
    if (!allowed) return res.status(429).json({ ok: false, error: 'rate_limited' });
    if (!config.enabled) return res.status(503).json({ ok: false, error: 'routing_unavailable' });
    const parsed = parseRouteRequest(req.body);
    if (!parsed.ok) return res.status(parsed.status).json({ ok: false, error: parsed.reason });
    try {
      const json = await fetchRoute(config, valhallaRouteBody(parsed.value), { fetchImpl, timeoutMs, maxBytes });
      res.json({ ...json, provider: 'farq-valhalla' });
    } catch (e) {
      if (e instanceof RoutingError) return res.status(e.status).json({ ok: false, error: e.code });
      throw e;
    }
  }));

  return router;
}

module.exports = {
  createRoutingRouter,
  routingConfigFromEnv,
  parseRouteRequest,
  valhallaRouteBody,
  mapUpstreamError,
  fetchRoute,
  RoutingError,
  GCC_BOX,
  REQUEST_TIMEOUT_MS,
  MAX_RESPONSE_BYTES,
};
