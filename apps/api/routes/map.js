'use strict';

const express = require('express');
const comparisonMap = require('../lib/comparison-map');
const { asyncHandler } = require('../lib/async-handler');
const cityOpportunities = require('../lib/city-opportunities');

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
        layer: 'comparison',
        limit: req.query.limit,
        fields: req.query.fields,
      });
      res.setHeader('Cache-Control', 'public, max-age=60');
      res.json(body);
    })
  );

  /**
   * The whole city at once — opportunities only by default, `include=all` for
   * every restaurant with coordinates. Cached server-side and ETagged so a
   * returning client pays nothing when the read layer has not changed.
   */
  router.get(
    '/map/city/:city/opportunities',
    asyncHandler(async (req, res) => {
      const result = await cityOpportunities.getCityOpportunities({
        city: req.params.city,
        include: req.query.include,
      });
      if (!result) {
        return res.status(404).json({ error: 'unknown_city', city: req.params.city });
      }
      res.setHeader('ETag', result.etag);
      res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=3600');
      if (req.headers['if-none-match'] === result.etag) return res.status(304).end();
      res.json(result.body);
    })
  );

  router.get(
    '/map/city/:city/areas',
    asyncHandler(async (req, res) => {
      const result = await cityOpportunities.getCityAreas({ city: req.params.city });
      if (!result) {
        return res.status(404).json({ error: 'unknown_city', city: req.params.city });
      }
      res.setHeader('ETag', result.etag);
      res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=3600');
      if (req.headers['if-none-match'] === result.etag) return res.status(304).end();
      res.json(result.body);
    })
  );

  /**
   * The city's أحياء with the same aggregates the H3 cells carry. Boundaries are
   * the committed MOMRAH polygons (apps/api/data/districts); a city without a
   * file is a 404, never an invented outline.
   */
  router.get(
    '/map/city/:city/districts',
    asyncHandler(async (req, res) => {
      const result = await cityOpportunities.getCityDistricts({ city: req.params.city });
      if (!result) {
        return res.status(404).json({ error: 'no_districts_for_city', city: req.params.city });
      }
      res.setHeader('ETag', result.etag);
      res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=3600');
      if (req.headers['if-none-match'] === result.etag) return res.status(304).end();
      res.json(result.body);
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

  /**
   * The evidence behind the pin: every item this restaurant sells on more than
   * one app, with the price on each app. Cached for five minutes — the read
   * layer refreshes far slower than that.
   */
  router.get(
    '/map/places/:placeId/items',
    asyncHandler(async (req, res) => {
      const body = await comparisonMap.getPlaceItems(req.params.placeId);
      if (!body) {
        return res.status(404).json({ error: 'not_found', place_id: req.params.placeId });
      }
      res.setHeader('Cache-Control', 'public, max-age=300');
      res.json(body);
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
