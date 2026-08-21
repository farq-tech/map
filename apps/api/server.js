'use strict';

const cityOpportunities = require('./lib/city-opportunities');
const resultIntegrity = require('./lib/result-integrity');
const selfCheck = require('./lib/self-check');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '.env') });
require('dotenv').config({ path: path.join(__dirname, '../../.env') });
require('dotenv').config({ path: path.join(__dirname, '../../.env.local') });

const express = require('express');
const cors = require('cors');
const compression = require('compression');
const createMapRouter = require('./routes/map');
const createCopilotRouter = require('./routes/copilot');
const createAnalyticsRouter = require('./routes/analytics');
const { warmCityCache } = require('./lib/city-opportunities');
const { getCatalog, catalogJson } = require('./lib/comparison-catalog');

const PORT = Number(process.env.PORT || 4001);
const FARQ_API_ORIGIN = (process.env.FARQ_API_ORIGIN || '').replace(/\/$/, '');

const corsOrigins = String(process.env.CORS_ORIGINS || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

const app = express();
app.disable('x-powered-by');
/* The city read model is ~2.7 MB of JSON and ~380 KB gzipped; never send it raw. */
app.use(compression({ threshold: 1024 }));
app.use(
  cors({
    origin(origin, callback) {
      if (!origin) return callback(null, true);
      if (origin.endsWith('.vercel.app')) return callback(null, true);
      if (
        /^http:\/\/(localhost|127\.0\.0\.1):(4173|5173|5174|5175)$/.test(origin)
      ) {
        return callback(null, true);
      }
      if (!corsOrigins.length || corsOrigins.includes(origin)) {
        return callback(null, true);
      }
      return callback(null, false);
    },
  }),
);
app.use(express.json({ limit: '1mb' }));

/**
 * Liveness. Is this process running and able to answer?
 *
 * This is the platform's probe (Railway is configured to poll it with an
 * ON_FAILURE restart policy), so it must answer 200 for as long as the process
 * can serve at all. It deliberately says nothing about whether the data is any
 * good: a container restart does not fix a stale read layer, and wiring data
 * quality into a liveness probe turns a data problem into a restart loop.
 */
const liveness = (_req, res) => {
  res.json({ ok: true, service: 'farq-map-api', signal: 'liveness' });
};

/* The platform's probe. Railway polls this on the Railway domain directly. */
app.get('/version', liveness);

/**
 * The same answer under /api, because that is the only prefix the web host
 * rewrites through to this service. Reached from the public domain, a bare
 * /version is served by the CDN as the single-page app's HTML with a 200 — so a
 * liveness check pointed there would report a healthy API while this process was
 * entirely down. One path that works from everywhere is worth the duplicate line.
 */
app.get('/api/version', liveness);

/**
 * Readiness. Is the data this process is serving worth believing?
 *
 * NOT a liveness probe — see /version for that. This one answers 503 when the
 * read layer produced nothing for a city we serve, or when a rebuild was refused
 * and we are knowingly serving older data. Both are states where the process is
 * perfectly healthy and the answers are not.
 *
 * Three signals, kept apart on purpose:
 *   /version           the process is up            (platform probe)
 *   /api/health        the data can be trusted      (this endpoint)
 *   synthetic check    a user can actually get a correct result
 *                      (apps/api/scripts/synthetic-check.mjs, from outside)
 */
app.get('/api/health', (_req, res) => {
  const data = resultIntegrity.snapshot();
  /* A refused rebuild means we are deliberately serving older data. That is the
   * correct behaviour and it is still a condition someone must see. */
  const refused = [...cityOpportunities.refusedSnapshots.entries()].map(([city, v]) => ({
    city, at: v.at, violations: v.violations.map((x) => x.rule),
  }));
  const dataOk = !data.last_failure && refused.length === 0;
  res.status(dataOk ? 200 : 503).json({
    ok: dataOk,
    signal: 'readiness',
    liveness_endpoint: '/version',
    process: {
      ok: true,
      service: 'farq-map-api',
      uptime_s: Math.round(process.uptime()),
    },
    self_check: selfCheck.snapshot(),
    data: {
      ok: dataOk,
      counts: data.counts,
      last_failure: data.last_failure,
      refused_rebuilds: refused,
      stale_after_days: data.stale_after_days,
    },
    config: {
      comparison_read: process.env.SUPABASE_COMPARISON_READ_ENABLED === '1',
      menu_catalog: process.env.MENU_CATALOG_ENABLED === '1',
      farq_api_origin: Boolean(FARQ_API_ORIGIN),
    },
  });
});

app.use('/api/intelligence', createMapRouter());
app.use('/api/copilot', createCopilotRouter());
app.use('/api/analytics', createAnalyticsRouter());

async function proxyFarqCatalog(id) {
  if (!FARQ_API_ORIGIN) return null;
  const url = `${FARQ_API_ORIGIN}/api/comparison/restaurants/${encodeURIComponent(id)}/catalog`;
  const upstream = await fetch(url, { headers: { accept: 'application/json' } });
  const body = await upstream.json().catch(() => null);
  return { status: upstream.status, body };
}

app.get('/api/comparison/restaurants/:id/catalog', async (req, res) => {
  try {
    const local = await getCatalog(req.params.id);
    if (local.ok) {
      return res.status(200).json(catalogJson(local));
    }
    const proxied = await proxyFarqCatalog(req.params.id);
    if (proxied && proxied.body) {
      return res.status(proxied.status).json(proxied.body);
    }
    return res.status(local.status || 503).json({
      ok: false,
      error: local.error || 'catalog_unavailable',
    });
  } catch (err) {
    if (FARQ_API_ORIGIN) {
      try {
        const proxied = await proxyFarqCatalog(req.params.id);
        if (proxied && proxied.body) {
          return res.status(proxied.status).json(proxied.body);
        }
      } catch {
        /* fall through */
      }
    }
    res.status(502).json({ ok: false, error: err.message });
  }
});

app.get('/api/restaurant/:id/menu', async (req, res) => {
  try {
    let local;
    try {
      local = await getCatalog(req.params.id);
    } catch (err) {
      local = { ok: false, error: err.message };
    }
    if (local.ok) {
      return res.status(200).json({
        items: local.items,
        restaurant: local.restaurant,
        categories: local.categories,
        summary: local.summary,
      });
    }
    const proxied = await proxyFarqCatalog(req.params.id);
    if (proxied && proxied.body && proxied.body.ok) {
      const categories = Array.isArray(proxied.body.categories)
        ? proxied.body.categories
        : [];
      const items = categories.flatMap((c) =>
        Array.isArray(c.items) ? c.items : [],
      );
      return res.status(proxied.status).json({
        items,
        restaurant: proxied.body.restaurant,
        categories,
        summary: proxied.body.summary,
      });
    }
    return res.status(200).json({ items: [], note: local.error || 'catalog_unavailable' });
  } catch (err) {
    res.status(502).json({ items: [], error: err.message });
  }
});

if (FARQ_API_ORIGIN) {
  app.use('/api', async (req, res, next) => {
    if (
      req.path.startsWith('/intelligence') ||
      req.path.startsWith('/restaurant/') ||
      req.path.startsWith('/comparison/')
    ) {
      return next();
    }
    try {
      const url = `${FARQ_API_ORIGIN}/api${req.originalUrl.replace(/^\/api/, '')}`;
      const upstream = await fetch(url);
      const body = await upstream.json().catch(() => null);
      res.status(upstream.status).json(body);
    } catch (err) {
      res.status(502).json({ error: err.message });
    }
  });
}

app.use((err, _req, res, _next) => {
  console.error(err);
  res.status(500).json({ error: err.message || 'internal_error' });
});

/* The intended scheduler is GitHub Actions; this covers the gap while that is
 * unavailable. Off unless SELF_CHECK_ENABLED=1. See lib/self-check.js. */
selfCheck.start();

app.listen(PORT, () => {
  console.log(`[farq-map-api] listening on :${PORT}`);
  if (process.env.SUPABASE_COMPARISON_READ_ENABLED === '1' || process.env.SUPABASE_COMPARISON_READ_ENABLED === 'true') {
    warmCityCache(['riyadh']);
  }
});
