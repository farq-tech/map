'use strict';

/**
 * GIBS colour maps → numbers. NASA GIBS serves its science layers (IMERG rain rate, VIIRS NDVI)
 * as palette PNGs and publishes the exact colour → value-range table for each
 * (https://gibs.earthdata.nasa.gov/colormaps/v1.3/<name>.xml). Reading a tile pixel back
 * through that table gives the value's bin (≈5 % wide for IMERG), so we can sum rain and
 * compare greenness without a key. The two tables we use are vendored in data/weather/.
 */

const fs = require('fs');
const path = require('path');

const DIR = path.join(__dirname, '../../data/weather');

/** Parses one GIBS colormap XML into `{ units, entries: [{ rgb:[r,g,b], lo, hi, nodata }] }`. */
function parseColormapXml(xml) {
  const units = (xml.match(/units="([^"]*)"/) || [])[1] || null;
  const entries = [];
  const re = /<ColorMapEntry\s+([^>]*?)\/>/g;
  let m;
  while ((m = re.exec(xml))) {
    const attr = {};
    for (const a of m[1].matchAll(/(\w+)="([^"]*)"/g)) attr[a[1]] = a[2];
    if (!attr.rgb) continue;
    const rgb = attr.rgb.split(',').map(Number);
    const nodata = attr.nodata === 'true' || attr.transparent === 'true';
    let lo = null;
    let hi = null;
    const v = attr.value || attr.sourceValue;
    const r = v && v.match(/^[[(]\s*([^,]+)\s*,\s*([^\])]+)\s*[\])]$/);
    if (r) {
      lo = r[1] === '-INF' ? -Infinity : Number(r[1]);
      hi = r[2] === '+INF' ? Infinity : Number(r[2]);
    } else if (v != null && v !== '' && Number.isFinite(Number(v))) {
      lo = hi = Number(v);
    }
    entries.push({ rgb, lo, hi, nodata });
  }
  return { units, entries };
}

/** A representative number for a bin: its middle; open ends use the finite edge. */
function binValue(e) {
  if (e.lo == null || e.hi == null) return NaN;
  if (!Number.isFinite(e.lo)) return e.hi;
  if (!Number.isFinite(e.hi)) return e.lo;
  return (e.lo + e.hi) / 2;
}

/**
 * A lookup from packed RGB (r<<16|g<<8|b) to the bin's value. Nodata / transparent colours map
 * to NaN; `zeroBelow` lets a transparent "below threshold" bin read as 0 instead (rain < 0.1 mm/h).
 */
function buildLookup(cm, { zeroTransparentBelow = null } = {}) {
  const map = new Map();
  for (const e of cm.entries) {
    const key = (e.rgb[0] << 16) | (e.rgb[1] << 8) | e.rgb[2];
    let val = binValue(e);
    if (e.nodata) {
      val = zeroTransparentBelow != null && e.hi != null && e.hi <= zeroTransparentBelow ? 0 : NaN;
    }
    if (!map.has(key)) map.set(key, val);
  }
  return map;
}

/** JSON has no Infinity: the vendored files spell open bin ends "-INF" / "+INF". */
function replaceInf(_k, v) {
  if (v === Infinity) return '+INF';
  if (v === -Infinity) return '-INF';
  return v;
}
function reviveInf(_k, v) {
  if (v === '+INF') return Infinity;
  if (v === '-INF') return -Infinity;
  return v;
}

const cache = {};
function load(name) {
  if (!cache[name]) cache[name] = JSON.parse(fs.readFileSync(path.join(DIR, `colormap-${name}.json`), 'utf8'), reviveInf);
  return cache[name];
}

module.exports = { parseColormapXml, buildLookup, binValue, load, replaceInf, reviveInf };
