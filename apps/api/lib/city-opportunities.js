'use strict';

/**
 * City read model — every opportunity in a city, once.
 *
 * The map used to ask for pins viewport by viewport (400 at a time, a LATERAL
 * join per restaurant, no clustering possible). This module answers the
 * question the product actually asks — "what are the opportunities in Riyadh?"
 * — with one set-based query, and caches the answer for a few minutes. The
 * client can then pan, zoom, cluster, count and rank without a network round
 * trip, and "search here" is only needed when leaving the cached city.
 *
 * Data honesty, unchanged: coordinates come from comparison.discovery_cards,
 * gaps from comparison.item_price_spread. Nothing is invented; a restaurant
 * without an observed gap simply has gap = null.
 *
 * Freshness is a property of the whole read layer, not of a place: the source
 * carries no per-restaurant observation time (product_ready_restaurants
 * .latest_price_observed_at is null for every row, menu_item_offers
 * .freshness_status is a single constant), so the only honest timestamp is
 * read_layer_meta.generated_at, returned once at the collection level.
 *
 * A restaurant's representative opportunity is its largest observed gap among
 * consumer-priced items (<= CONSUMER_PRICE_CAP_SAR, approved 2026-08-20).
 */

const h3 = require('h3-js');
const { comparisonQuery } = require('./comparison-pool');
const { CONSUMER_PRICE_CAP_SAR, validCoord } = require('./comparison-map');

const KSA = { lngMin: 34, lngMax: 56, latMin: 16, latMax: 33 };

/** Approved tiers (2026-08-20): Hero ≥36 · Strong 15–35 · Regular 5–14 · Faint <5. */
const TIERS = Object.freeze({ hero: 36, strong: 15, regular: 5 });

/** H3 resolution for area aggregates: ~0.74 km² cells — a neighbourhood, not a block. */
const AREA_H3_RES = 8;

/** Cities the read model knows, with the spellings the source uses. */
const CITY_ALIASES = Object.freeze({
  riyadh: ['riyadh', 'الرياض'],
  jeddah: ['jeddah', 'جدة'],
  dammam: ['dammam', 'الدمام'],
  makkah: ['makkah', 'mecca', 'مكة'],
  madinah: ['madinah', 'medina', 'المدينة'],
});

const CACHE_TTL_MS = 10 * 60 * 1000;
const cache = new Map(); // city -> { at, value, etag }

function tierForGap(gap) {
  const n = Number(gap);
  if (!Number.isFinite(n) || n <= 0) return null;
  if (n >= TIERS.hero) return 'hero';
  if (n >= TIERS.strong) return 'strong';
  if (n >= TIERS.regular) return 'regular';
  return 'faint';
}

function normalizeCity(raw) {
  const key = String(raw || '').trim().toLowerCase();
  return CITY_ALIASES[key] ? key : null;
}

