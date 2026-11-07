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
  TILE, KSA, lngToX, latToY, xToLng, yToLat, tileBbox3857, tilesFor, tileBox, intersects, parseBbox, parseNear, haversineKm,
};
