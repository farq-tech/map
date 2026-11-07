'use strict';

/**
 * A mosaic of 256-px Web-Mercator tiles at one zoom (`z`), holding a number per pixel, with
 * point sampling and re-rendering to any XYZ tile. The rain and greenness layers keep their
 * grids in this form (the zoom of the GIBS tiles they were read from).
 */

const { PNG } = require('pngjs');
const { TILE, lngToX, latToY, xToLng, yToLat } = require('./mercator');

class Mosaic {
  constructor(z) {
    this.z = z;
    this.tiles = new Map(); // "x/y" → Float32Array(65536)
  }
  set(x, y, arr) {
    this.tiles.set(`${x}/${y}`, arr);
  }
  get(x, y) {
    return this.tiles.get(`${x}/${y}`);
  }
  /** Value at global pixel (px, py) of zoom z, nearest. NaN when unknown. */
  pixel(px, py) {
    const tx = Math.floor(px / TILE);
    const ty = Math.floor(py / TILE);
    const arr = this.get(tx, ty);
    if (!arr) return NaN;
    const ix = Math.min(TILE - 1, Math.max(0, Math.floor(px - tx * TILE)));
    const iy = Math.min(TILE - 1, Math.max(0, Math.floor(py - ty * TILE)));
    return arr[iy * TILE + ix];
  }
  /** Nearest value at a lon/lat. */
  at(lng, lat) {
    return this.pixel(lngToX(lng, this.z), latToY(lat, this.z));
  }
  /** Bilinear value (NaN neighbours ignored). */
  bilinear(lng, lat) {
    const fx = lngToX(lng, this.z) - 0.5;
    const fy = latToY(lat, this.z) - 0.5;
    const x0 = Math.floor(fx);
    const y0 = Math.floor(fy);
    const ax = fx - x0;
    const ay = fy - y0;
    let s = 0;
    let w = 0;
    const add = (px, py, ww) => {
      const v = this.pixel(px + 0.5, py + 0.5);
      if (Number.isFinite(v) && ww > 0) {
        s += v * ww;
        w += ww;
      }
    };
    add(x0, y0, (1 - ax) * (1 - ay));
    add(x0 + 1, y0, ax * (1 - ay));
    add(x0, y0 + 1, (1 - ax) * ay);
    add(x0 + 1, y0 + 1, ax * ay);
    return w > 0 ? s / w : NaN;
  }
  /** Largest value within `r` pixels (of zoom z) of a lon/lat — tolerant point reads. */
  maxAround(lng, lat, r = 1) {
    const px = lngToX(lng, this.z);
    const py = latToY(lat, this.z);
    let best = NaN;
    for (let dy = -r; dy <= r; dy++) {
      for (let dx = -r; dx <= r; dx++) {
        const v = this.pixel(px + dx, py + dy);
        if (Number.isFinite(v) && !(best >= v)) best = v;
      }
    }
    return best;
  }
}

/**
 * Renders XYZ tile (z, x, y) by sampling `valueAt(lng, lat)` per pixel and colouring with
 * `color(v)` → [r, g, b, a] or null (transparent). Returns a PNG buffer.
 */
function renderTile(z, x, y, valueAt, color) {
  const png = new PNG({ width: TILE, height: TILE });
  const d = png.data;
  for (let j = 0; j < TILE; j++) {
    const lat = yToLat(y * TILE + j + 0.5, z);
    for (let i = 0; i < TILE; i++) {
      const lng = xToLng(x * TILE + i + 0.5, z);
      const c = color(valueAt(lng, lat));
      const k = (j * TILE + i) * 4;
      if (c) {
        d[k] = c[0];
        d[k + 1] = c[1];
        d[k + 2] = c[2];
        d[k + 3] = c[3];
      }
    }
  }
  return PNG.sync.write(png, { colorType: 6 });
}

/** Colour by ascending stops `[{ min, rgba:[r,g,b,a] }]`: the last stop with v ≥ min. */
function stepColor(stops) {
  return (v) => {
    if (!Number.isFinite(v)) return null;
    let c = null;
    for (const s of stops) if (v >= s.min) c = s.rgba;
    return c;
  };
}

module.exports = { Mosaic, renderTile, stepColor };
