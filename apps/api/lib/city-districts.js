'use strict';

/**
 * Districts (أحياء) — the geography people actually think in.
 *
 * Polygons come from apps/api/data/districts/<city>.geojson (MOMRAH boundaries,
 * see the README there). This module answers two questions and nothing else:
 *
 *   which حي is this coordinate in?      districtOfPoint(city, lng, lat)
 *   which حي did the person name?        findDistrictByName(city, text)
 *
 * Membership is geometric, never by name: a point belongs to a حي because it
 * is inside that حي's ring — ray casting, holes cut back out, bounds checked
 * first so a miss costs four comparisons. A point inside no polygon belongs
 * nowhere, because a wrong حي is worse than an uncounted one.
 *
 * No boundary is ever invented: an unknown city or a missing file is null.
 */

const fs = require('fs');
const path = require('path');

const DATA_DIR = path.join(__dirname, '..', 'data', 'districts');

const cache = new Map(); // city -> loaded | null

function ringBbox(ring) {
  let w = Infinity, s = Infinity, e = -Infinity, n = -Infinity;
  for (const [x, y] of ring) {
    if (x < w) w = x;
    if (x > e) e = x;
    if (y < s) s = y;
    if (y > n) n = y;
  }
  return [w, s, e, n];
}

function inBbox(lng, lat, b) {
  return lng >= b[0] && lng <= b[2] && lat >= b[1] && lat <= b[3];
}

