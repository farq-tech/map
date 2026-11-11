'use strict';

/**
 * Weather layers for the app (server-side fetch + cache; the app never talks to a provider
 * and holds no key):
 *   GET /api/weather/clouds/tiles              latest cloud frames (+ tile templates)
 *   GET /api/weather/clouds/tile/:id/:z/:x/:y.png
 *   GET /api/weather/clouds/outlook?lat=&lng=  cloud motion + arrival estimate for one point
 *   GET /api/weather/rain/recent?days=1|3|7&bbox=w,s,e,n
 *   GET /api/weather/rain/tile/:days/:z/:x/:y.png
 *   GET /api/weather/green?bbox=w,s,e,n
 *   GET /api/weather/green/tile/:z/:x/:y.png
 *   GET /api/desert/categories/search?q=مطر|ربيع&near=lat,lng[&radius_km=250&limit=20]
 * Contract: docs/weather-sources.md (§ API).
 */

const express = require('express');
const crypto = require('crypto');
const clouds = require('../lib/weather/clouds');
const cloudOutlook = require('../lib/weather/cloud-outlook');
const rain = require('../lib/weather/rain');
const green = require('../lib/weather/green');
const desert = require('../lib/weather/desert-search');
const { KSA, parseBbox, parseNear } = require('../lib/weather/mercator');

function sendJson(req, res, body, maxAge) {
  const payload = JSON.stringify(body);
  const tag = `"${crypto.createHash('sha1').update(payload).digest('base64url').slice(0, 20)}"`;
  res.set('ETag', tag);
  res.set('Cache-Control', `public, max-age=${maxAge}, stale-while-revalidate=${maxAge * 4}`);
  if (req.headers['if-none-match'] === tag) return res.status(304).end();
  return res.type('json').send(payload);
}

function sendTile(res, r, maxAge) {
  if (r.status !== 200) return res.status(r.status).end();
  res.set('Cache-Control', `public, max-age=${maxAge}`);
  return res.type('png').send(r.body);
}

const int = (v) => (/^\d+$/.test(String(v)) ? Number(v) : NaN);
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res)).catch(next);

function createWeatherRouter() {
  const router = express.Router();

  router.get('/weather/clouds/tiles', wrap(async (req, res) => {
    const body = await clouds.framesPayload();
    if (!body.ok) return res.status(503).json({ ...body, message_ar: 'صور السحاب ما وصلت الحين، جرّب بعد شوي.' });
    return sendJson(req, res, body, 120);
  }));

  router.get('/weather/clouds/tile/:id/:z/:x/:y.png', wrap(async (req, res) => {
    const r = await clouds.tile(req.params.id, int(req.params.z), int(req.params.x), int(req.params.y));
    /* A frame never changes once sensed. */
    return sendTile(res, r, 86400);
  }));

  router.get('/weather/clouds/outlook', wrap(async (req, res) => {
    const pt = parseNear(`${req.query.lat},${req.query.lng}`);
    if (!pt) return res.status(400).json({ ok: false, error: 'bad_point', message_ar: 'الموقع خارج المملكة أو غير مقروء.' });
    const body = await cloudOutlook.outlook(pt.lat, pt.lng);
    if (!body.ok) return res.status(503).json({ ...body, message_ar: 'ما قدرنا نقدّر حركة السحاب الحين.' });
    return sendJson(req, res, body, 300);
  }));

  router.get('/weather/rain/recent', wrap(async (req, res) => {
    const days = rain.parseDays(req.query.days);
    if (!days) return res.status(400).json({ ok: false, error: 'bad_days', message_ar: 'المدة لازم تكون ١ أو ٣ أو ٧ أيام.' });
    const bbox = req.query.bbox ? parseBbox(req.query.bbox) : KSA;
    if (!bbox) return res.status(400).json({ ok: false, error: 'bad_bbox', message_ar: 'المنطقة خارج المملكة أو غير مقروءة.' });
    const body = await rain.recent({ days, bbox });
    if (!body.ok) return res.status(503).json(body);
    return sendJson(req, res, body, body.complete ? 600 : 60);
  }));

  router.get('/weather/rain/tile/:days/:z/:x/:y.png', wrap(async (req, res) => {
    const days = rain.parseDays(req.params.days);
    if (!days) return res.status(404).end();
    return sendTile(res, await rain.tile(days, int(req.params.z), int(req.params.x), int(req.params.y)), 600);
  }));

  router.get('/weather/green', wrap(async (req, res) => {
    const bbox = req.query.bbox ? parseBbox(req.query.bbox) : KSA;
    if (!bbox) return res.status(400).json({ ok: false, error: 'bad_bbox', message_ar: 'المنطقة خارج المملكة أو غير مقروءة.' });
    const body = await green.areas({ bbox });
    if (!body.ok) {
      res.set('Retry-After', '60');
      return res.status(503).json(body);
    }
    return sendJson(req, res, body, 3600);
  }));

  router.get('/weather/green/tile/:z/:x/:y.png', wrap(async (req, res) => {
    return sendTile(res, await green.tile(int(req.params.z), int(req.params.x), int(req.params.y)), 3600);
  }));

  router.get('/desert/categories/search', wrap(async (req, res) => {
    const q = String(req.query.q || '').slice(0, 80);
    let near = null;
    if (req.query.near) {
      near = parseNear(req.query.near);
      if (!near) return res.status(400).json({ ok: false, error: 'bad_near', message_ar: 'الموقع لازم يكون lat,lng داخل المملكة.' });
    }
    const body = await desert.search({ q, near, radiusKm: req.query.radius_km, limit: req.query.limit });
    return sendJson(req, res, body, 300);
  }));

  return router;
}

module.exports = createWeatherRouter;
/**
 * Background warm-up: cloud frames (every 5 min), greenness first (≈ 220 GIBS tiles), then the 7-day rain window (≈ 1,300
 * tiles); rain again every 20 min, greenness every 6 h. Off with WEATHER_WARM=0.
 */
module.exports.startWarm = () => {
  if (process.env.WEATHER_WARM === '0') return;
  let n = 0;
  const run = async () => {
    if (n++ % 18 === 0) await green.warm();
    await rain.warm();
  };
  setTimeout(run, 3_000).unref();
  setInterval(run, 20 * 60_000).unref();
  /* Clouds: a new picture every 10 min; warm the newest few so the loop plays whole, not square by square. */
  const runClouds = () => clouds.warm().catch(() => {});
  setTimeout(runClouds, 5_000).unref();
  setInterval(runClouds, 5 * 60_000).unref();
};
