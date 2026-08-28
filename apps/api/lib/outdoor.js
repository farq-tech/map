'use strict';

/**
 * سَرى البارق read model — OSM features only, ODbL.
 * Never invents a coordinate, name, or accessibility claim.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const KSA = { lngMin: 34, lngMax: 56, latMin: 16, latMax: 33 };
const DATA_DIR = path.join(__dirname, '../data/outdoor');
const AROUND_DEFAULT_M = 15_000;
const FEATURE_CAP = 400;

const NATURE_LEXICON = [
  { kind: 'rawdah', re: /روضة|روضات|rawdah|rawdat/i },
  { kind: 'fayad', re: /فيضة|فياض|fayad|faydah/i },
  { kind: 'shaib', re: /شعيب|شعاب|shaib|sha'ib/i },
  { kind: 'wadi', re: /وادي|وديان|wadi/i },
  { kind: 'nafud', re: /نفود|نفوذ|nafud/i },
  { kind: 'dune', re: /كثيب|كثبان|طعوس|dune/i },
  { kind: 'mountain', re: /جبل|جبال|jabal|jebel/i },
  { kind: 'sabkha', re: /سبخة|سبخات|sabkha/i },
  { kind: 'coast', re: /ساحل|شاطئ|coast|beach/i },
];

function validCoord(lng, lat) {
  return (
    Number.isFinite(lng) &&
    Number.isFinite(lat) &&
    lng >= KSA.lngMin &&
    lng <= KSA.lngMax &&
    lat >= KSA.latMin &&
    lat <= KSA.latMax
  );
}

function kindFromName(name) {
  const n = String(name || '').trim();
  if (!n) return null;
  for (const row of NATURE_LEXICON) {
    if (row.re.test(n)) return row.kind;
  }
  return null;
}

function groupOf(kind) {
  if (['camp', 'picnic', 'well', 'spring', 'landmark'].includes(kind)) return 'place';
  if (['public_track', 'osm_track', 'observed_track', 'personal_track'].includes(kind)) {
    return 'movement';
  }
  return 'nature';
}

function firstCoord(geom) {
  if (!geom) return null;
  if (geom.type === 'Point') return geom.coordinates;
  if (geom.type === 'LineString') return geom.coordinates[0];
  if (geom.type === 'MultiLineString') return geom.coordinates[0] && geom.coordinates[0][0];
  if (geom.type === 'MultiPolygon') {
    return geom.coordinates[0] && geom.coordinates[0][0] && geom.coordinates[0][0][0];
  }
  return null;
}

function haversineMeters(a, b) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

function loadFc(file, layer, classify) {
  const full = path.join(DATA_DIR, file);
  if (!fs.existsSync(full)) return [];
  const raw = JSON.parse(fs.readFileSync(full, 'utf8'));
  const out = [];
  for (const f of raw.features || []) {
    const coords = firstCoord(f.geometry);
    if (!coords || coords.length < 2) continue;
    const [lng, lat] = coords;
    if (!validCoord(lng, lat)) continue;
    const props = f.properties || {};
    const name = String(props.name || '').trim() || null;
    const classified = classify(props, name);
    if (!classified) continue;
    const osmId = String(props.osm_id || '');
    const id = osmId ? `${layer}:${osmId}` : `${layer}:${lng.toFixed(5)},${lat.toFixed(5)}`;
    out.push({
      type: 'Feature',
      id,
      geometry: f.geometry,
      properties: {
        id,
        kind: classified.kind,
        group: groupOf(classified.kind),
        name,
        source: 'osm',
        evidence: classified.evidence || 'public',
        license: 'ODbL',
        fclass: props.fclass || null,
        lng,
        lat,
      },
    });
  }
  return out;
}

function classifyLayer(layer) {
  return (props, name) => {
    if (layer === 'wells') return { kind: 'well', evidence: 'public' };
    if (layer === 'springs') return { kind: 'spring', evidence: 'public' };
    if (layer === 'camps') return { kind: 'camp', evidence: 'public' };
    if (layer === 'tracks') return { kind: 'osm_track', evidence: 'public' };
    if (layer === 'wadis') {
      const fromName = kindFromName(name);
      return { kind: fromName === 'shaib' ? 'shaib' : 'wadi', evidence: name ? 'public' : 'unconfirmed' };
    }
    const nature = kindFromName(name);
    if (nature) return { kind: nature, evidence: 'public' };
    if (props.fclass === 'national_park' || /منتزه|picnic/i.test(name || '')) {
      return { kind: 'picnic', evidence: 'public' };
    }
    return { kind: 'landmark', evidence: name ? 'public' : 'unconfirmed' };
  };
}

let INDEX = null;

function loadIndex() {
  if (INDEX) return INDEX;
  INDEX = [
    ...loadFc('wells.geojson', 'wells', classifyLayer('wells')),
    ...loadFc('springs.geojson', 'springs', classifyLayer('springs')),
    ...loadFc('camps.geojson', 'camps', classifyLayer('camps')),
    ...loadFc('nature-places.geojson', 'places', classifyLayer('places')),
    ...loadFc('tracks-named.geojson', 'tracks', classifyLayer('tracks')),
    ...loadFc('wadis.geojson', 'wadis', classifyLayer('wadis')),
  ];
  return INDEX;
}

function parseBbox(raw) {
  const parts = String(raw || '')
    .split(',')
    .map(Number);
  if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) return null;
  let [west, south, east, north] = parts;
  if (east <= west || north <= south) return null;
  west = Math.max(west, KSA.lngMin);
  east = Math.min(east, KSA.lngMax);
  south = Math.max(south, KSA.latMin);
  north = Math.min(north, KSA.latMax);
  if (east <= west || north <= south) return null;
  return { west, south, east, north };
}

function inBbox(lng, lat, b) {
  return lng >= b.west && lng <= b.east && lat >= b.south && lat <= b.north;
}

function parseTypes(raw) {
  if (!raw) return null;
  const set = new Set(
    String(raw)
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
  );
  return set.size ? set : null;
}

function etagFor(payload) {
  return `"${crypto.createHash('sha1').update(payload).digest('hex').slice(0, 16)}"`;
}

function queryFeatures({ bbox, types, zoom, limit }) {
  const index = loadIndex();
  const box = parseBbox(bbox);
  const typeSet = parseTypes(types);
  const z = Number(zoom);
  const cap = Math.min(FEATURE_CAP, Math.max(20, Number(limit) || FEATURE_CAP));
  const includeWadis = !Number.isFinite(z) || z >= 9;
  const includeTracks = !Number.isFinite(z) || z >= 8;
  const hits = [];
  for (const f of index) {
    const p = f.properties;
    if (p.kind === 'wadi' || p.kind === 'shaib') {
      if (f.geometry.type !== 'Point' && !includeWadis) continue;
    }
    if (p.group === 'movement' && !includeTracks) continue;
    if (typeSet && !typeSet.has(p.kind) && !typeSet.has(p.group)) continue;
    if (box && !inBbox(p.lng, p.lat, box)) continue;
    hits.push(f);
    if (hits.length >= cap) break;
  }
  return {
    type: 'FeatureCollection',
    count: hits.length,
    source: 'osm',
    license: 'ODbL',
    features: hits,
  };
}

function queryAround({ lng, lat, radius }) {
  if (!validCoord(lng, lat)) return { error: 'invalid_origin' };
  const r = Number.isFinite(radius) ? Math.min(80_000, Math.max(500, radius)) : AROUND_DEFAULT_M;
  const origin = { lng, lat };
  const nearby = [];
  for (const f of loadIndex()) {
    const p = f.properties;
    const d = haversineMeters(origin, { lng: p.lng, lat: p.lat });
    if (d <= r) nearby.push({ ...f, properties: { ...p, distance_m: Math.round(d) } });
  }
  const nearest = (pred) => {
    const hits = nearby.filter((f) => pred(f.properties)).sort((a, b) => a.properties.distance_m - b.properties.distance_m);
    return hits[0] || null;
  };
  const tracks = nearby.filter((f) => f.properties.group === 'movement').length;
  const places = nearby.filter((f) => f.properties.group !== 'movement').length;
  return {
    origin: { lng, lat },
    radius_m: r,
    source: 'osm',
    license: 'ODbL',
    summary: {
      tracks,
      places,
      nearest_well: nearest((p) => p.kind === 'well'),
      nearest_rawdah: nearest((p) => p.kind === 'rawdah' || p.kind === 'fayad'),
      nearest_shaib: nearest((p) => p.kind === 'shaib' || p.kind === 'wadi'),
    },
    features: nearby
      .sort((a, b) => a.properties.distance_m - b.properties.distance_m)
      .slice(0, 80),
  };
}

function normalizeAr(s) {
  return String(s || '')
    .toLowerCase()
    .replace(/[أإآ]/g, 'ا')
    .replace(/ة/g, 'ه')
    .replace(/ى/g, 'ي')
    .replace(/[ًٌٍَُِّْ]/g, '')
    .trim();
}

function searchFeatures(q, limit = 20) {
  const needle = normalizeAr(q);
  if (needle.length < 2) return { type: 'FeatureCollection', count: 0, features: [], note: 'short_query' };
  const cap = Math.min(40, Math.max(1, Number(limit) || 20));
  const hits = [];
  for (const f of loadIndex()) {
    const name = normalizeAr(f.properties.name);
    if (!name || !name.includes(needle)) continue;
    hits.push(f);
    if (hits.length >= cap) break;
  }
  return {
    type: 'FeatureCollection',
    count: hits.length,
    source: 'osm',
    license: 'ODbL',
    features: hits,
  };
}

function getFeature(id) {
  if (!id) return null;
  return loadIndex().find((f) => f.properties.id === id || f.id === id) || null;
}

function stats() {
  const index = loadIndex();
  const byKind = {};
  for (const f of index) {
    const k = f.properties.kind;
    byKind[k] = (byKind[k] || 0) + 1;
  }
  return { count: index.length, byKind, source: 'osm', license: 'ODbL' };
}

module.exports = {
  KSA,
  validCoord,
  kindFromName,
  parseBbox,
  queryFeatures,
  queryAround,
  searchFeatures,
  getFeature,
  stats,
  etagFor,
  loadIndex,
  __reset() {
    INDEX = null;
  },
};
