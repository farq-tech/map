'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { geocodePlace } = require('./geocode-place');

const MAGHRZAT = {
  type: 'FeatureCollection',
  features: [
    {
      text: 'المغرزات',
      place_name: 'المغرزات, الرياض, السعودية',
      center: [46.76, 24.78],
      bbox: [46.74, 24.76, 46.78, 24.80],
    },
  ],
};

describe('geocodePlace — Mapbox, no invented coords', () => {
  it('returns the Mapbox bbox for المغرزات', async () => {
    const prev = process.env.MAPBOX_ACCESS_TOKEN;
    process.env.MAPBOX_ACCESS_TOKEN = 'test-token';
    try {
      const result = await geocodePlace('المغرزات', {
        fetch: async () => ({
          ok: true,
          json: async () => MAGHRZAT,
        }),
      });
      assert.equal(result.ok, true);
      assert.deepEqual(result.bbox, {
        west: 46.74,
        south: 24.76,
        east: 46.78,
        north: 24.8,
      });
      assert.equal(result.center.lng, 46.76);
      assert.equal(result.label.includes('المغرزات'), true);
    } finally {
      if (prev == null) delete process.env.MAPBOX_ACCESS_TOKEN;
      else process.env.MAPBOX_ACCESS_TOKEN = prev;
    }
  });

  it('does not invent a bbox when no geocoder has a feature', async () => {
    const prev = process.env.MAPBOX_ACCESS_TOKEN;
    process.env.MAPBOX_ACCESS_TOKEN = 'test-token';
    try {
      const result = await geocodePlace('حي وهمي', {
        fetch: async () => ({
          ok: true,
          json: async () => ({ features: [], suggestions: [] }),
        }),
      });
      assert.equal(result.ok, false);
      assert.equal(result.reason, 'place_not_found');
      assert.equal(result.bbox, null);
    } finally {
      if (prev == null) delete process.env.MAPBOX_ACCESS_TOKEN;
      else process.env.MAPBOX_ACCESS_TOKEN = prev;
    }
  });

  it('uses Nominatim neighborhood bbox when Mapbox places is empty', async () => {
    const prev = process.env.MAPBOX_ACCESS_TOKEN;
    process.env.MAPBOX_ACCESS_TOKEN = 'test-token';
    try {
      const result = await geocodePlace('المغرزات', {
        fetch: async (url) => {
          const href = String(url);
          if (href.includes('nominatim')) {
            return {
              ok: true,
              json: async () => [
                {
                  display_name: 'المغرزات, الرياض, السعودية',
                  lat: '24.7639948',
                  lon: '46.7257785',
                  boundingbox: ['24.7518635', '24.7761756', '46.7126102', '46.7388336'],
                },
              ],
            };
          }
          return { ok: true, json: async () => ({ features: [], suggestions: [] }) };
        },
      });
      assert.equal(result.ok, true);
      assert.equal(result.bbox.west, 46.7126102);
      assert.equal(result.bbox.south, 24.7518635);
      assert.equal(result.center.lat, 24.7639948);
    } finally {
      if (prev == null) delete process.env.MAPBOX_ACCESS_TOKEN;
      else process.env.MAPBOX_ACCESS_TOKEN = prev;
    }
  });
});
