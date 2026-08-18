/**
 * Comparison map read layer — real lat/lng from comparison.discovery_cards
 * (product-ready restaurants). Never invents coordinates, never remints
 * Golden FARQ-PLACE- ids, never fuzzy-joins Golden↔DB.
 *
 * Menu identity is canonical_restaurant_id — the same id home cards and
 * SearchService already open via /merchant/restaurant/:id.
 *
 * Observed cheapest/dearest come only from comparison.item_price_spread
 * (existing per-item aggregate). Missing spread = no winner, not a fake «ف».
 */
'use strict';

const { comparisonQuery } = require('./comparison-pool');

function readEnabled() {
  const v = process.env.SUPABASE_COMPARISON_READ_ENABLED;
  return v === '1' || v === 'true';
}

/** Riyadh launch coverage — default *view* only, never a fake GPS pin. */
const RIYADH_VIEW = {
  lat: 24.7136,
  lng: 46.6753,
  zoom: 11,
  bbox: { west: 46.45, south: 24.45, east: 47.05, north: 25.05 },
};

const KSA = { lngMin: 34, lngMax: 56, latMin: 16, latMax: 33 };

let coverageCache = { at: 0, value: null };
const COVERAGE_TTL_MS = 60_000;

function isFiniteNum(n) {
  return typeof n === 'number' && Number.isFinite(n);
}

function validCoord(lng, lat) {
  return (
    isFiniteNum(lng) &&
    isFiniteNum(lat) &&
    lng >= KSA.lngMin &&
    lng <= KSA.lngMax &&
    lat >= KSA.latMin &&
    lat <= KSA.latMax
  );
}

