'use strict';

const express = require('express');
const comparisonMap = require('../lib/comparison-map');
const { asyncHandler } = require('../lib/async-handler');
const { buildPresentation } = require('../lib/map-opportunity');

const CATEGORIES = [
  { category_id: 'burgers', category_name: 'Burgers', category_name_ar: 'برجر' },
  { category_id: 'pizza', category_name: 'Pizza', category_name_ar: 'بيتزا' },
  { category_id: 'coffee', category_name: 'Coffee', category_name_ar: 'قهوة' },
  { category_id: 'shawarma', category_name: 'Shawarma', category_name_ar: 'شاورما' },
  { category_id: 'grocery', category_name: 'Grocery', category_name_ar: 'بقالة' },
];

function emptyCollection() {
  return {
    type: 'FeatureCollection',
    count: 0,
    features: [],
    note_en: 'Neighborhood mosaic is not painted on this map preview.',
    note_ar: 'أحياء الخريطة للوحة الجانب فقط — ليست فسيفساء.',
  };
}

function createMapRouter() {
  const router = express.Router();

  router.get(
    '/health',
    asyncHandler(async (_req, res) => {
      const comparison = await comparisonMap.mapHealth().catch((err) => ({
        ok: false,
        error: err.message,
      }));
      res.json({ ok: true, comparison });
    })
  );

  router.get('/meta', (_req, res) => {
    res.json({
      neighborhoods: [],
      categories: CATEGORIES,
      category_groups: [],
      category_count: CATEGORIES.length,
      quick_categories: CATEGORIES.slice(0, 4),
      cities: ['Riyadh'],
      providers: [],
    });
  });

  router.get(
    '/map/places',
    asyncHandler(async (req, res) => {
      const body = await comparisonMap.queryPlaces({
        bbox: req.query.bbox,
        zoom: req.query.zoom,
        q: req.query.q,
        category: req.query.category,
        layer: 'comparison',
        limit: req.query.limit,
      });

      // Keep the legacy FeatureCollection response for the current map while
      // adding the semantic Farq layer. This lets the UI migrate incrementally
      // without changing the existing pin renderer in one risky release.
      const presentation = buildPresentation(body);
      res.setHeader('Cache-Control', 'public, max-age=60');
      res.json({ ...body, presentation });
    })
  );

  router.get(
    '/map/opportunities',
    asyncHandler(async (req, res) => {
      const body = await comparisonMap.queryPlaces({
        bbox: req.query.bbox,
        zoom: req.query.zoom,
        q: req.query.q,
        category: req.query.category,
        layer: 'comparison',
        limit: req.query.limit,
      });

      res.setHeader('Cache-Control', 'public, max-age=60');
      res.json(buildPresentation(body));
    })
  );

  router.get(
    '/map/places/:placeId',
    asyncHandler(async (req, res) => {
      const place = await comparisonMap.getPlace(req.params.placeId);
      if (!place) {
        return res.status(404).json({
          error: 'not_found',
          place_id: req.params.placeId,
        });
      }
      res.json(place);
    })
  );

  router.get('/map/neighborhoods', (_req, res) => {
    res.json(emptyCollection());
  });

  router.get(
    '/neighborhoods/:neighborhoodId/categories/:categoryId',
    (_req, res) => {
      res.json({
        neighborhood_id: _req.params.neighborhoodId,
        category_id: _req.params.categoryId,
        question_ar: '',
        winner: {
          provider_id: null,
          confidence: 'INSUFFICIENT_DATA',
          evidence_bullets: [],
          caution: false,
          promote_in_consumer_ui: false,
        },
        dimension_chips: [],
      });
    }
  );

  return router;
}

module.exports = createMapRouter;
