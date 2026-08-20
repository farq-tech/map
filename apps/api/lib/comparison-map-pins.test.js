'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const {
  clusterPlaces,
  gridCluster,
  observedGapRiyals,
  pinFieldsMode,
  toSlimPinFeature,
  toFeature,
  PIN_FIELDS,
} = require('./comparison-map');

function place(i, opts = {}) {
  return {
    type: 'place',
    place_id: String(opts.place_id || i),
    restaurant_id: String(opts.place_id || i),
    name: opts.name || `مطعم ${i}`,
    kind: 'comparison',
    lat: opts.lat ?? 24.7 + i * 0.001,
    lng: opts.lng ?? 46.6 + i * 0.001,
    has_difference: opts.has_difference !== false,
    image_url: 'https://example.test/photo.jpg',
    menu: { href: `/merchant/restaurant/${i}` },
    difference: {
      difference_amount: opts.gap ?? 12 + i,
      cheapest_provider_id: opts.provider || 'jahez',
      expensive_provider_id: 'ninja',
      cheapest_price: 20,
      expensive_price: 32,
      product_name: 'وجبة',
    },
  };
}

describe('map list — points only, Mapbox owns clusters', () => {
  it('never emits server grid clusters even at city zoom', () => {
    const places = Array.from({ length: 24 }, (_, i) => place(i));
    const out = clusterPlaces(places, 10, 400);
    assert.equal(out.length, 24);
    assert.ok(out.every((p) => p.type !== 'cluster' && p.place_id));
  });

  it('gridCluster still exists but query path does not use it', () => {
    const clustered = gridCluster(
      [
        place(1, { lat: 24.71, lng: 46.67 }),
        place(2, { lat: 24.711, lng: 46.671 }),
      ],
      0.1,
    );
    assert.equal(clustered[0].type, 'cluster');
    const listed = clusterPlaces(
      [
        place(1, { lat: 24.71, lng: 46.67 }),
        place(2, { lat: 24.711, lng: 46.671 }),
      ],
      10,
      400,
    );
    assert.ok(listed.every((p) => p.type === 'place'));
  });

  it('spatial-samples over the cap and keeps top observed gaps', () => {
    const places = [
      place(79, { gap: 90 }),
      ...Array.from({ length: 79 }, (_, i) => place(i, { gap: 3 })),
    ];
    const out = clusterPlaces(places, 16, 40);
    assert.ok(out.length <= 40);
    assert.ok(out.some((p) => p.place_id === '79'));
    assert.ok(out.every((p) => p.type !== 'cluster'));
  });
});

describe('fields=pin slim mapper', () => {
  it('defaults to pin and keeps observed gap for ranking', () => {
    assert.equal(pinFieldsMode(undefined), 'pin');
    assert.equal(pinFieldsMode('PIN'), 'pin');
    assert.equal(pinFieldsMode('full'), 'full');
    assert.equal(observedGapRiyals({ difference_amount: 18.4 }), 18);
    assert.equal(observedGapRiyals({ difference_amount: 0.4 }), null);
  });

  it('omits image, menu, and nested difference from pin features', () => {
    const feature = toSlimPinFeature(place(8, { name: 'كودو', gap: 18.4 }));
    assert.deepEqual(Object.keys(feature.properties).sort(), [...PIN_FIELDS].sort());
    assert.equal(feature.properties.place_id, '8');
    assert.equal(feature.properties.name, 'كودو');
    assert.equal(feature.properties.gap, 18);
    assert.equal(feature.properties.cheapest_provider_id, 'jahez');
    assert.equal(feature.properties.expensive_provider_id, 'ninja');
    assert.equal(feature.properties.product_name, 'وجبة');
    assert.equal(feature.properties.cheapest_price, 20);
    assert.equal(feature.properties.expensive_price, 32);
    assert.equal(feature.properties.image_url, undefined);
    assert.equal(feature.properties.difference, undefined);
    assert.equal(feature.properties.menu, undefined);
    assert.equal(feature.geometry.coordinates[0], 46.6 + 8 * 0.001);
    assert.equal(feature.geometry.coordinates[1], 24.7 + 8 * 0.001);
  });

  it('toFeature(pin) matches slim; full keeps photo for the sheet path', () => {
    const row = place(3, { gap: 7 });
    const slim = toFeature(row, 'pin');
    const full = toFeature(row, 'full');
    assert.equal(slim.properties.gap, 7);
    assert.equal(slim.properties.image_url, undefined);
    assert.equal(full.properties.image_url, 'https://example.test/photo.jpg');
    assert.equal(full.properties.difference.difference_amount, 7);
  });
});
