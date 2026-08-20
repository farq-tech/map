'use strict';

/**
 * Copilot tools — every answer is assembled from rows of the city read model.
 *
 * The tools are deterministic, typed and cheap: they run over the cached city
 * collection (see city-opportunities.js), never over the model's memory. Every
 * row carries a short id (r1, r2, …) plus the real place_id, so an answer or
 * an action can only ever point at something that exists.
 */

const { getCityOpportunities } = require('./city-opportunities');
const { geocodePlace } = require('./geocode-place');
const { normalizeArabic } = require('./copilot-intent');

const DEFAULT_NEAR_KM = 2;
const MAX_ROWS = 10;
const MIN_APP_VERDICT_COMPARISONS = 8;

function haversineKm(lat1, lng1, lat2, lng2) {
  const toRad = (d) => (d * Math.PI) / 180;
  const r = 6371;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.asin(Math.min(1, Math.sqrt(a)));
}

function parseBboxCsv(raw) {
  if (Array.isArray(raw) && raw.length === 4 && raw.every((n) => Number.isFinite(Number(n)))) {
    const [a, b, c, d] = raw.map(Number);
    return [Math.min(a, c), Math.min(b, d), Math.max(a, c), Math.max(b, d)];
  }
  const p = String(raw || '').split(',').map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isFinite(n))) return null;
  return [Math.min(p[0], p[2]), Math.min(p[1], p[3]), Math.max(p[0], p[2]), Math.max(p[1], p[3])];
}

function bboxAround(lat, lng, km) {
  const dLat = km / 111;
  const dLng = km / (111 * Math.cos((lat * Math.PI) / 180));
  return [lng - dLng, lat - dLat, lng + dLng, lat + dLat];
}

function inBbox(lng, lat, b) {
  return lng >= b[0] && lng <= b[2] && lat >= b[1] && lat <= b[3];
}

function bboxOf(rows) {
  if (!rows.length) return null;
  let w = Infinity, s = Infinity, e = -Infinity, n = -Infinity;
  for (const r of rows) {
    w = Math.min(w, r.lng); e = Math.max(e, r.lng);
    s = Math.min(s, r.lat); n = Math.max(n, r.lat);
  }
  if (w === e && s === n) return bboxAround(s, w, 0.4);
  return [w, s, e, n];
}

/**
 * Resolve where to look. Priority: a named place (geocoded, never invented),
 * the user's position (2 km), the viewport, the city. The result says which.
 */
async function resolveScope(plan, ctx = {}, deps = {}) {
  const want = plan.slots?.scope || null;
  const user =
    Number.isFinite(Number(ctx.userLat)) && Number.isFinite(Number(ctx.userLng))
      ? { lat: Number(ctx.userLat), lng: Number(ctx.userLng) }
      : null;
  const viewport = parseBboxCsv(ctx.bbox);

  if (want === 'place' && plan.slots.placeText) {
    const geocode = deps.geocodePlace || geocodePlace;
    const hit = await geocode(plan.slots.placeText, { fetch: deps.fetch });
    if (hit && hit.ok && hit.bbox) {
      const b = parseBboxCsv(hit.bbox) || hit.bbox;
      return { kind: 'place', bbox: b, label: hit.label || plan.slots.placeText, placeText: plan.slots.placeText };
    }
    return { kind: 'place_not_found', bbox: null, label: plan.slots.placeText, placeText: plan.slots.placeText };
  }
  if (want === 'city') return { kind: 'city', bbox: null, label: null };
  if (want === 'viewport' && viewport) return { kind: 'viewport', bbox: viewport, label: null };
  if ((want === 'near' || want == null) && user) {
    return { kind: 'near', bbox: bboxAround(user.lat, user.lng, DEFAULT_NEAR_KM), center: user, radiusKm: DEFAULT_NEAR_KM, label: null };
  }
  if (want === 'near' && !user && viewport) return { kind: 'viewport', bbox: viewport, label: null, wantedUser: true };
  if (viewport && Number(ctx.zoom) >= 11) return { kind: 'viewport', bbox: viewport, label: null };
  return { kind: 'city', bbox: null, label: null };
}

function featureToRow(f, index, center) {
  const p = f.properties || {};
  const [lng, lat] = f.geometry.coordinates;
  const row = {
    id: `r${index + 1}`,
    place_id: String(p.place_id),
    name: p.name || null,
    name_en: p.name_en || null,
    product_name: p.product_name || null,
    gap: p.gap,
    pct: p.pct,
    tier: p.tier,
    cheapest_provider_id: p.cheapest_provider_id || null,
    cheapest_price: p.cheapest_price,
    expensive_provider_id: p.expensive_provider_id || null,
    expensive_price: p.expensive_price,
    provider_count: p.provider_count,
    comparisons: p.comparisons || 0,
    wins: p.wins || null,
    lat,
    lng,
  };
  if (center) row.distance_m = Math.round(haversineKm(center.lat, center.lng, lat, lng) * 1000);
  return row;
}

/**
 * @param {{ city?: string, scope: object, terms?: string[], q?: string, minGap?: number|null, sort?: 'gap'|'cheap'|'near', limit?: number, excludePlaceId?: string }} args
 */
