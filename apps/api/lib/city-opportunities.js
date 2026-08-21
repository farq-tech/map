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

const { comparisonQuery } = require('./comparison-pool');
const { CONSUMER_PRICE_CAP_SAR, validCoord } = require('./comparison-map');
const { districtOfPoint, loadDistricts } = require('./city-districts');
const { placeConfidence, attributableToDistrict } = require('./place-truth');
const { resolveDestination } = require('./place-navigation');
const readLayerGuard = require('./read-layer-guard');
const integrity = require('./result-integrity');
const {
  categoryCaseSql,
  deliveryAdjustedGap,
  demoteReason,
  displayItemName,
  normalizedNameSql,
  retailItemPattern,
  shareItemPattern,
} = require('./consumer-items');
const {
  MIN_AREA_COMPARISONS,
  aggregateByKey,
  emptyStats,
  statsToProperties,
} = require('./opportunity-aggregate');

/** Bump when the shape of a feature changes, so a cached client refetches. */
const READ_MODEL_VERSION = 4;

const KSA = { lngMin: 34, lngMax: 56, latMin: 16, latMax: 33 };

/** Approved tiers (2026-08-20): Hero ≥36 · Strong 15–35 · Regular 5–14 · Faint <5. */
const TIERS = Object.freeze({ hero: 36, strong: 15, regular: 5 });

/** Cities the read model knows, with the spellings the source uses. */
const CITY_ALIASES = Object.freeze({
  riyadh: ['riyadh', 'الرياض'],
  jeddah: ['jeddah', 'جدة'],
  dammam: ['dammam', 'الدمام'],
  makkah: ['makkah', 'mecca', 'مكة'],
  madinah: ['madinah', 'medina', 'المدينة'],
});

const CACHE_TTL_MS = 10 * 60 * 1000;
const cache = new Map();
/** The last snapshot that passed the rebuild guard, per city. */
const lastGoodSnapshot = new Map();
/** Why the most recent rebuild was turned away, per city, for the health endpoint. */
const refusedSnapshots = new Map();

/**
 * The أحياء aggregate derived from a cached city used to be rebuilt on every
 * request, folding ~8,700 features each time for an answer that cannot change
 * until the city cache does. Keyed by the city's own ETag, so a refresh
 * invalidates it for free and a stale one is impossible.
 */
const derived = new Map(); // `${kind}:${city}` -> { etag, value }

/**
 * One city query in flight at a time. The load is heavier now that every item
 * is classified, and a cold cache — a fresh deploy, or the first visitors
 * after a TTL — used to start one full query per waiting request. They now
 * share the first one; if it fails, the next caller is free to try again.
 */
const inFlight = new Map(); // city -> Promise

function memoDerived(kind, cityKey, etag, build) {
  const key = `${kind}:${cityKey}`;
  const hit = derived.get(key);
  if (hit && hit.etag === etag) return hit.value;
  const value = build();
  derived.set(key, { etag, value });
  return value;
}

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

/**
 * A missing value is missing, not zero. `Number(null)` is 0, and that single
 * coercion was enough to turn "we never observed a delivery fee for Mrsool"
 * into "Mrsool delivers free": only HungerStation has any fee recorded at all
 * (14,129 rows), every other provider is NULL for every row, and the database
 * holds no genuine zero anywhere. Unknown has to stay unknown.
 */
