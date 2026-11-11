'use strict';

/**
 * NASA GIBS (Global Imagery Browse Services) — keyless WMTS. NASA data carry no restriction on
 * use, including commercial; NASA asks for credit («Imagery: NASA GIBS / EOSDIS»).
 * https://www.earthdata.nasa.gov/engage/open-data-services-software-policies
 */

const { PNG } = require('pngjs');
const { fetchBuffer } = require('./fetcher');

const BASE = process.env.GIBS_WMTS_URL || 'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best';

function tileUrl(layer, time, matrixSet, z, x, y) {
  return `${BASE}/${layer}/default/${time}/${matrixSet}/${z}/${y}/${x}.png`;
}

/** DescribeDomains: `<Domain>2026-11-01/2026-11-07T05:30:00Z/PT30M,…</Domain>` → newest time (ms). */
function latestFromDomains(xml) {
  const m = /<Domain>([^<]*)<\/Domain>/.exec(String(xml || ''));
  if (!m) return null;
  let best = null;
  for (const seg of m[1].split(',')) {
    const parts = seg.trim().split('/');
    const end = parts.length >= 2 ? parts[1] : parts[0];
    const t = Date.parse(/T/.test(end) ? end : `${end}T00:00:00Z`);
    if (Number.isFinite(t) && (best == null || t > best)) best = t;
  }
  return best;
}

function ymd(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

async function latestTime(layer, matrixSet, nowMs, backDays) {
  const url = `${BASE}/1.0.0/${layer}/default/${matrixSet}/all/${ymd(nowMs - backDays * 86400_000)}--${ymd(nowMs + 86400_000)}.xml`;
  const r = await fetchBuffer(url, { timeoutMs: 20_000 });
  if (r.status !== 200) return null;
  return latestFromDomains(r.body.toString('utf8'));
}

/**
 * Fetches one palette tile and reads every pixel back through `lookup` (packed RGB → value).
 * Transparent pixels read as `transparentValue`. Returns a Float32Array(256*256), or null when
 * GIBS has no tile for that time (non-200 / not a PNG).
 */
async function valuesTile(layer, time, matrixSet, z, x, y, lookup, { transparentValue = NaN } = {}) {
  const r = await fetchBuffer(tileUrl(layer, time, matrixSet, z, x, y), { timeoutMs: 30_000 });
  if (r.status !== 200 || !/png/.test(r.type)) return null;
  return decodeValues(r.body, lookup, transparentValue);
}

function decodeValues(pngBuf, lookup, transparentValue = NaN) {
  const png = PNG.sync.read(pngBuf);
  const n = png.width * png.height;
  const out = new Float32Array(n);
  const d = png.data;
  for (let i = 0; i < n; i++) {
    const j = i * 4;
    if (d[j + 3] === 0) {
      out[i] = transparentValue;
      continue;
    }
    const v = lookup.get((d[j] << 16) | (d[j + 1] << 8) | d[j + 2]);
    out[i] = v === undefined ? NaN : v;
  }
  return out;
}

module.exports = { BASE, tileUrl, latestFromDomains, latestTime, valuesTile, decodeValues, ymd };