/** Even–odd ray casting against one ring. */
function pointInRing(lng, lat, ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    if (yi > lat !== yj > lat && lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/** Inside the outer ring and inside none of the holes. */
function pointInPolygonRings(lng, lat, rings) {
  if (!rings.length || !pointInRing(lng, lat, rings[0])) return false;
  for (let i = 1; i < rings.length; i += 1) {
    if (pointInRing(lng, lat, rings[i])) return false;
  }
  return true;
}

function polygonsOf(geometry) {
  if (!geometry) return [];
  if (geometry.type === 'Polygon') return [geometry.coordinates];
  if (geometry.type === 'MultiPolygon') return geometry.coordinates;
  return [];
}

function normalizeKey(raw) {
  return String(raw || '').trim().toLowerCase();
}

/** Digits, hamza, taa marbuta, alef maqsura, diacritics, tatweel, punctuation, case. */
function normName(raw) {
  return String(raw || '')
    .replace(/[٠-٩]/g, (d) => String('٠١٢٣٤٥٦٧٨٩'.indexOf(d)))
    .replace(/[ً-ْـ]/g, '')
    .replace(/[أإآ]/g, 'ا')
    .replace(/ة/g, 'ه')
    .replace(/ى/g, 'ي')
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

/** "حي النرجس" → "النرجس"; "al narjas" → "narjas"; "النرجس" → "نرجس" too, as a second key. */
function nameKeys(name) {
  const n = normName(name);
  if (!n) return [];
  const keys = new Set([n]);
  const noHay = n.replace(/^حي\s+/, '');
  keys.add(noHay);
  if (/^ال/.test(noHay)) keys.add(noHay.slice(2));
  const noAl = noHay.replace(/^al[\s-]?/, '');
  keys.add(noAl);
  return [...keys].filter((k) => k.length >= 2);
}

/** A point inside one polygon: its bbox centre when that is inside, else the first hit of a coarse scan. */
function insidePoint(poly) {
  const [w, s, e, n] = poly.bbox;
  const cx = (w + e) / 2;
  const cy = (s + n) / 2;
  if (pointInPolygonRings(cx, cy, poly.rings)) return [cx, cy];
  const steps = 12;
  for (let i = 1; i < steps; i += 1) {
    for (let j = 1; j < steps; j += 1) {
      const x = w + ((e - w) * i) / steps;
      const y = s + ((n - s) * j) / steps;
      if (pointInPolygonRings(x, y, poly.rings)) return [x, y];
    }
  }
  return null;
}

function prepare(feature) {
  const p = feature.properties || {};
  const id = String(p.district_id || feature.id || '').trim();
  const polys = polygonsOf(feature.geometry)
    .filter((rings) => Array.isArray(rings) && rings.length && rings[0].length >= 4)
    .map((rings) => ({ bbox: ringBbox(rings[0]), rings }));
  if (!id || !polys.length) return null;
  let w = Infinity, s = Infinity, e = -Infinity, n = -Infinity;
  for (const poly of polys) {
    w = Math.min(w, poly.bbox[0]); s = Math.min(s, poly.bbox[1]);
    e = Math.max(e, poly.bbox[2]); n = Math.max(n, poly.bbox[3]);
  }
  /* One label per حي, in its largest part — a multi-part district must not speak three times. */
  const largest = polys.reduce((a, b) =>
    (b.bbox[2] - b.bbox[0]) * (b.bbox[3] - b.bbox[1]) > (a.bbox[2] - a.bbox[0]) * (a.bbox[3] - a.bbox[1]) ? b : a,
  );
  const labelPoint = insidePoint(largest);
  return {
    id,
    name_ar: String(p.name_ar || '').trim(),
    name_en: String(p.name_en || '').trim(),
    bbox: [w, s, e, n],
    label_point: labelPoint ? [Math.round(labelPoint[0] * 1e5) / 1e5, Math.round(labelPoint[1] * 1e5) / 1e5] : null,
    polys,
    feature,
  };
}

/**
 * @returns {{ city: string, count: number, features: object[], byId: Map, prepared: object[], source: string|null } | null}
 */
function loadDistricts(cityRaw, opts = {}) {
  const city = normalizeKey(cityRaw);
  if (!city) return null;
  if (!opts.__fixture && cache.has(city)) return cache.get(city);
  let fc = opts.__fixture || null;
  if (!fc) {
    const file = path.join(DATA_DIR, `${city}.geojson`);
    try {
      fc = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      cache.set(city, null);
      return null;
    }
  }
  const prepared = [];
  const byId = new Map();
  for (const f of Array.isArray(fc.features) ? fc.features : []) {
    const d = prepare(f);
    if (!d || !d.name_ar || !d.name_en || byId.has(d.id)) continue;
    prepared.push(d);
    byId.set(d.id, d);
  }
  const loaded = {
    city,
    count: prepared.length,
    features: prepared.map((d) => d.feature),
    byId,
    prepared,
    source: fc.source ? String(fc.source) : null,
  };
  if (!opts.__fixture) cache.set(city, loaded);
  return loaded;
}

function districtCities() {
  try {
    return fs
      .readdirSync(DATA_DIR)
      .filter((f) => f.endsWith('.geojson'))
      .map((f) => f.replace(/\.geojson$/, ''))
      .sort();
  } catch {
    return [];
  }
}

/** The حي whose ring contains the point, or null. Deterministic: file order wins a tie. */
function districtOfPoint(cityRaw, lng, lat, opts = {}) {
  const loaded = opts.__loaded || loadDistricts(cityRaw, opts);
  if (!loaded) return null;
  const x = Number(lng);
  const y = Number(lat);
  if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
  for (const d of loaded.prepared) {
    if (!inBbox(x, y, d.bbox)) continue;
    for (const poly of d.polys) {
      if (inBbox(x, y, poly.bbox) && pointInPolygonRings(x, y, poly.rings)) return d.id;
    }
  }
  return null;
}

function districtBbox(cityRaw, id, opts = {}) {
  const loaded = opts.__loaded || loadDistricts(cityRaw, opts);
  const d = loaded && loaded.byId.get(String(id));
  return d ? d.bbox.slice() : null;
}

/**
 * Resolve a typed or spoken name to one حي. Exact match on any normalised
 * key first (with/without "حي", "ال", "Al"); otherwise a prefix match, but
 * only when it is unique. Ambiguity returns null — the caller asks, not guesses.
 */
function findDistrictByName(cityRaw, text, opts = {}) {
  const loaded = opts.__loaded || loadDistricts(cityRaw, opts);
  if (!loaded) return null;
  const queries = nameKeys(text);
  if (!queries.length) return null;
  const toHit = (d) => ({
    district_id: d.id,
    name_ar: d.name_ar,
    name_en: d.name_en,
    bbox: d.bbox.slice(),
    feature: d.feature,
  });
  for (const d of loaded.prepared) {
    const keys = new Set([...nameKeys(d.name_ar), ...nameKeys(d.name_en)]);
    if (queries.some((q) => keys.has(q))) return toHit(d);
  }
  const longest = queries.reduce((a, b) => (b.length > a.length ? b : a), '');
  if (longest.length < 3) return null;
  const prefix = loaded.prepared.filter((d) =>
    [...nameKeys(d.name_ar), ...nameKeys(d.name_en)].some((k) => k.startsWith(longest)),
  );
  return prefix.length === 1 ? toHit(prefix[0]) : null;
}

/** A point guaranteed inside the حي (its label point) — for tests and callers that need one. */
function interiorPoint(cityRaw, id, opts = {}) {
  const loaded = opts.__loaded || loadDistricts(cityRaw, opts);
  const d = loaded && loaded.byId.get(String(id));
  if (!d) return null;
  if (d.label_point) return d.label_point.slice();
  for (const poly of d.polys) {
    const pt = insidePoint(poly);
    if (pt) return pt;
  }
  return null;
}

function __resetDistrictCacheForTests() {
  cache.clear();
}

module.exports = {
  DATA_DIR,
  districtBbox,
  districtCities,
  districtOfPoint,
  findDistrictByName,
  interiorPoint,
  loadDistricts,
  nameKeys,
  normName,
  pointInPolygonRings,
  __resetDistrictCacheForTests,
};
