'use strict';

const express = require('express');
const outdoor = require('../lib/outdoor');

function sendJson(req, res, body, maxAge = 120) {
  const payload = JSON.stringify(body);
  const tag = outdoor.etagFor(payload);
  res.set('ETag', tag);
  res.set('Cache-Control', `public, max-age=${maxAge}, stale-while-revalidate=600`);
  if (req.headers['if-none-match'] === tag) {
    return res.status(304).end();
  }
  res.type('json').send(payload);
}

module.exports = function createOutdoorRouter() {
  const router = express.Router();

  router.get('/features', (req, res) => {
    const data = outdoor.queryFeatures({
      bbox: req.query.bbox,
      types: req.query.types,
      zoom: req.query.zoom,
      limit: req.query.limit,
    });
    sendJson(req, res, data);
  });

  router.get('/around', (req, res) => {
    const lng = Number(req.query.lng);
    const lat = Number(req.query.lat);
    const radius = Number(req.query.radius);
    const data = outdoor.queryAround({ lng, lat, radius });
    if (data.error) {
      return res.status(400).json({
        ok: false,
        error: data.error,
        message_ar: 'لا نضع موقعًا إذا لم يصل GPS.',
      });
    }
    sendJson(req, res, data, 30);
  });

  router.get('/search', (req, res) => {
    const q = String(req.query.q || '').slice(0, 80);
    sendJson(req, res, outdoor.searchFeatures(q, req.query.limit));
  });

  router.get('/stats', (req, res) => {
    sendJson(req, res, outdoor.stats(), 300);
  });

  router.get('/:kind/:id', (req, res) => {
    const id = `${req.params.kind}:${req.params.id}`;
    const feature = outdoor.getFeature(id);
    if (!feature) {
      return res.status(404).json({
        ok: false,
        error: 'not_found',
        message_ar: 'غير مؤكد — لا يوجد هذا المعلم في البيانات العامة.',
      });
    }
    sendJson(req, res, feature, 300);
  });

  return router;
};