function finite(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function pct(cheapest, dearest) {
  const low = finite(cheapest);
  const high = finite(dearest);
  if (low == null || high == null || high <= 0) return null;
  return Math.round(((high - low) / high) * 100);
}

const ITEM_NAME_EXPR = "coalesce(ips.name_ar,'') || ' ' || coalesce(ips.name_en,'')";

/**
 * One pass over item_price_spread classifies every comparable item, then
 * picks:
 *   · the restaurant's representative opportunity — the biggest gap on
 *     something one person actually orders (see consumer-items.js). A share
 *     box or a tub of creatine only represents a restaurant that has nothing
 *     else, and says so through `demote_reason`;
 *   · its best gap per food category, so "أبي برجر" can rank a restaurant by
 *     its burger instead of by whatever item happened to be its largest;
 *   · how often each app was cheapest, the basis of "which app tonight?".
 *
 * Delivery fees for the two providers involved ride along. They are observed
 * on one side or the other but never both today, so the adjusted gap stays
 * null — the query carries them anyway so the honest number appears the day
 * the crawler records the pair, rather than waiting for a schema change.
 */
const CITY_SQL = `
WITH branch_spread AS (
  /* How far apart are the pins the delivery apps give for one canonical
   * restaurant? A large answer means the upstream match joined branches of a
   * chain, not listings of one branch — see place-truth.js for what that costs.
   * Max pairwise, not bounding box: at most eight providers per restaurant, so
   * the self-join is bounded and the number is exact. */
  SELECT p.canonical_restaurant_id,
         MAX(2*6371000*asin(sqrt(
             power(sin(radians(q.lat::float - p.lat::float)/2), 2)
           + cos(radians(p.lat::float)) * cos(radians(q.lat::float))
             * power(sin(radians(q.lon::float - p.lon::float)/2), 2)))) AS spread_m
    FROM comparison.restaurant_providers p
    JOIN comparison.restaurant_providers q
      ON q.canonical_restaurant_id = p.canonical_restaurant_id
     AND q.provider_restaurant_id::text > p.provider_restaurant_id::text
   WHERE p.lat IS NOT NULL AND p.lon IS NOT NULL
     AND q.lat IS NOT NULL AND q.lon IS NOT NULL
   GROUP BY 1
),
scored AS (
  SELECT ips.canonical_restaurant_id,
         ips.canonical_item_id,
         ips.cheapest_provider,
         ips.dearest_provider,
         ips.cheapest_price,
         ips.dearest_price,
         (ips.dearest_price - ips.cheapest_price) AS gap,
         COALESCE(ips.name_ar, ips.name_en) AS product_name,
         ${normalizedNameSql(ITEM_NAME_EXPR)} ~ '${shareItemPattern()}' AS is_share,
         ${normalizedNameSql(ITEM_NAME_EXPR)} ~ '${retailItemPattern()}' AS is_retail,
         ${categoryCaseSql(ITEM_NAME_EXPR)} AS category
    FROM comparison.item_price_spread ips
   WHERE ips.cheapest_provider IS NOT NULL
     AND btrim(ips.cheapest_provider) <> ''
     AND ips.dearest_price IS NOT NULL
     AND ips.cheapest_price IS NOT NULL
     AND ips.dearest_price > ips.cheapest_price
     AND ips.dearest_price <= $2
),
best AS (
  SELECT DISTINCT ON (canonical_restaurant_id) *
    FROM scored
   ORDER BY canonical_restaurant_id, (is_share OR is_retail) ASC, gap DESC
),
per_category AS (
  SELECT DISTINCT ON (canonical_restaurant_id, category)
         canonical_restaurant_id, category, gap
    FROM scored
   WHERE category IS NOT NULL AND NOT is_share AND NOT is_retail
   ORDER BY canonical_restaurant_id, category, gap DESC
),
cats AS (
  SELECT canonical_restaurant_id,
         jsonb_object_agg(category, round(gap)::int) AS category_gaps
    FROM per_category
   WHERE gap >= 1
   GROUP BY 1
),
wins AS (
  SELECT canonical_restaurant_id,
         jsonb_object_agg(cheapest_provider, n) AS wins,
         SUM(n)::int AS comparisons
    FROM (
      SELECT canonical_restaurant_id, cheapest_provider, COUNT(*)::int AS n
        FROM scored
       GROUP BY 1, 2
    ) x
   GROUP BY 1
)
SELECT dc.canonical_restaurant_id::text AS place_id,
       dc.canonical_name_ar,
       dc.canonical_name_en,
       dc.brand_key,
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
       b.is_share,
       b.is_retail,
       c.category_gaps,
       fc.delivery_fee AS cheapest_delivery_fee,
       fd.delivery_fee AS expensive_delivery_fee,
       w.wins,
       w.comparisons,
       bs.spread_m AS branch_spread_m,
       nb.lat AS branch_lat,
       nb.lon AS branch_lng
  FROM comparison.discovery_cards dc
  LEFT JOIN best b ON b.canonical_restaurant_id = dc.canonical_restaurant_id
  LEFT JOIN cats c ON c.canonical_restaurant_id = dc.canonical_restaurant_id
  LEFT JOIN wins w ON w.canonical_restaurant_id = dc.canonical_restaurant_id
  LEFT JOIN branch_spread bs ON bs.canonical_restaurant_id = dc.canonical_restaurant_id
  /* A restaurant can carry several rows for one app; take one deterministically
   * rather than averaging fees that were never observed together. */
  LEFT JOIN LATERAL (
    SELECT rp.delivery_fee
      FROM comparison.restaurant_providers rp
     WHERE rp.canonical_restaurant_id = dc.canonical_restaurant_id
       AND rp.provider_code = b.cheapest_provider
       AND rp.delivery_fee IS NOT NULL
     ORDER BY rp.provider_restaurant_id
     LIMIT 1
  ) fc ON TRUE
  /* Where the cheapest offer actually is. A canonical restaurant carries one
   * pin, but the price we quote belongs to one branch of one app — and measured,
   * 591 of Riyadh's opportunities have that branch more than a kilometre from
   * the pin, the worst by 28.7 km. Drawing the pin there is a glance; sending a
   * person there is their evening. */
  LEFT JOIN LATERAL (
    SELECT rp.lat, rp.lon
      FROM comparison.restaurant_providers rp
     WHERE rp.canonical_restaurant_id = dc.canonical_restaurant_id
       AND rp.provider_code = b.cheapest_provider
       AND rp.lat IS NOT NULL AND rp.lon IS NOT NULL
     ORDER BY rp.provider_restaurant_id
     LIMIT 1
  ) nb ON TRUE
  LEFT JOIN LATERAL (
    SELECT rp.delivery_fee
      FROM comparison.restaurant_providers rp
     WHERE rp.canonical_restaurant_id = dc.canonical_restaurant_id
       AND rp.provider_code = b.dearest_provider
       AND rp.delivery_fee IS NOT NULL
     ORDER BY rp.provider_restaurant_id
     LIMIT 1
  ) fd ON TRUE
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
  const productName = hasGap && row.product_name ? String(row.product_name) : null;
  /* The row already knows why it was demoted; recomputing from the name keeps
   * the reason available when a caller builds a feature without the SQL. */
  const reason = hasGap
    ? row.is_share === true
      ? 'share'
      : row.is_retail === true
        ? 'retail'
        : row.is_share === undefined
          ? demoteReason(productName)
          : null
    : null;
  const adjusted = hasGap
    ? deliveryAdjustedGap({
        cheapestPrice: row.cheapest_price,
        dearestPrice: row.dearest_price,
        cheapestFee: row.cheapest_delivery_fee,
        dearestFee: row.expensive_delivery_fee,
      })
    : null;
  return {
    type: 'Feature',
    id: Number(placeId),
    geometry: { type: 'Point', coordinates: [lng, lat] },
    properties: {
      feature_type: 'place',
      place_id: placeId,
      name,
      name_en: row.canonical_name_en ? String(row.canonical_name_en) : null,
      /* Branches of one chain repeat the same item and the same gap: 5,222 of
       * Riyadh's 8,745 cards are extra branches. Every branch is a real place
       * and keeps its pin; the key lets a list show a brand once. */
      brand_key: row.brand_key ? String(row.brand_key) : null,
      gap: hasGap ? Math.round(gap) : null,
      pct: hasGap ? pct(row.cheapest_price, row.dearest_price) : null,
      tier: hasGap ? tierForGap(gap) : null,
      item_id: hasGap && row.item_id ? String(row.item_id) : null,
      product_name: productName ? displayItemName(productName) : null,
      /* null when the representative item is what a person orders for one; a
       * reason when the restaurant only had a share box or packaged retail. */
      demote_reason: reason,
      /* Best gap per food category, so a category filter ranks a restaurant by
       * that category instead of by its largest item overall. */
      category_gaps:
        row.category_gaps && typeof row.category_gaps === 'object' ? row.category_gaps : null,
      cheapest_provider_id: hasGap && row.cheapest_provider ? String(row.cheapest_provider) : null,
      expensive_provider_id: hasGap && row.dearest_provider ? String(row.dearest_provider) : null,
      cheapest_price: hasGap ? finite(row.cheapest_price) : null,
      expensive_price: hasGap ? finite(row.dearest_price) : null,
      cheapest_delivery_fee: finite(row.cheapest_delivery_fee),
      expensive_delivery_fee: finite(row.expensive_delivery_fee),
      /* Only when both fees were observed — never an average, never a zero. */
      delivery_adjusted_gap: adjusted,
      has_difference: hasGap,
      provider_count: finite(row.provider_count),
      comparisons: finite(row.comparisons) || 0,
      /* How far apart the apps place this restaurant's branches, and what that
       * lets us claim about it. See place-truth.js — 4.5% of the places we draw
       * in Riyadh are chains merged into one pin. */
      branch_spread_m: finite(row.branch_spread_m),
      place_confidence: placeConfidence({
        spreadMeters: row.branch_spread_m,
        providerCount: row.provider_count,
      }),
      /* Where to actually send someone — see place-navigation.js. Null when we
       * cannot name a branch honestly, which is a better answer than a wrong one. */
      navigate_to: (() => {
        const d = resolveDestination({
          placeLat: lat,
          placeLng: lng,
          providerLat: row.branch_lat,
          providerLng: row.branch_lng,
          provider: hasGap && row.cheapest_provider ? String(row.cheapest_provider) : null,
          branchSpreadMeters: row.branch_spread_m,
          providerCount: row.provider_count,
        });
        return d.lat === null
          ? { lat: null, lng: null, source: null, confidence: d.confidence, reason: d.reason }
          : d;
      })(),
      wins: row.wins && typeof row.wins === 'object' ? row.wins : null,
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
  /* Which حي each place is in — by its coordinates, never by name. Outside every
   * polygon (or a city without boundaries) is null, not a guess. */
  const districts = loadDistricts(cityKey);
  for (const f of features) {
    const [lng, lat] = f.geometry.coordinates;
    /* A place whose own branches are kilometres apart has a pin, but the pin
     * describes one branch out of several. The map already refuses to place an
     * opportunity that falls in no polygon, on the rule that a wrong حي is worse
     * than an uncounted one; this is the same failure wearing a coordinate, so
     * it gets the same answer. The place still appears on the map with its own
     * number — it is only barred from being counted as belonging to one حي. */
    f.properties.district_id =
      districts && attributableToDistrict(f.properties.place_confidence)
        ? districtOfPoint(cityKey, lng, lat, { __loaded: districts })
        : null;
  }
  /* Default order is the one a person should meet: a real dinner order before a
   * share box of the same size, then the biggest gap. Clients re-rank freely. */
  features.sort(
    (a, b) =>
      Number(Boolean(a.properties.demote_reason)) - Number(Boolean(b.properties.demote_reason)) ||
      (b.properties.gap || 0) - (a.properties.gap || 0) ||
      a.properties.place_id.localeCompare(b.properties.place_id),
  );
  const generatedAt = metaRows[0]?.generated_at
    ? new Date(metaRows[0].generated_at).toISOString()
    : null;
  const withGap = features.filter((f) => f.properties.has_difference).length;
  return {
    type: 'FeatureCollection',
    city: cityKey,
    count: features.length,
    with_gap: withGap,
    /* How many أحياء this city ships. The rebuild guard needs the denominator to
     * judge whether district coverage collapsed; without it that rule silently
     * never fires, which is worse than not having the rule. */
    districts_total: districts ? districts.prepared.length : null,
    tiers: TIERS,
    source: 'comparison.discovery_cards + item_price_spread',
    freshness: 'read_layer',
    consumer_price_cap_sar: CONSUMER_PRICE_CAP_SAR,
    generated_at: generatedAt,
    features,
  };
}

function etagFor(body) {
  return `W/"v${READ_MODEL_VERSION}-${body.city}-${body.count}-${body.with_gap}-${body.generated_at || 'na'}"`;
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
    if (opts.__query) {
      entry = { at: now, value: await loadCity(cityKey, query), etag: null };
      entry.etag = etagFor(entry.value);
    } else {
      let pending = inFlight.get(cityKey);
      if (!pending) {
        pending = loadCity(cityKey, query).finally(() => inFlight.delete(cityKey));
        inFlight.set(cityKey, pending);
      }
      const value = await pending;
      /**
       * The moment a rebuild reaches users. A snapshot that has lost a third of
       * its restaurants, or a required column, or most of its providers, is not
       * served — the previous snapshot keeps serving instead, stale and correct
       * rather than fresh and wrong. See read-layer-guard.js for why the
       * thresholds are set at catastrophe level and what to tighten them to.
       */
      const candidate = readLayerGuard.summarize(value.features, {
        city: cityKey,
        generatedAt: value.generated_at,
      });
      const verdict = readLayerGuard.evaluateSnapshot(candidate, lastGoodSnapshot.get(cityKey), {
        totalDistricts: (value.districts_total ?? null),
      });
      if (!verdict.accept && entry) {
        integrity.record({
          status: 'rebuild-refused',
          severity: 'failed',
          city: cityKey,
          count: candidate.count,
          sourceCount: candidate.count,
          detail: verdict.violations.map((v) => `${v.rule}: ${v.detail}`).join('; '),
        });
        /* Keep the entry we already had, and let the next refresh try again. */
        entry.at = Date.now();
        cache.set(cityKey, entry);
        refusedSnapshots.set(cityKey, { at: new Date().toISOString(), ...verdict });
      } else {
        if (!verdict.accept) {
          /* Nothing better to fall back to. Serve it, but say so loudly rather
           * than pretend the first snapshot of the process was verified. */
          integrity.record({
            status: 'rebuild-unverified',
            severity: 'failed',
            city: cityKey,
            count: candidate.count,
            sourceCount: candidate.count,
            detail: `no previous snapshot to fall back to; ${verdict.violations.map((v) => v.rule).join(', ')}`,
          });
        }
        lastGoodSnapshot.set(cityKey, candidate);
        refusedSnapshots.delete(cityKey);
        entry = { at: Date.now(), value, etag: etagFor(value) };
        cache.set(cityKey, entry);
      }
    }
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
 * The same aggregates per حي. Every district of the city is returned — an
 * empty one carries zero and null, so the map can still draw its boundary —
 * and membership is the geometric `district_id` stamped on each place.
 */
function aggregateDistricts(loaded, features) {
  const groups = aggregateByKey(features, (f) => (f.properties && f.properties.district_id) || null);
  const out = loaded.prepared.map((d) => ({
    type: 'Feature',
    id: d.id,
    geometry: d.feature.geometry,
    properties: {
      district_id: d.id,
      name_ar: d.name_ar,
      name_en: d.name_en,
      /* Only present when this city holds more than one حي by this name — see
       * stampAmbiguityHints in city-districts.js. */
      name_hint_ar: d.name_hint_ar || null,
      name_hint_en: d.name_hint_en || null,
      bbox: d.bbox.slice(),
      label_point: d.label_point ? d.label_point.slice() : null,
      ...statsToProperties(groups.get(d.id) || emptyStats(), MIN_AREA_COMPARISONS),
    },
  }));
  out.sort(
    (a, b) =>
      b.properties.opportunities - a.properties.opportunities ||
      a.properties.district_id.localeCompare(b.properties.district_id),
  );
  return out;
}

async function getCityDistricts(opts = {}) {
  const city = await getCityOpportunities({ ...opts, include: 'all' });
  if (!city) return null;
  const loaded = loadDistricts(city.body.city);
  if (!loaded) return null;
  const features = opts.__query
    ? aggregateDistricts(loaded, city.body.features)
    : memoDerived('districts', city.body.city, city.etag, () =>
        aggregateDistricts(loaded, city.body.features),
      );
  return {
    body: {
      type: 'FeatureCollection',
      city: city.body.city,
      source: loaded.source,
      min_comparisons_for_app_verdict: MIN_AREA_COMPARISONS,
      generated_at: city.body.generated_at,
      count: features.length,
      features,
    },
    etag: `${city.etag.slice(0, -1)}-districts"`,
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
  derived.clear();
}

module.exports = {
  refusedSnapshots,
  CITY_ALIASES,
  MIN_AREA_COMPARISONS,
  TIERS,
  aggregateDistricts,
  getCityDistricts,
  getCityOpportunities,
  normalizeCity,
  rowToFeature,
  tierForGap,
  warmCityCache,
  __resetCityCacheForTests,
};