function norm(s) {
  return String(s || '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

function restaurantMenu(restaurantId) {
  const id = String(restaurantId || '').trim();
  if (!id || !/^\d+$/.test(id)) return null;
  return {
    to: '/merchant/$type/$id',
    type: 'restaurant',
    id,
    href: `/merchant/restaurant/${id}`,
  };
}

function parseBbox(raw) {
  if (!raw) return null;
  const parts = String(raw)
    .split(',')
    .map((x) => Number.parseFloat(x));
  if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) return null;
  let [west, south, east, north] = parts;
  if (west > east) [west, east] = [east, west];
  if (south > north) [south, north] = [north, south];
  if (east - west > 2.5 || north - south > 2.5) {
    return {
      west: Math.max(west, RIYADH_VIEW.bbox.west),
      south: Math.max(south, RIYADH_VIEW.bbox.south),
      east: Math.min(east, RIYADH_VIEW.bbox.east),
      north: Math.min(north, RIYADH_VIEW.bbox.north),
      clamped: true,
    };
  }
  return { west, south, east, north, clamped: false };
}

function cellSizeForZoom(zoom) {
  const z = Number(zoom);
  if (!Number.isFinite(z) || z >= 14) return 0;
  if (z >= 12) return 0.02;
  if (z >= 10) return 0.05;
  return 0.1;
}

function toPlacePin(p) {
  const menu = restaurantMenu(p.restaurant_id);
  const cheapest = p.cheapest_provider ? String(p.cheapest_provider) : null;
  const expensive = p.dearest_provider ? String(p.dearest_provider) : null;
  const amount =
    p.difference_amount != null && Number.isFinite(Number(p.difference_amount))
      ? Number(p.difference_amount)
      : null;
  const hasDifference = Boolean(cheapest);
  return {
    type: 'place',
    place_id: p.restaurant_id,
    restaurant_id: p.restaurant_id,
    name: p.name,
    kind: 'comparison',
    lat: p.lat,
    lng: p.lng,
    provider_count: p.provider_count,
    has_difference: hasDifference,
    menu,
    image_url: p.image_url || null,
    difference: hasDifference
      ? {
          difference_amount: amount,
          cheapest_provider_id: cheapest,
          expensive_provider_id: expensive,
          product_name: p.product_name || null,
        }
      : null,
  };
}

function gridCluster(places, cell) {
  const buckets = new Map();
  for (const p of places) {
    const key = `${Math.round(p.lat / cell)}:${Math.round(p.lng / cell)}`;
    let b = buckets.get(key);
    if (!b) {
      b = { count: 0, latSum: 0, lngSum: 0, sample: p, differenceCount: 0 };
      buckets.set(key, b);
    }
    b.count += 1;
    b.latSum += p.lat;
    b.lngSum += p.lng;
    if (p.has_difference) {
      b.differenceCount += 1;
      b.sample = p;
    } else if (
      !b.sample.has_difference &&
      (p.provider_count || 0) > (b.sample.provider_count || 0)
    ) {
      b.sample = p;
    }
  }
  const out = [];
  for (const b of buckets.values()) {
    if (b.count === 1) {
      out.push(b.sample);
    } else {
      out.push({
        type: 'cluster',
        count: b.count,
        difference_count: b.differenceCount,
        lat: b.latSum / b.count,
        lng: b.lngSum / b.count,
      });
    }
  }
  return out;
}

function spatialSample(places, n) {
  if (places.length <= n) return places;
  const sorted = places.slice().sort((a, b) => a.lat - b.lat || a.lng - b.lng);
  const out = [];
  const step = sorted.length / n;
  for (let i = 0; i < n; i += 1) {
    out.push(sorted[Math.min(sorted.length - 1, Math.floor(i * step))]);
  }
  return out;
}

function clusterPlaces(places, zoom, limit) {
  const cell = cellSizeForZoom(zoom);
  if (!cell) {
    if (places.length <= limit) return places;
    const diffs = places.filter((p) => p.has_difference);
    const rest = places.filter((p) => !p.has_difference);
    const keepDiffs = diffs.slice(0, limit);
    const sampled = spatialSample(rest, Math.max(0, limit - keepDiffs.length));
    return [...keepDiffs, ...sampled];
  }

  const out = gridCluster(places, cell);
  if (out.length <= limit) return out;
  out.sort((a, b) => {
    const ac = a.type === 'cluster' ? a.count : 1;
    const bc = b.type === 'cluster' ? b.count : 1;
    const ad = a.type === 'cluster' ? a.difference_count : a.has_difference ? 1 : 0;
    const bd = b.type === 'cluster' ? b.difference_count : b.has_difference ? 1 : 0;
    if (bd !== ad) return bd - ad;
    return bc - ac;
  });
  return out.slice(0, limit);
}

function emptyCoverage() {
  return {
    source: 'comparison.discovery_cards',
    restaurants_total: 0,
    restaurants_with_coords: 0,
    product_ready_total: 0,
    product_ready_with_coords: 0,
    discovery_cards_total: 0,
    discovery_cards_with_coords: 0,
    spread_restaurants: 0,
    unique_places: 0,
    matched: 0,
    shown: 0,
    db_join: null,
  };
}

async function loadCoverage() {
  const now = Date.now();
  if (coverageCache.value && now - coverageCache.at < COVERAGE_TTL_MS) {
    return coverageCache.value;
  }
  const rows = await comparisonQuery(
    `SELECT
       (SELECT count(*)::int FROM comparison.product_ready_restaurants) AS pr_total,
       (SELECT count(*)::int FROM comparison.product_ready_restaurants
         WHERE latitude IS NOT NULL AND longitude IS NOT NULL
           AND latitude BETWEEN $1 AND $2
           AND longitude BETWEEN $3 AND $4) AS pr_coords,
       (SELECT count(*)::int FROM comparison.product_ready_restaurants
         WHERE product_ready) AS pr_ready,
       (SELECT count(*)::int FROM comparison.product_ready_restaurants
         WHERE product_ready
           AND latitude IS NOT NULL AND longitude IS NOT NULL
           AND latitude BETWEEN $1 AND $2
           AND longitude BETWEEN $3 AND $4) AS pr_ready_coords,
       (SELECT count(*)::int FROM comparison.discovery_cards) AS dc_total,
       (SELECT count(*)::int FROM comparison.discovery_cards
         WHERE latitude IS NOT NULL AND longitude IS NOT NULL
           AND latitude BETWEEN $1 AND $2
           AND longitude BETWEEN $3 AND $4) AS dc_coords,
       (SELECT count(DISTINCT canonical_restaurant_id)::int
          FROM comparison.item_price_spread
         WHERE cheapest_provider IS NOT NULL) AS spread_restaurants`,
    [KSA.latMin, KSA.latMax, KSA.lngMin, KSA.lngMax],
  );
  const r = rows[0] || {};
  const value = {
    source: 'comparison.discovery_cards',
    restaurants_total: Number(r.pr_ready) || 0,
    restaurants_with_coords: Number(r.dc_coords) || 0,
    product_ready_total: Number(r.pr_total) || 0,
    product_ready_with_coords: Number(r.pr_coords) || 0,
    discovery_cards_total: Number(r.dc_total) || 0,
    discovery_cards_with_coords: Number(r.dc_coords) || 0,
    spread_restaurants: Number(r.spread_restaurants) || 0,
    unique_places: Number(r.dc_coords) || 0,
    matched: 0,
    shown: 0,
    db_join: null,
  };
  coverageCache = { at: now, value };
  return value;
}

function rowToPlace(row) {
  const lng = Number(row.longitude);
  const lat = Number(row.latitude);
  if (!validCoord(lng, lat)) return null;
  const restaurant_id = String(row.restaurant_id || '').trim();
  if (!restaurant_id || !/^\d+$/.test(restaurant_id)) return null;
  const name =
    row.canonical_name_ar ||
    row.canonical_name_en ||
    '';
  if (!String(name).trim()) return null;
  return {
    restaurant_id,
    name: String(name),
    name_ar: row.canonical_name_ar ? String(row.canonical_name_ar) : null,
    name_en: row.canonical_name_en ? String(row.canonical_name_en) : null,
    city: row.city ? String(row.city) : null,
    lat,
    lng,
    provider_count:
      row.provider_count != null && Number.isFinite(Number(row.provider_count))
        ? Number(row.provider_count)
        : null,
    cheapest_provider: row.cheapest_provider || null,
    dearest_provider: row.dearest_provider || null,
    difference_amount:
      row.difference_amount != null ? Number(row.difference_amount) : null,
    product_name: row.product_name || null,
    image_url: row.branch_image_url || null,
    has_difference: Boolean(row.cheapest_provider),
  };
}

const LIST_SQL = `
SELECT dc.canonical_restaurant_id::text AS restaurant_id,
       dc.canonical_name_ar,
       dc.canonical_name_en,
       dc.latitude,
       dc.longitude,
       dc.city,
       dc.provider_count,
       dc.branch_image_url,
       s.cheapest_provider,
       s.dearest_provider,
       s.cheapest_price,
       s.dearest_price,
       s.difference_amount,
       s.product_name
  FROM comparison.discovery_cards dc
  LEFT JOIN LATERAL (
    SELECT ips.cheapest_provider,
           ips.dearest_provider,
           ips.cheapest_price,
           ips.dearest_price,
           (ips.dearest_price - ips.cheapest_price) AS difference_amount,
           COALESCE(ips.name_ar, ips.name_en) AS product_name
      FROM comparison.item_price_spread ips
     WHERE ips.canonical_restaurant_id = dc.canonical_restaurant_id
       AND ips.cheapest_provider IS NOT NULL
       AND btrim(ips.cheapest_provider) <> ''
     ORDER BY (ips.dearest_price - ips.cheapest_price) DESC NULLS LAST
     LIMIT 1
  ) s ON true
 WHERE dc.latitude IS NOT NULL
   AND dc.longitude IS NOT NULL
   AND dc.latitude BETWEEN $1 AND $2
   AND dc.longitude BETWEEN $3 AND $4
   AND dc.latitude BETWEEN $5 AND $6
   AND dc.longitude BETWEEN $7 AND $8
`;

function matchesQuery(place, q) {
  if (!q) return true;
  const hay = norm([place.name, place.name_ar, place.name_en, place.city].join(' '));
  return hay.includes(q);
}

function emptyCollection(opts) {
  const bbox = parseBbox(opts.bbox) || RIYADH_VIEW.bbox;
  const zoom = Number(opts.zoom);
  return {
    type: 'FeatureCollection',
    count: 0,
    matched: 0,
    layer: 'comparison',
    bbox,
    zoom: Number.isFinite(zoom) ? zoom : null,
    q: opts.q ? norm(opts.q) : null,
    default_view: RIYADH_VIEW,
    coverage: emptyCoverage(),
    note_ar:
      'دبابيس من إحداثيات طبقة المقارنة الحقيقية — بدون إحداثيات مخترعة وبدون سكّ place_id.',
    note_en:
      'Pins from comparison-row coordinates only — no invented locations, no reminted place_ids.',
    features: [],
  };
}

function toFeature(f) {
  if (f.type === 'cluster') {
    return {
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [f.lng, f.lat] },
      properties: {
        feature_type: 'cluster',
        count: f.count,
        difference_count: f.difference_count,
      },
    };
  }
  return {
    type: 'Feature',
    id: f.place_id,
    geometry: { type: 'Point', coordinates: [f.lng, f.lat] },
    properties: {
      feature_type: 'place',
      place_id: f.place_id,
      restaurant_id: f.restaurant_id,
      name: f.name,
      kind: f.kind,
      provider_count: f.provider_count,
      has_difference: f.has_difference,
      difference: f.difference,
      menu: f.menu,
      image_url: f.image_url || null,
    },
  };
}

