'use strict';

const { validCoord, bboxAroundPoint } = require('./comparison-map');

const MAPBOX_GEOCODE = 'https://api.mapbox.com/geocoding/v5/mapbox.places';
const MAPBOX_SUGGEST = 'https://api.mapbox.com/search/searchbox/v1/suggest';
const MAPBOX_RETRIEVE = 'https://api.mapbox.com/search/searchbox/v1/retrieve';
const NOMINATIM_SEARCH = 'https://nominatim.openstreetmap.org/search';

function mapboxToken() {
  return String(
    process.env.MAPBOX_ACCESS_TOKEN || process.env.VITE_MAPBOX_ACCESS_TOKEN || '',
  ).trim();
}

function geocodeConfigured() {
  return Boolean(mapboxToken());
}

function clipFeatureBbox(raw) {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const nums = raw.map((n) => Number(n));
  if (nums.some((n) => !Number.isFinite(n))) return null;
  let [west, south, east, north] = nums;
  if (west > east) [west, east] = [east, west];
  if (south > north) [south, north] = [north, south];
  if (east === west || north === south) return null;
  return { west, south, east, north };
}

function nameIncludesQuery(name, query) {
  const n = String(name || '').toLowerCase();
  const q = String(query || '').toLowerCase();
  return Boolean(n && q && n.includes(q));
}

async function readJson(fetchFn, url, headers) {
  const res = await fetchFn(url, headers ? { headers } : undefined);
  const payload = await res.json().catch(() => null);
  if (!res.ok) return null;
  return payload;
}

function resultFromCenter(lng, lat, label, query, bboxRaw) {
  if (!validCoord(lng, lat)) return null;
  const bbox = clipFeatureBbox(bboxRaw) || bboxAroundPoint(lng, lat, 0.018);
  if (!bbox) return null;
  return {
    ok: true,
    reason: null,
    bbox,
    center: { lng, lat },
    label: String(label || query).trim() || query,
    query,
  };
}

async function geocodeMapboxPlaces(query, opts, fetchFn) {
  const token = mapboxToken();
  if (!token) return null;
  const language = opts.language === 'en' ? 'en' : 'ar';
  const params = new URLSearchParams({
    access_token: token,
    country: 'SA',
    language,
    proximity: '46.6753,24.7136',
    types: 'neighborhood,locality,place,district,address,poi',
    limit: '3',
  });
  const payload = await readJson(
    fetchFn,
    `${MAPBOX_GEOCODE}/${encodeURIComponent(query)}.json?${params}`,
  );
  const feats = payload && Array.isArray(payload.features) ? payload.features : [];
  const feat =
    feats.find((f) => nameIncludesQuery(f.text || f.place_name, query)) || feats[0];
  if (!feat) return null;
  const coords = feat.center;
  return resultFromCenter(
    Array.isArray(coords) ? Number(coords[0]) : NaN,
    Array.isArray(coords) ? Number(coords[1]) : NaN,
    feat.text || feat.place_name,
    query,
    feat.bbox,
  );
}

async function geocodeMapboxSearchBox(query, opts, fetchFn) {
  const token = mapboxToken();
  if (!token) return null;
  const language = opts.language === 'en' ? 'en' : 'ar';
  const session = `farq-chat-${Date.now()}`;
  const suggestParams = new URLSearchParams({
    q: query,
    access_token: token,
    session_token: session,
    language,
    country: 'SA',
    proximity: '46.6753,24.7136',
    limit: '5',
  });
  const suggested = await readJson(fetchFn, `${MAPBOX_SUGGEST}?${suggestParams}`);
  const suggestions =
    suggested && Array.isArray(suggested.suggestions) ? suggested.suggestions : [];
  const pick =
    suggestions.find((s) => nameIncludesQuery(s.name || s.full_address, query)) ||
    suggestions[0];
  if (!pick || !pick.mapbox_id) return null;
  const retrieveParams = new URLSearchParams({
    access_token: token,
    session_token: session,
  });
  const retrieved = await readJson(
    fetchFn,
    `${MAPBOX_RETRIEVE}/${encodeURIComponent(pick.mapbox_id)}?${retrieveParams}`,
  );
  const feat =
    retrieved && Array.isArray(retrieved.features) ? retrieved.features[0] : null;
  if (!feat) return null;
  const coords =
    (feat.geometry && feat.geometry.coordinates) ||
    (feat.properties &&
      feat.properties.coordinates && [
        feat.properties.coordinates.longitude,
        feat.properties.coordinates.latitude,
      ]);
  const lng = Array.isArray(coords) ? Number(coords[0]) : NaN;
  const lat = Array.isArray(coords) ? Number(coords[1]) : NaN;
  return resultFromCenter(
    lng,
    lat,
    (feat.properties && feat.properties.name) || pick.name,
    query,
    feat.bbox,
  );
}

async function geocodeNominatim(query, opts, fetchFn) {
  const language = opts.language === 'en' ? 'en' : 'ar';
  const params = new URLSearchParams({
    q: `${query} الرياض`,
    format: 'json',
    limit: '3',
    countrycodes: 'sa',
    'accept-language': language,
  });
  const payload = await readJson(fetchFn, `${NOMINATIM_SEARCH}?${params}`, {
    Accept: 'application/json',
    'User-Agent': 'FarqMap/1.0 (+https://farq-map-investor.vercel.app)',
  });
  const rows = Array.isArray(payload) ? payload : [];
  const row =
    rows.find((r) => nameIncludesQuery(r.display_name, query)) || rows[0];
  if (!row) return null;
  const lat = Number(row.lat);
  const lng = Number(row.lon);
  let bboxRaw = null;
  if (Array.isArray(row.boundingbox) && row.boundingbox.length === 4) {
    const south = Number(row.boundingbox[0]);
    const north = Number(row.boundingbox[1]);
    const west = Number(row.boundingbox[2]);
    const east = Number(row.boundingbox[3]);
    bboxRaw = [west, south, east, north];
  }
  return resultFromCenter(lng, lat, row.display_name, query, bboxRaw);
}

/**
 * Forward-geocode a Saudi place via the same Mapbox search the map uses,
 * then Farq's existing Nominatim fallback. Never invents a coordinate.
 */
async function geocodePlace(query, opts = {}) {
  const q = String(query || '').trim();
  if (!q) {
    return { ok: false, reason: 'empty_query', bbox: null };
  }
  const fetchFn = opts.fetch || fetch;
  try {
    const mapboxPlace = await geocodeMapboxPlaces(q, opts, fetchFn);
    if (mapboxPlace) return mapboxPlace;
    const searchBox = await geocodeMapboxSearchBox(q, opts, fetchFn);
    if (searchBox) return searchBox;
    const nominatim = await geocodeNominatim(q, opts, fetchFn);
    if (nominatim) return nominatim;
  } catch {
    return { ok: false, reason: 'geocode_unavailable', bbox: null };
  }
  return { ok: false, reason: 'place_not_found', bbox: null };
}

module.exports = {
  geocodeConfigured,
  geocodePlace,
  mapboxToken,
};