function finite(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function pct(cheapest, dearest) {
  const low = finite(cheapest);
  const high = finite(dearest);
  if (low == null || high == null || high <= 0) return null;
  return Math.round(((high - low) / high) * 100);
}

/**
 * One pass over item_price_spread picks each restaurant's best consumer
 * opportunity; one pass counts which app was cheapest how often per
 * restaurant (the basis of "which app tonight?"); both join discovery_cards
 * for coordinates.
 */
const CITY_SQL = `
WITH best AS (
  SELECT DISTINCT ON (ips.canonical_restaurant_id)
         ips.canonical_restaurant_id,
         ips.canonical_item_id,
         ips.cheapest_provider,
         ips.dearest_provider,
         ips.cheapest_price,
         ips.dearest_price,
         (ips.dearest_price - ips.cheapest_price) AS gap,
         COALESCE(ips.name_ar, ips.name_en) AS product_name
    FROM comparison.item_price_spread ips
   WHERE ips.cheapest_provider IS NOT NULL
     AND btrim(ips.cheapest_provider) <> ''
     AND ips.dearest_price IS NOT NULL
     AND ips.cheapest_price IS NOT NULL
     AND ips.dearest_price > ips.cheapest_price
     AND ips.dearest_price <= $2
   ORDER BY ips.canonical_restaurant_id,
            (ips.dearest_price - ips.cheapest_price) DESC
),
wins AS (
  SELECT ips.canonical_restaurant_id,
         jsonb_object_agg(ips.cheapest_provider, ips.n) AS wins,
         SUM(ips.n)::int AS comparisons
    FROM (
      SELECT canonical_restaurant_id, cheapest_provider, COUNT(*)::int AS n
        FROM comparison.item_price_spread
       WHERE cheapest_provider IS NOT NULL
         AND btrim(cheapest_provider) <> ''
         AND dearest_price IS NOT NULL
         AND cheapest_price IS NOT NULL
         AND dearest_price > cheapest_price
         AND dearest_price <= $2
       GROUP BY 1, 2
    ) ips
   GROUP BY 1
)
SELECT dc.canonical_restaurant_id::text AS place_id,
       dc.canonical_name_ar,
       dc.canonical_name_en,
       dc.latitude,
       dc.longitude,
       dc.provider_count,
       dc.rating,
       b.canonical_item_id::text AS item_id,
       b.cheapest_provider,
       b.dearest_provider,
       b.cheapest_price,
       b.dearest_price,
       b.gap,
       b.product_name,
       w.wins,
       w.comparisons
  FROM comparison.discovery_cards dc
  LEFT JOIN best b ON b.canonical_restaurant_id = dc.canonical_restaurant_id
  LEFT JOIN wins w ON w.canonical_restaurant_id = dc.canonical_restaurant_id
 WHERE dc.latitude IS NOT NULL
   AND dc.longitude IS NOT NULL
   AND lower(btrim(dc.city)) = ANY($1::text[])
`;

const META_SQL = `SELECT generated_at FROM comparison.read_layer_meta LIMIT 1`;

function rowToFeature(row) {
  const lng = Number(row.longitude);
  const lat = Number(row.latitude);
  if (!validCoord(lng, lat)) return null;
  const placeId = String(row.place_id || '').trim();
  if (!/^\d+$/.test(placeId)) return null;
  const name = String(row.canonical_name_ar || row.canonical_name_en || '').trim();
  if (!name) return null;
  const gap = finite(row.gap);
  const hasGap = gap != null && Math.round(gap) >= 1;
  return {
    type: 'Feature',
    id: Number(placeId),
    geometry: { type: 'Point', coordinates: [lng, lat] },
    properties: {
      feature_type: 'place',
      place_id: placeId,
      name,
      name_en: row.canonical_name_en ? String(row.canonical_name_en) : null,
      gap: hasGap ? Math.round(gap) : null,
      pct: hasGap ? pct(row.cheapest_price, row.dearest_price) : null,
      tier: hasGap ? tierForGap(gap) : null,
      item_id: hasGap && row.item_id ? String(row.item_id) : null,
      product_name: hasGap && row.product_name ? String(row.product_name) : null,
      cheapest_provider_id: hasGap && row.cheapest_provider ? String(row.cheapest_provider) : null,
      expensive_provider_id: hasGap && row.dearest_provider ? String(row.dearest_provider) : null,
      cheapest_price: hasGap ? finite(row.cheapest_price) : null,
      expensive_price: hasGap ? finite(row.dearest_price) : null,
      has_difference: hasGap,
      provider_count: finite(row.provider_count),
      comparisons: finite(row.comparisons) || 0,
      wins: row.wins && typeof row.wins === 'object' ? row.wins : null,
      h3: h3.latLngToCell(lat, lng, AREA_H3_RES),
    },
  };
}

async function loadCity(cityKey, query) {
  const aliases = CITY_ALIASES[cityKey];
  const [rows, metaRows] = await Promise.all([
    query(CITY_SQL, [aliases, CONSUMER_PRICE_CAP_SAR]),
    query(META_SQL, []).catch(() => []),
  ]);
  const features = [];
  for (const row of rows) {
    const f = rowToFeature(row);
    if (f) features.push(f);
  }
  features.sort((a, b) => (b.properties.gap || 0) - (a.properties.gap || 0) || a.properties.place_id.localeCompare(b.properties.place_id));
  const generatedAt = metaRows[0]?.generated_at
    ? new Date(metaRows[0].generated_at).toISOString()
    : null;
  const withGap = features.filter((f) => f.properties.has_difference).length;
  return {
    type: 'FeatureCollection',
    city: cityKey,
    count: features.length,
    with_gap: withGap,
    tiers: TIERS,
    source: 'comparison.discovery_cards + item_price_spread',
    freshness: 'read_layer',
    consumer_price_cap_sar: CONSUMER_PRICE_CAP_SAR,
    generated_at: generatedAt,
    features,
  };
}

function etagFor(body) {
  return `W/"${body.city}-${body.count}-${body.with_gap}-${body.generated_at || 'na'}"`;
}

/**
 * @param {{ city?: string, include?: 'opportunities'|'all', __query?: Function, __now?: number }} opts
 */
async function getCityOpportunities(opts = {}) {
  const cityKey = normalizeCity(opts.city);
  if (!cityKey) return null;
  const query = opts.__query || comparisonQuery;
  const now = opts.__now ?? Date.now();
  let entry = cache.get(cityKey);
  if (!entry || now - entry.at > CACHE_TTL_MS || opts.__query || opts.__force) {
    const value = await loadCity(cityKey, query);
    entry = { at: now, value, etag: etagFor(value) };
    if (!opts.__query) cache.set(cityKey, entry);
  }
  const includeAll = String(opts.include || 'opportunities') === 'all';
  const features = includeAll
    ? entry.value.features
    : entry.value.features.filter((f) => f.properties.has_difference);
  return {
    body: { ...entry.value, include: includeAll ? 'all' : 'opportunities', count: features.length, features },
    etag: `${entry.etag.slice(0, -1)}-${includeAll ? 'all' : 'opp'}"`,
  };
}

/**
 * Area aggregates on H3 res 8: how many opportunities, the biggest, and which
 * app was cheapest how often. Counts below MIN_AREA_COMPARISONS are still
 * returned, but `enough_for_app_verdict` tells the client not to name a
 * winner on a handful of rows (approved minimum: 8 comparisons).
 */
const MIN_AREA_COMPARISONS = 8;

function aggregateAreas(features) {
  const cells = new Map();
  for (const f of features) {
    const p = f.properties;
    const id = p.h3;
    let c = cells.get(id);
    if (!c) {
      c = { h3: id, places: 0, opportunities: 0, max_gap: 0, top_place_id: null, comparisons: 0, wins: {} };
      cells.set(id, c);
    }
    c.places += 1;
    if (p.has_difference) {
      c.opportunities += 1;
      if (p.gap > c.max_gap) {
        c.max_gap = p.gap;
        c.top_place_id = p.place_id;
      }
    }
    if (p.wins) {
      for (const [provider, n] of Object.entries(p.wins)) {
        const k = String(provider);
        c.wins[k] = (c.wins[k] || 0) + Number(n || 0);
        c.comparisons += Number(n || 0);
      }
    }
  }
  const out = [];
  for (const c of cells.values()) {
    let leader = null;
    let leaderWins = 0;
    for (const [provider, n] of Object.entries(c.wins)) {
      if (n > leaderWins) {
        leader = provider;
        leaderWins = n;
      }
    }
    const enough = c.comparisons >= MIN_AREA_COMPARISONS;
    out.push({
      type: 'Feature',
      id: c.h3,
      geometry: { type: 'Polygon', coordinates: [h3.cellToBoundary(c.h3, true)] },
      properties: {
        h3: c.h3,
        places: c.places,
        opportunities: c.opportunities,
        max_gap: c.opportunities ? c.max_gap : null,
        top_place_id: c.top_place_id,
        comparisons: c.comparisons,
        wins: c.wins,
        enough_for_app_verdict: enough,
        cheapest_app: enough ? leader : null,
        cheapest_app_wins: enough ? leaderWins : null,
      },
    });
  }
  out.sort((a, b) => b.properties.opportunities - a.properties.opportunities);
  return out;
}

async function getCityAreas(opts = {}) {
  const city = await getCityOpportunities({ ...opts, include: 'all' });
  if (!city) return null;
  const features = aggregateAreas(city.body.features);
  return {
    body: {
      type: 'FeatureCollection',
      city: city.body.city,
      resolution: AREA_H3_RES,
      min_comparisons_for_app_verdict: MIN_AREA_COMPARISONS,
      generated_at: city.body.generated_at,
      count: features.length,
      features,
    },
    etag: `${city.etag.slice(0, -1)}-areas"`,
  };
}

/**
 * Fill the cache before anyone asks. The SQL runs in ~200 ms but the rows
 * travel far; a cold miss costs seconds, so the server takes it at boot and
 * every TTL thereafter instead of the first visitor.
 */
function warmCityCache(cities = ['riyadh'], opts = {}) {
  const log = opts.log || ((msg) => console.log(`[city-cache] ${msg}`));
  const run = async () => {
    for (const city of cities) {
      const started = Date.now();
      try {
        await getCityOpportunities({ city, __force: true });
        log(`${city} warmed in ${Date.now() - started}ms`);
      } catch (err) {
        log(`${city} warm failed: ${err.message}`);
      }
    }
  };
  void run();
  const timer = setInterval(run, CACHE_TTL_MS);
  if (typeof timer.unref === 'function') timer.unref();
  return () => clearInterval(timer);
}

function __resetCityCacheForTests() {
  cache.clear();
}

module.exports = {
  AREA_H3_RES,
  CITY_ALIASES,
  MIN_AREA_COMPARISONS,
  TIERS,
  aggregateAreas,
  getCityAreas,
  getCityOpportunities,
  normalizeCity,
  rowToFeature,
  tierForGap,
  warmCityCache,
  __resetCityCacheForTests,
};