/**
 * @param {{ bbox?: string, zoom?: number|string, q?: string, limit?: number|string }} opts
 */
async function queryPlaces(opts = {}) {
  if (!readEnabled()) {
    const empty = emptyCollection(opts);
    empty.note_en = 'Comparison read layer is off — no invented pins.';
    return empty;
  }

  const bbox = parseBbox(opts.bbox) || RIYADH_VIEW.bbox;
  const zoom = Number(opts.zoom);
  const q = norm(opts.q);
  const limit = Math.min(Math.max(Number(opts.limit) || 400, 1), 800);

  const [rows, coverage] = await Promise.all([
    comparisonQuery(LIST_SQL, [
      bbox.south,
      bbox.north,
      bbox.west,
      bbox.east,
      KSA.latMin,
      KSA.latMax,
      KSA.lngMin,
      KSA.lngMax,
    ]),
    loadCoverage().catch(() => emptyCoverage()),
  ]);

  const pool = [];
  for (const row of rows) {
    const place = rowToPlace(row);
    if (!place) continue;
    if (!matchesQuery(place, q)) continue;
    pool.push(toPlacePin(place));
  }

  pool.sort((a, b) => {
    if (a.has_difference && !b.has_difference) return -1;
    if (b.has_difference && !a.has_difference) return 1;
    const da = a.difference?.difference_amount || 0;
    const db = b.difference?.difference_amount || 0;
    return db - da;
  });

  const features = clusterPlaces(pool, zoom, limit);
  return {
    type: 'FeatureCollection',
    count: features.length,
    matched: pool.length,
    layer: 'comparison',
    bbox,
    zoom: Number.isFinite(zoom) ? zoom : null,
    q: q || null,
    default_view: RIYADH_VIEW,
    coverage: {
      ...coverage,
      matched: pool.length,
      shown: features.length,
      unique_places: coverage.discovery_cards_with_coords,
      db_join: null,
    },
    note_ar:
      'دبابيس مطاعم المقارنة من إحداثيات الصف الحقيقية. اضغط الدبوس لفتح قائمة فرق.',
    note_en:
      'Comparison restaurant pins from real row coordinates. Tap a pin to open the Farq menu.',
    features: features.map(toFeature),
  };
}

