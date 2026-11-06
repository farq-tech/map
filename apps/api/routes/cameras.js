'use strict';

/**
 * /api/cameras — «كاميرات الرصد» (ساهر).
 *
 *   GET  /api/cameras?bbox=west,south,east,north   public layer (no identity)
 *   POST /api/cameras/report   { lat, lon, kind, client_id }   a driver's «كاميرا هنا»
 *   POST /api/cameras/:id/confirm | /dismiss        raise / lower confidence
 *
 * Reads are public and cacheable; reports carry no identity in the response. A
 * Bearer token, if present, only ties the report to a user server-side for
 * dedupe (see lib/cameras.js) — it is never echoed back or exposed on the layer.
 */

const express = require('express');
const { asyncHandler } = require('../lib/async-handler');
const { createRateLimiter } = require('../lib/outings/rate-limit');

function clientKey(req) {
  const fwd = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
  return fwd || req.socket.remoteAddress || 'unknown';
}

/** Accepts "w,s,e,n" (GeoJSON/Mapbox order) or explicit west/south/east/north. */
function parseBBox(req) {
  if (req.query.bbox != null) {
    const parts = String(req.query.bbox).split(',').map((s) => Number(s.trim()));
    if (parts.length === 4) {
      const [west, south, east, north] = parts;
      return { west, south, east, north };
    }
    return null;
  }
  const { west, south, east, north } = req.query;
  if ([west, south, east, north].every((v) => v != null)) {
    return { west: Number(west), south: Number(south), east: Number(east), north: Number(north) };
  }
  return null;
}

function createCamerasRouter({ cameras, authenticate = null, limits = {} } = {}) {
  const router = express.Router();
  router.use(express.json({ limit: '16kb' }));

  if (!cameras) {
    router.use((_req, res) => res.status(503).json({ ok: false, error: 'cameras_unconfigured' }));
    return router;
  }

  const reportLimit = createRateLimiter({ limit: limits.reportsPer5Min ?? 30, windowMs: 5 * 60_000 });
  const voteLimit = createRateLimiter({ limit: limits.votesPer5Min ?? 60, windowMs: 5 * 60_000 });

  /* Resolve a Bearer token to a user when we can; anonymous is fine for reports. */
  const maybeUser = asyncHandler(async (req, _res, next) => {
    const m = /^Bearer\s+(\S+)$/i.exec(String(req.headers.authorization || ''));
    req.user = m && authenticate ? await authenticate(m[1]).catch(() => null) : null;
    next();
  });

  router.get('/', asyncHandler(async (req, res) => {
    const box = parseBBox(req);
    if (!box) return res.status(400).json({ ok: false, error: 'bbox_required', message_ar: 'حدّد المستطيل bbox=west,south,east,north.' });
    const out = await cameras.inBBox({ ...box, limit: req.query.limit });
    if (!out.ok) return res.status(400).json(out);
    /* The layer is the same for everyone and changes slowly; let the CDN hold it. */
    res.set('Cache-Control', 'public, max-age=120, stale-while-revalidate=600');
    res.json({ ok: true, cameras: out.cameras });
  }));

  router.post('/report', maybeUser, asyncHandler(async (req, res) => {
    if (!reportLimit(clientKey(req))) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const b = req.body || {};
    const out = await cameras.report({
      userId: req.user ? req.user.id : null,
      clientId: b.client_id,
      lat: b.lat,
      lon: b.lon,
      kind: b.kind,
    });
    if (!out.ok) return res.status(400).json({ ...out, message_ar: 'لا نسجّل بلاغًا بدون موقع صحيح.' });
    res.set('Cache-Control', 'no-store');
    res.status(201).json(out);
  }));

  router.post('/:id/confirm', asyncHandler(async (req, res) => {
    if (!voteLimit(clientKey(req))) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const out = await cameras.confirm(req.params.id);
    res.status(out.ok ? 200 : 404).json(out);
  }));

  router.post('/:id/dismiss', asyncHandler(async (req, res) => {
    if (!voteLimit(clientKey(req))) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const out = await cameras.dismiss(req.params.id);
    res.status(out.ok ? 200 : 404).json(out);
  }));

  return router;
}

module.exports = { createCamerasRouter, parseBBox };
