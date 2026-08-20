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

/**
 * Map list is always honest points. Mapbox `cluster: true`
 * (clusterMaxZoom 13) owns aggregation below CLUSTER_BREAK_ZOOM.
 * Cap: MAP_PIN_CAP (request max MAP_PIN_CAP_MAX). Over cap → spatial sample
 * of the viewport, plus a small reserved slice for top observed gaps.
 */
const CLUSTER_BREAK_ZOOM = 14;
const PIN_FIELDS = Object.freeze([
  'feature_type',
  'place_id',
  'name',
  'gap',
  'cheapest_provider_id',
  'expensive_provider_id',
  'has_difference',
  'product_name',
  'cheapest_price',
  'expensive_price',
]);
const MAP_PIN_CAP = 400;
const MAP_PIN_CAP_MAX = 800;
/**
 * A restaurant's representative opportunity is its largest observed gap among
 * *consumer* items. Items priced above this (catering trays, 20-person meals)
 * are real but do not describe what a person orders for dinner — they are kept
 * out of the headline and ranking until a dedicated "جمعات" mode shows them.
 * Approved product threshold (2026-08-20).
 */
const CONSUMER_PRICE_CAP_SAR = 200;

const MAP_PIN_HERO_RESERVE = 24;

function cellSizeForZoom(zoom) {
  const z = Number(zoom);
  if (!Number.isFinite(z) || z >= CLUSTER_BREAK_ZOOM) return 0;
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
          cheapest_price:
            p.cheapest_price != null && Number.isFinite(Number(p.cheapest_price))
              ? Number(p.cheapest_price)
              : null,
          expensive_price:
            p.dearest_price != null && Number.isFinite(Number(p.dearest_price))
              ? Number(p.dearest_price)
              : null,
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

function observedGapRiyals(difference) {
  const n = Number(difference?.difference_amount);
  if (!Number.isFinite(n) || n <= 0 || Math.round(n) < 1) return null;
  return Math.round(n);
}

function pinFieldsMode(raw) {
  return String(raw || 'pin').toLowerCase() === 'full' ? 'full' : 'pin';
}

function observedPrice(raw) {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function toSlimPinFeature(f) {
  const gap = observedGapRiyals(f.difference);
  const diff = f.difference || {};
  return {
    type: 'Feature',
    id: f.place_id,
    geometry: { type: 'Point', coordinates: [f.lng, f.lat] },
    properties: {
      feature_type: 'place',
      place_id: f.place_id,
      name: f.name,
      gap,
      cheapest_provider_id: diff.cheapest_provider_id || null,
      expensive_provider_id: diff.expensive_provider_id || null,
      has_difference: Boolean(f.has_difference),
      product_name: diff.product_name || null,
      cheapest_price: observedPrice(diff.cheapest_price),
      expensive_price: observedPrice(diff.expensive_price),
    },
  };
}

/** Points only — Mapbox GPU clustering owns zoom < 14. Never emit grid orbs. */
function clusterPlaces(places, zoom, limit) {
  void zoom;
  if (places.length <= limit) return places;
  const heroBudget = Math.min(
    MAP_PIN_HERO_RESERVE,
    Math.max(0, Math.floor(limit * 0.15)),
  );
  const diffs = places.filter((p) => p.has_difference);
  const heroes = diffs.slice(0, heroBudget);
  const heroIds = new Set(heroes.map((p) => p.place_id));
  const rest = places.filter((p) => !heroIds.has(p.place_id));
  const sampled = spatialSample(rest, Math.max(0, limit - heroes.length));
  return [...heroes, ...sampled];
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
    cheapest_price:
      row.cheapest_price != null && Number.isFinite(Number(row.cheapest_price))
        ? Number(row.cheapest_price)
        : null,
    dearest_price:
      row.dearest_price != null && Number.isFinite(Number(row.dearest_price))
        ? Number(row.dearest_price)
        : null,
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
       AND ips.dearest_price <= ${CONSUMER_PRICE_CAP_SAR}
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

const SOURCE_MATCH_SQL = `
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
  JOIN LATERAL (
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
       AND ips.dearest_price <= ${CONSUMER_PRICE_CAP_SAR}
       AND EXISTS (
         SELECT 1
           FROM unnest($9::text[]) t
          WHERE COALESCE(ips.name_ar, '') ILIKE '%' || t || '%'
             OR COALESCE(ips.name_en, '') ILIKE '%' || t || '%'
       )
       AND COALESCE(ips.name_ar, '') !~* 'صوص|خبز|إضافة|اضافه'
       AND COALESCE(ips.name_en, '') !~* 'sauce|bun|add.?on'
     ORDER BY ips.cheapest_price ASC NULLS LAST,
              (ips.dearest_price - ips.cheapest_price) DESC NULLS LAST
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
  const hay = norm(
    [place.name, place.name_ar, place.name_en, place.city, place.product_name].join(
      ' ',
    ),
  );
  return hay.includes(q);
}

function bboxAroundPoint(lng, lat, padDeg = 0.018) {
  const pad = Number(padDeg);
  const d = Number.isFinite(pad) && pad > 0 ? pad : 0.018;
  if (!validCoord(lng, lat)) return null;
  return {
    west: lng - d,
    south: lat - d,
    east: lng + d,
    north: lat + d,
  };
}

function bboxToCsv(bbox) {
  if (!bbox) return '';
  return `${bbox.west},${bbox.south},${bbox.east},${bbox.north}`;
}

function likeSafe(term) {
  return String(term || '')
    .replace(/[%_\\]/g, '')
    .trim();
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

function toFeature(f, fields = 'pin') {
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
  if (pinFieldsMode(fields) === 'pin') return toSlimPinFeature(f);
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
      gap: observedGapRiyals(f.difference),
      cheapest_provider_id: f.difference?.cheapest_provider_id || null,
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
  const fields = pinFieldsMode(opts.fields);
  const limit = Math.min(Math.max(Number(opts.limit) || MAP_PIN_CAP, 1), MAP_PIN_CAP_MAX);

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
    limit,
    capped: pool.length > features.length,
    cluster_break_zoom: CLUSTER_BREAK_ZOOM,
    fields,
    server_clusters: false,
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
      `دبابيس مطاعم المقارنة من إحداثيات الصف الحقيقية. الحد ${limit} نقطة (تجميع Mapbox تحت زوم ${CLUSTER_BREAK_ZOOM}).`,
    note_en:
      `Comparison restaurant pins from real row coordinates. Cap ${limit} points — Mapbox clusters below zoom ${CLUSTER_BREAK_ZOOM}.`,
    features: features.map((f) => toFeature(f, fields)),
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
       AND ips.dearest_price <= ${CONSUMER_PRICE_CAP_SAR}
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

/**
 * The proof behind a pin. A number on a map is a claim; this is the evidence —
 * every item this restaurant sells on more than one app, with the price on
 * each app, so a person can check the «فرق» instead of trusting it.
 *
 * Source is comparison.menu_item_offers, one row per app per item, and NOT
 * item_price_spread: the spread matview keeps only items that actually differ,
 * so building the table from it would silently hide every item priced the same
 * everywhere — which is evidence too. The spread is still joined for the
 * canonical item name and typical_price.
 *
 * A provider with no offer row for an item is simply absent from `prices` —
 * never a null, never a zero, never carried over from another app.
 */
const META_SQL = `SELECT generated_at FROM comparison.read_layer_meta LIMIT 1`;

const PLACE_ITEMS_CAP = 200;

/**
 * An app can list the same item on several branch rows at different prices.
 * The price a person pays on that app is the lowest of them, which is also
 * exactly what item_price_spread aggregates — verified equal on the sampled
 * restaurants (2026-08-20), so the table can never contradict the pin.
 */
const PLACE_ITEMS_SQL = `
WITH offers AS (
  SELECT o.canonical_item_id,
         o.provider_code,
         o.current_price,
         o.provider_item_name_ar,
         o.provider_item_name_en
    FROM comparison.menu_item_offers o
   WHERE o.canonical_restaurant_id = $1::bigint
     AND o.provider_code IS NOT NULL
     AND btrim(o.provider_code) <> ''
     AND o.current_price IS NOT NULL
     AND o.current_price > 0
),
app_price AS (
  SELECT canonical_item_id, provider_code, min(current_price) AS price
    FROM offers
   GROUP BY 1, 2
),
offer_name AS (
  SELECT canonical_item_id,
         mode() WITHIN GROUP (ORDER BY provider_item_name_ar)
           FILTER (WHERE btrim(COALESCE(provider_item_name_ar, '')) <> '') AS name_ar,
         mode() WITHIN GROUP (ORDER BY provider_item_name_en)
           FILTER (WHERE btrim(COALESCE(provider_item_name_en, '')) <> '') AS name_en
    FROM offers
   GROUP BY 1
),
compared AS (
  SELECT canonical_item_id,
         count(*)::int AS provider_count,
         min(price) AS cheapest_price,
         max(price) AS dearest_price,
         jsonb_object_agg(provider_code, price) AS prices
    FROM app_price
   GROUP BY 1
  HAVING count(*) >= 2
)
SELECT c.canonical_item_id::text AS item_id,
       COALESCE(s.name_ar, n.name_ar) AS name_ar,
       COALESCE(s.name_en, n.name_en) AS name_en,
       c.provider_count,
       c.cheapest_price,
       c.dearest_price,
       c.prices,
       s.typical_price
  FROM compared c
  LEFT JOIN offer_name n ON n.canonical_item_id = c.canonical_item_id
  LEFT JOIN comparison.item_price_spread s
    ON s.canonical_restaurant_id = $1::bigint
   AND s.canonical_item_id = c.canonical_item_id
 ORDER BY (c.dearest_price - c.cheapest_price) DESC, c.canonical_item_id
 LIMIT $2
`;

const PLACE_ITEMS_HEAD_SQL = `
SELECT dc.canonical_restaurant_id::text AS place_id,
       dc.canonical_name_ar,
       dc.canonical_name_en,
       dc.city,
       dc.provider_count
  FROM comparison.discovery_cards dc
 WHERE dc.canonical_restaurant_id = $1::bigint
 LIMIT 1
`;

/**
 * One row per app, not per branch: restaurant_providers carries a row per
 * provider branch and most of them have no delivery_fee at all (~29% do), so
 * the branch that actually observed a fee wins the dedupe. Fees stay optional
 * evidence — a null is printed as nothing, never as «free».
 */
const PLACE_PROVIDERS_SQL = `
SELECT DISTINCT ON (rp.provider_code)
       rp.provider_code,
       rp.delivery_fee,
       rp.min_order,
       rp.rating,
       rp.eta
  FROM comparison.restaurant_providers rp
 WHERE rp.canonical_restaurant_id = $1::bigint
   AND rp.provider_code IS NOT NULL
   AND btrim(rp.provider_code) <> ''
 ORDER BY rp.provider_code,
          rp.is_active DESC NULLS LAST,
          (rp.delivery_fee IS NOT NULL) DESC,
          rp.observed_at DESC NULLS LAST,
          rp.provider_restaurant_id
`;

/**
 * Riyals, two decimals at most — halalas are real money, never rounded away.
 * A missing value stays null: Number(null) is 0, and a printed 0 would read as
 * «free delivery» or «no typical price» where we simply never observed one.
 */
function riyals(v) {
  if (v == null || v === '') return null;
  const n = Number(v);
  if (!Number.isFinite(n)) return null;
  return Math.round(n * 100) / 100;
}

function itemPct(cheapest, dearest) {
  const low = Number(cheapest);
  const high = Number(dearest);
  if (!Number.isFinite(low) || !Number.isFinite(high) || high <= 0) return null;
  return Math.round(((high - low) / high) * 100);
}

/** Provider names come from the price map, so a tie names nobody. */
function extremeProvider(prices, target) {
  const hits = Object.keys(prices).filter((code) => prices[code] === target);
  return hits.length === 1 ? hits[0] : null;
}

function rowToPlaceItem(row) {
  const itemId = String(row.item_id || '').trim();
  if (!/^\d+$/.test(itemId)) return null;
  const raw = row.prices && typeof row.prices === 'object' ? row.prices : null;
  if (!raw) return null;
  const prices = {};
  for (const [code, value] of Object.entries(raw)) {
    const key = String(code || '').trim();
    const price = riyals(value);
    if (!key || price == null || price <= 0) continue;
    prices[key] = price;
  }
  const codes = Object.keys(prices);
  if (codes.length < 2) return null;
  const cheapest = Math.min(...codes.map((c) => prices[c]));
  const dearest = Math.max(...codes.map((c) => prices[c]));
  const nameAr = String(row.name_ar || '').trim() || null;
  const nameEn = String(row.name_en || '').trim() || null;
  const name = nameAr || nameEn;
  if (!name) return null;
  return {
    item_id: itemId,
    name,
    name_ar: nameAr,
    name_en: nameEn,
    provider_count: codes.length,
    cheapest_provider_id: extremeProvider(prices, cheapest),
    cheapest_price: cheapest,
    expensive_provider_id: dearest > cheapest ? extremeProvider(prices, dearest) : null,
    expensive_price: dearest,
    gap: riyals(dearest - cheapest),
    pct: itemPct(cheapest, dearest),
    typical_price: riyals(row.typical_price),
    /**
     * The ranking layer refuses any spread where the dearest price is twice the
     * cheapest or more: `item_price_spread` tops out at a ratio of 1.9 across
     * all 56,245 rows, because one app at 149.50 against two at 50 is a scrape
     * error, not a saving. This table reads the raw offers, so without the same
     * rule it showed the reader exactly the rows the headline had thrown away —
     * with bigger numbers. The row stays visible and says what it is; silence
     * would be the worst of the three options.
     */
    price_outlier: cheapest > 0 && dearest >= cheapest * PRICE_OUTLIER_RATIO,
    prices,
  };
}

/** The ratio at or above which a spread is treated as a bad scrape, not a gap. */
const PRICE_OUTLIER_RATIO = 2;

/**
 * Biggest observed gap first; suspect spreads sit below the numbers the rest of
 * the product stands behind, and the same-price items stay at the bottom.
 */
function sortPlaceItems(items) {
  return items.slice().sort(
    (a, b) =>
      Number(Boolean(a.price_outlier)) - Number(Boolean(b.price_outlier)) ||
      Number(b.gap > 0) - Number(a.gap > 0) ||
      b.gap - a.gap ||
      a.name.localeCompare(b.name, 'ar'),
  );
}

function rowToPlaceProvider(row) {
  const providerId = String(row.provider_code || '').trim();
  if (!providerId) return null;
  return {
    provider_id: providerId,
    delivery_fee: riyals(row.delivery_fee),
    min_order: riyals(row.min_order),
    rating: riyals(row.rating),
    eta: row.eta ? String(row.eta) : null,
  };
}

/**
 * @param {string} placeId canonical_restaurant_id — digits only, never minted.
 * @param {{ __query?: Function }} opts
 */
async function getPlaceItems(placeId, opts = {}) {
  const id = String(placeId || '').trim();
  if (!/^\d+$/.test(id)) return null;
  const query = typeof opts.__query === 'function' ? opts.__query : comparisonQuery;
  if (!readEnabled() && typeof opts.__query !== 'function') return null;

  const [headRows, providerRows, itemRows, metaRows] = await Promise.all([
    query(PLACE_ITEMS_HEAD_SQL, [id]),
    query(PLACE_PROVIDERS_SQL, [id]),
    query(PLACE_ITEMS_SQL, [id, PLACE_ITEMS_CAP]),
    query(META_SQL, []).catch(() => []),
  ]);

  const head = headRows[0];
  if (!head) return null;
  const nameAr = String(head.canonical_name_ar || '').trim() || null;
  const nameEn = String(head.canonical_name_en || '').trim() || null;
  const name = nameAr || nameEn;
  if (!name) return null;

  const providers = [];
  for (const row of providerRows) {
    const provider = rowToPlaceProvider(row);
    if (provider) providers.push(provider);
  }
  const items = [];
  for (const row of itemRows) {
    const item = rowToPlaceItem(row);
    if (item) items.push(item);
  }
  const sorted = sortPlaceItems(items);

  return {
    place_id: String(head.place_id),
    name,
    name_ar: nameAr,
    name_en: nameEn,
    city: head.city ? String(head.city) : null,
    provider_count:
      head.provider_count != null && Number.isFinite(Number(head.provider_count))
        ? Number(head.provider_count)
        : providers.length || null,
    providers,
    count: sorted.length,
    items: sorted,
    source: 'comparison.menu_item_offers',
    generated_at: metaRows[0]?.generated_at
      ? new Date(metaRows[0].generated_at).toISOString()
      : null,
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

/**
 * Viewport bbox for chat — the request's camera box only.
 * Never falls back to all-Riyadh. Never substitutes RIYADH_VIEW.
 */
function parseViewportBbox(raw) {
  if (raw == null || raw === '') return null;
  if (typeof raw === 'object' && raw !== null) {
    const west = Number(raw.west);
    const south = Number(raw.south);
    const east = Number(raw.east);
    const north = Number(raw.north);
    if (![west, south, east, north].every(isFiniteNum)) return null;
    if (east === west || north === south) return null;
    return {
      west: Math.min(west, east),
      south: Math.min(south, north),
      east: Math.max(west, east),
      north: Math.max(south, north),
    };
  }
  const parts = String(raw)
    .split(',')
    .map((x) => Number.parseFloat(x));
  if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) return null;
  let [west, south, east, north] = parts;
  if (west > east) [west, east] = [east, west];
  if (south > north) [south, north] = [north, south];
  if (east === west || north === south) return null;
  return { west, south, east, north };
}

const VISIBLE_OPPORTUNITY_CAP = 12;
const SLIM_OPPORTUNITY_KEYS = Object.freeze([
  'place',
  'cheapest_provider',
  'expensive_provider',
  'cheapest_price',
  'highest_price',
  'difference_amount',
  'item',
  'lat',
  'lng',
]);

function slimOpportunity(place) {
  const slim = {};
  const name = String(place.name || '').trim();
  if (name) slim.place = name;
  if (place.cheapest_provider) slim.cheapest_provider = String(place.cheapest_provider);
  if (place.dearest_provider) slim.expensive_provider = String(place.dearest_provider);
  if (place.cheapest_price != null && Number.isFinite(Number(place.cheapest_price))) {
    slim.cheapest_price = Number(place.cheapest_price);
  }
  if (place.dearest_price != null && Number.isFinite(Number(place.dearest_price))) {
    slim.highest_price = Number(place.dearest_price);
  }
  if (
    place.difference_amount != null &&
    Number.isFinite(Number(place.difference_amount))
  ) {
    slim.difference_amount = Number(place.difference_amount);
  }
  const item = String(place.product_name || '').trim();
  if (item) slim.item = item;
  if (isFiniteNum(place.lat)) slim.lat = place.lat;
  if (isFiniteNum(place.lng)) slim.lng = place.lng;
  return slim;
}

function isComparablePlace(place) {
  return Boolean(
    place &&
      place.has_difference &&
      (place.cheapest_price != null || place.difference_amount != null),
  );
}

function clipRequestedBbox(requested) {
  if (!requested) {
    return { queried: null, empty_reason: 'invalid_bbox' };
  }
  const south = Math.max(requested.south, KSA.latMin);
  const north = Math.min(requested.north, KSA.latMax);
  const west = Math.max(requested.west, KSA.lngMin);
  const east = Math.min(requested.east, KSA.lngMax);
  if (south >= north || west >= east) {
    return { queried: null, empty_reason: 'out_of_coverage' };
  }
  return { queried: { west, south, east, north }, empty_reason: null };
}

function sortSlimOpportunities(slim, sort) {
  const rows = slim.slice();
  if (sort === 'cheapest') {
    rows.sort(
      (a, b) => (a.cheapest_price ?? Number.POSITIVE_INFINITY) - (b.cheapest_price ?? Number.POSITIVE_INFINITY),
    );
    return rows;
  }
  rows.sort((a, b) => (b.difference_amount || 0) - (a.difference_amount || 0));
  return rows;
}

async function queryOpportunitiesInBbox(opts = {}) {
  const requested = parseViewportBbox(opts.bbox) || parseBbox(opts.bbox);
  const cap = Math.min(
    Math.max(Number(opts.limit) || VISIBLE_OPPORTUNITY_CAP, 1),
    VISIBLE_OPPORTUNITY_CAP,
  );
  const clipped = clipRequestedBbox(requested);
  if (!clipped.queried) {
    return {
      opportunities: [],
      queried_bbox: null,
      requested_bbox: requested,
      empty_reason: clipped.empty_reason,
    };
  }
  const queried = clipped.queried;
  const query = typeof opts.__query === 'function' ? opts.__query : comparisonQuery;
  if (!readEnabled() && typeof opts.__query !== 'function') {
    return {
      opportunities: [],
      queried_bbox: queried,
      requested_bbox: requested,
      empty_reason: 'read_disabled',
    };
  }
  const qTerms = (Array.isArray(opts.qTerms) ? opts.qTerms : [])
    .map((t) => likeSafe(t))
    .filter((t) => t.length >= 3)
    .slice(0, 8);
  const params = [
    queried.south,
    queried.north,
    queried.west,
    queried.east,
    KSA.latMin,
    KSA.latMax,
    KSA.lngMin,
    KSA.lngMax,
  ];
  const sql = qTerms.length ? SOURCE_MATCH_SQL : LIST_SQL;
  if (qTerms.length) params.push(qTerms);
  const rows = await query(sql, params);
  const slim = [];
  for (const row of rows) {
    const place = rowToPlace(row);
    if (!isComparablePlace(place)) continue;
    slim.push(slimOpportunity(place));
  }
  const sorted = sortSlimOpportunities(slim, opts.sort);
  return {
    opportunities: sorted.slice(0, cap),
    queried_bbox: queried,
    requested_bbox: requested,
    empty_reason: slim.length ? null : 'insufficient_comparison',
    q_terms: qTerms.length ? qTerms : null,
    sort: opts.sort === 'cheapest' ? 'cheapest' : 'gap',
  };
}

/**
 * Slim observed gaps in the request viewport. Not a GeoJSON dump, not
 * clustered pins, not all-Riyadh unless that is the bbox the client sent.
 */
async function queryVisibleOpportunities(opts = {}) {
  const requested = parseViewportBbox(opts.bbox);
  if (!requested) {
    return {
      opportunities: [],
      queried_bbox: null,
      requested_bbox: null,
      empty_reason: 'invalid_bbox',
    };
  }
  return queryOpportunitiesInBbox({
    bbox: requested,
    limit: opts.limit,
    __query: opts.__query,
    sort: 'gap',
  });
}

/**
 * Same Farq comparison source as the map pins (discovery_cards +
 * item_price_spread). Bbox comes from a geocoded place, user GPS, or
 * documented Riyadh coverage — never an invented restaurant coordinate.
 */
async function querySourceOpportunities(opts = {}) {
  const requested =
    parseViewportBbox(opts.bbox) ||
    parseBbox(opts.bbox) ||
    (opts.bbox && typeof opts.bbox === 'object' ? opts.bbox : null);
  if (!requested) {
    return {
      opportunities: [],
      queried_bbox: null,
      requested_bbox: null,
      empty_reason: 'invalid_bbox',
    };
  }
  return queryOpportunitiesInBbox({
    bbox: requested,
    qTerms: opts.qTerms,
    sort: opts.sort,
    limit: opts.limit,
    __query: opts.__query,
  });
}

module.exports = {
  RIYADH_VIEW,
  CLUSTER_BREAK_ZOOM,
  PIN_FIELDS,
  MAP_PIN_CAP,
  MAP_PIN_CAP_MAX,
  MAP_PIN_HERO_RESERVE,
  CONSUMER_PRICE_CAP_SAR,
  VISIBLE_OPPORTUNITY_CAP,
  SLIM_OPPORTUNITY_KEYS,
  restaurantMenu,
  validCoord,
  parseBbox,
  parseViewportBbox,
  slimOpportunity,
  bboxAroundPoint,
  bboxToCsv,
  likeSafe,
  queryVisibleOpportunities,
  querySourceOpportunities,
  cellSizeForZoom,
  spatialSample,
  clusterPlaces,
  gridCluster,
  observedGapRiyals,
  pinFieldsMode,
  toSlimPinFeature,
  toFeature,
  queryPlaces,
  getPlace,
  PLACE_ITEMS_CAP,
  rowToPlaceItem,
  rowToPlaceProvider,
  sortPlaceItems,
  getPlaceItems,
  mapHealth,
  __resetCoverageCacheForTests,
};