const GET_SQL = `
SELECT dc.canonical_restaurant_id::text AS restaurant_id,
       dc.canonical_name_ar,
       dc.canonical_name_en,
       dc.latitude,
       dc.longitude,
       dc.city,
       dc.provider_count,
       dc.branch_image_url,
       s.cheapest_provider,
       s.dearest_provider,
       s.cheapest_price,
       s.dearest_price,
       s.difference_amount,
       s.product_name
  FROM comparison.discovery_cards dc
  LEFT JOIN LATERAL (
    SELECT ips.cheapest_provider,
           ips.dearest_provider,
           ips.cheapest_price,
           ips.dearest_price,
           (ips.dearest_price - ips.cheapest_price) AS difference_amount,
           COALESCE(ips.name_ar, ips.name_en) AS product_name
      FROM comparison.item_price_spread ips
     WHERE ips.canonical_restaurant_id = dc.canonical_restaurant_id
       AND ips.cheapest_provider IS NOT NULL
       AND btrim(ips.cheapest_provider) <> ''
     ORDER BY (ips.dearest_price - ips.cheapest_price) DESC NULLS LAST
     LIMIT 1
  ) s ON true
 WHERE dc.canonical_restaurant_id = $1::bigint
   AND dc.latitude IS NOT NULL
   AND dc.longitude IS NOT NULL
   AND dc.latitude BETWEEN $2 AND $3
   AND dc.longitude BETWEEN $4 AND $5
 LIMIT 1
`;

async function getPlace(placeId) {
  if (!readEnabled()) return null;
  const id = String(placeId || '').trim();
  if (!/^\d+$/.test(id)) return null;
  const rows = await comparisonQuery(GET_SQL, [
    id,
    KSA.latMin,
    KSA.latMax,
    KSA.lngMin,
    KSA.lngMax,
  ]);
  const place = rows[0] ? rowToPlace(rows[0]) : null;
  if (!place) return null;
  const pin = toPlacePin(place);
  return {
    place_id: pin.place_id,
    restaurant_id: pin.restaurant_id,
    name: pin.name,
    name_ar: place.name_ar,
    name_en: place.name_en,
    category: null,
    subcategory: null,
    city: place.city,
    provider_count: pin.provider_count,
    kind: 'comparison',
    lat: pin.lat,
    lng: pin.lng,
    difference: pin.difference,
    menu: pin.menu,
    compare: pin.menu,
    image_url: place.image_url,
    source: 'comparison.discovery_cards',
  };
}

async function mapHealth() {
  if (!readEnabled()) {
    return { ok: false, source: 'comparison.discovery_cards', coverage: emptyCoverage() };
  }
  try {
    const coverage = await loadCoverage();
    return {
      ok: coverage.discovery_cards_with_coords > 0,
      source: 'comparison.discovery_cards',
      place_count: coverage.discovery_cards_with_coords,
      restaurant_count: coverage.restaurants_with_coords,
      coverage,
    };
  } catch (err) {
    return {
      ok: false,
      source: 'comparison.discovery_cards',
      error: err.message,
      coverage: emptyCoverage(),
    };
  }
}

function __resetCoverageCacheForTests() {
  coverageCache = { at: 0, value: null };
}

module.exports = {
  RIYADH_VIEW,
  restaurantMenu,
  validCoord,
  parseBbox,
  queryPlaces,
  getPlace,
  mapHealth,
  __resetCoverageCacheForTests,
};
