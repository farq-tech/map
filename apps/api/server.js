'use strict';

require('dotenv').config({ path: require('path').join(__dirname, '../../.env') });
require('dotenv').config({ path: require('path').join(__dirname, '../../.env.local') });

const express = require('express');
const cors = require('cors');
const createMapRouter = require('./routes/map');

const PORT = Number(process.env.PORT || 4001);
const FARQ_API_ORIGIN = (process.env.FARQ_API_ORIGIN || '').replace(/\/$/, '');

const app = express();
app.disable('x-powered-by');
app.use(cors());
app.use(express.json({ limit: '1mb' }));

app.get('/api/health', (_req, res) => {
  res.json({
    ok: true,
    service: 'farq-map-api',
    comparison_read: process.env.SUPABASE_COMPARISON_READ_ENABLED === '1',
    farq_api_origin: Boolean(FARQ_API_ORIGIN),
  });
});

app.use('/api/intelligence', createMapRouter());

app.get('/api/restaurant/:id/menu', async (req, res) => {
  if (!FARQ_API_ORIGIN) {
    return res.json({ items: [], note: 'FARQ_API_ORIGIN unset' });
  }
  try {
    const url = `${FARQ_API_ORIGIN}/api/restaurant/${encodeURIComponent(req.params.id)}/menu`;
    const upstream = await fetch(url, {
      headers: { accept: 'application/json' },
    });
    const body = await upstream.json().catch(() => ({ items: [] }));
    res.status(upstream.status).json(body);
  } catch (err) {
    res.status(502).json({ items: [], error: err.message });
  }
});

if (FARQ_API_ORIGIN) {
  app.use('/api', async (req, res, next) => {
    if (req.path.startsWith('/intelligence') || req.path.startsWith('/restaurant/')) {
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

app.listen(PORT, () => {
  console.log(`[farq-map-api] listening on :${PORT}`);
});
