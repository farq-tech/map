'use strict';

/** Web-Mercator (EPSG:3857 / XYZ tiles, 256 px) helpers shared by the weather layers. */

const R = 6378137;
const ORIGIN = Math.PI * R; // 20037508.34…
const TILE = 256;

/** Saudi Arabia with a small margin (the weather layers only work inside it). */
const KSA = { west: 34, south: 16, east: 56, north: 33 };

function lngToX(lng, z) {
  return ((lng + 180) / 360) * TILE * 2 ** z;
}
function latToY(lat, z) {
  const s = Math.sin((Math.max(-85.0511, Math.min(85.0511, lat)) * Math.PI) / 180);
  return (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * TILE * 2 ** z;
}
function xToLng(x, z) {
  return (x / (TILE * 2 ** z)) * 360 - 180;
}
function yToLat(y, z) {
  const n = Math.PI - (2 * Math.PI * y) / (TILE * 2 ** z);
  return (180 / Math.PI) * Math.atan(Math.sinh(n));
}

/** The tile's bounds in EPSG:3857 metres: [minx, miny, maxx, maxy] (a WMS GetMap bbox). */
function tileBbox3857(z, x, y) {
  const size = (2 * ORIGIN) / 2 ** z;
  const minx = -ORIGIN + x * size;
  const maxy = ORIGIN - y * size;
  return [minx, maxy - size, minx + size, maxy];
}

/** Tiles of zoom z covering a lon/lat box. */
function tilesFor(box, z) {
  const x0 = Math.floor(lngToX(box.west, z) / TILE);
  const x1 = Math.floor((lngToX(box.east, z) - 1e-9) / TILE);
  const y0 = Math.floor(latToY(box.north, z) / TILE);
  const y1 = Math.floor((latToY(box.south, z) - 1e-9) / TILE);
  const out = [];
  for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) out.push({ z, x, y });
  return out;
}

/*
 * The Kingdom's outline, coarse (≈ 10–30 km): enough to keep the desert search's unnamed
 * hotspots inside the country (the bbox also covers Kuwait, southern Iraq, Qatar, the UAE…).
 * [lng, lat], coastline a little offshore.
 */
const KSA_OUTLINE = [
  [34.95, 29.36], [36.07, 29.18], [36.75, 29.87], [37.99, 30.5], [37.0, 31.5], [39.0, 32.0], [39.2, 32.15],
  [40.4, 31.95], [42.08, 31.11], [44.72, 29.18], [46.55, 29.1], [47.46, 29.0], [47.7, 28.53], [48.6, 28.4],
  [49.0, 27.9], [49.6, 27.1], [50.2, 26.6], [50.35, 25.8], [50.75, 24.75], [51.4, 24.45], [51.58, 24.25],
  [52.0, 23.0], [55.0, 22.7], [55.67, 22.0], [55.0, 20.0], [52.0, 19.0], [49.1, 18.6], [48.2, 18.17],
  [47.0, 16.95], [46.3, 17.2], [45.2, 17.43], [44.1, 17.4], [43.4, 17.53], [43.2, 16.8], [42.79, 16.38],
  [42.4, 16.4], [41.6, 17.8], [40.6, 19.3], [39.4, 20.6], [38.9, 21.7], [38.3, 23.1], [37.2, 24.4],
  [36.4, 25.7], [35.4, 27.3], [34.6, 28.1], [34.65, 29.0],
];

/** Point-in-polygon (ray casting) against the coarse outline. */
function inKsa(lng, lat) {
  let inside = false;
  const P = KSA_OUTLINE;
  for (let i = 0, j = P.length - 1; i < P.length; j = i++) {
    const [xi, yi] = P[i];
    const [xj, yj] = P[j];
    if ((yi > lat) !== (yj > lat) && lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

function intersects(a, b) {
  return a.west < b.east && a.east > b.west && a.south < b.north && a.north > b.south;
}

function tileBox(z, x, y) {
  return {
    west: xToLng(x * TILE, z),
    east: xToLng((x + 1) * TILE, z),
    north: yToLat(y * TILE, z),
    south: yToLat((y + 1) * TILE, z),
  };
}

/** `west,south,east,north` → box (clamped to KSA); null when unreadable or outside. */
function parseBbox(raw, { clampTo = KSA } = {}) {
  const p = String(raw || '').split(',').map(Number);
  if (p.length !== 4 || !p.every(Number.isFinite)) return null;
  let [west, south, east, north] = p;
  if (west > east) [west, east] = [east, west];
  if (south > north) [south, north] = [north, south];
  const box = {
    west: Math.max(west, clampTo.west),
    south: Math.max(south, clampTo.south),
    east: Math.min(east, clampTo.east),
    north: Math.min(north, clampTo.north),
  };
  if (box.west >= box.east || box.south >= box.north) return null;
  return box;
}

/** `lat,lng` → { lat, lng } inside KSA, else null. */
function parseNear(raw) {
  const p = String(raw || '').split(',').map(Number);
  if (p.length !== 2 || !p.every(Number.isFinite)) return null;
  const [lat, lng] = p;
  if (lng < KSA.west || lng > KSA.east || lat < KSA.south || lat > KSA.north) return null;
  return { lat, lng };
}

function haversineKm(a, b) {
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * 6371.0088 * Math.asin(Math.sqrt(h));
}

module.exports = {
  TILE, KSA, KSA_OUTLINE, inKsa, lngToX, latToY, xToLng, yToLat, tileBbox3857, tilesFor, tileBox, intersects, parseBbox, parseNear, haversineKm,
};