async function findOpportunities(args, deps = {}) {
  const city = await getCityOpportunities({ city: args.city || 'riyadh', __query: deps.__query });
  if (!city) return { rows: [], total: 0, generated_at: null, reason: 'unknown_city' };
  const scope = args.scope || { kind: 'city', bbox: null };
  const needles = []
    .concat(args.terms || [])
    .concat(args.q ? [normalizeArabic(args.q)] : [])
    .map((t) => normalizeArabic(t))
    .filter((t) => t.length >= 2);
  const minGap = Number.isFinite(Number(args.minGap)) ? Number(args.minGap) : null;
  const center = scope.center || null;
  const matches = [];
  for (const f of city.body.features) {
    const p = f.properties || {};
    if (!p.has_difference) continue;
    const [lng, lat] = f.geometry.coordinates;
    if (scope.bbox && !inBbox(lng, lat, scope.bbox)) continue;
    if (center && scope.radiusKm && haversineKm(center.lat, center.lng, lat, lng) > scope.radiusKm) continue;
    if (minGap != null && Number(p.gap) < minGap) continue;
    if (args.excludePlaceId && String(p.place_id) === String(args.excludePlaceId)) continue;
    if (needles.length) {
      const hay = normalizeArabic(`${p.name || ''} ${p.name_en || ''} ${p.product_name || ''}`);
      if (!needles.some((t) => hay.includes(t))) continue;
    }
    matches.push(f);
  }
  const rows = matches.map((f, i) => featureToRow(f, i, center));
  const sort = args.sort || 'gap';
  rows.sort((a, b) => {
    if (sort === 'cheap') {
      const ac = a.cheapest_price ?? Infinity;
      const bc = b.cheapest_price ?? Infinity;
      if (ac !== bc) return ac - bc;
    } else if (sort === 'near' && a.distance_m != null && b.distance_m != null) {
      if (a.distance_m !== b.distance_m) return a.distance_m - b.distance_m;
    }
    return (b.gap || 0) - (a.gap || 0) || a.place_id.localeCompare(b.place_id);
  });
  const limit = Math.min(MAX_ROWS, Math.max(1, Number(args.limit) || MAX_ROWS));
  const top = rows.slice(0, limit).map((r, i) => ({ ...r, id: `r${i + 1}` }));
  return { rows: top, total: rows.length, generated_at: city.body.generated_at, reason: null };
}

/** How often each app was cheapest across the compared items of the places in scope. */
async function compareApps(args, deps = {}) {
  const city = await getCityOpportunities({ city: args.city || 'riyadh', __query: deps.__query });
  if (!city) return { ranked: [], comparisons: 0, verdict: null };
  const scope = args.scope || { kind: 'city', bbox: null };
  const center = scope.center || null;
  const wins = new Map();
  let comparisons = 0;
  let places = 0;
  for (const f of city.body.features) {
    const p = f.properties || {};
    const [lng, lat] = f.geometry.coordinates;
    if (scope.bbox && !inBbox(lng, lat, scope.bbox)) continue;
    if (center && scope.radiusKm && haversineKm(center.lat, center.lng, lat, lng) > scope.radiusKm) continue;
    if (!p.wins) continue;
    places += 1;
    for (const [provider, n] of Object.entries(p.wins)) {
      const v = Number(n);
      if (!Number.isFinite(v) || v <= 0) continue;
      wins.set(provider, (wins.get(provider) || 0) + v);
      comparisons += v;
    }
  }
  const ranked = [...wins.entries()]
    .map(([provider, n]) => ({ provider, wins: n, share: comparisons ? Math.round((n / comparisons) * 100) : 0 }))
    .sort((a, b) => b.wins - a.wins || a.provider.localeCompare(b.provider));
  const verdict = comparisons >= MIN_APP_VERDICT_COMPARISONS && ranked.length ? ranked[0] : null;
  return { ranked, comparisons, places, verdict, min_comparisons: MIN_APP_VERDICT_COMPARISONS, generated_at: city.body.generated_at };
}

async function getPlaceRow(placeId, deps = {}, city = 'riyadh') {
  const body = await getCityOpportunities({ city, include: 'all', __query: deps.__query });
  if (!body) return null;
  const f = body.body.features.find((x) => String(x.properties.place_id) === String(placeId));
  return f ? featureToRow(f, 0, null) : null;
}

async function nearestComparable(placeId, deps = {}, city = 'riyadh') {
  const me = await getPlaceRow(placeId, deps, city);
  if (!me) return { me: null, other: null };
  const body = await getCityOpportunities({ city, __query: deps.__query });
  let best = null;
  let bestKm = Infinity;
  for (const f of body.body.features) {
    const p = f.properties || {};
    if (String(p.place_id) === String(placeId) || !p.has_difference) continue;
    const [lng, lat] = f.geometry.coordinates;
    const km = haversineKm(me.lat, me.lng, lat, lng);
    if (km < bestKm) {
      bestKm = km;
      best = f;
    }
  }
  const other = best ? featureToRow(best, 1, { lat: me.lat, lng: me.lng }) : null;
  return { me: { ...me, id: 'r1' }, other: other ? { ...other, id: 'r2' } : null };
}

module.exports = {
  DEFAULT_NEAR_KM,
  MAX_ROWS,
  MIN_APP_VERDICT_COMPARISONS,
  bboxAround,
  bboxOf,
  compareApps,
  findOpportunities,
  getPlaceRow,
  haversineKm,
  nearestComparable,
  parseBboxCsv,
  resolveScope,
};
