'use strict';

/**
 * Builds apps/api/data/outdoor/fuel.geojson — OSM `amenity=fuel` in Saudi
 * Arabia — from an extract you already have on disk. It fetches nothing.
 *
 *   node apps/api/scripts/build-outdoor-fuel.js <input> [--out <file>]
 *
 * <input> is either
 *   · Overpass JSON (`[out:json]; area["ISO3166-1"="SA"]->.a;
 *     nwr["amenity"="fuel"](area.a); out center tags;`), or
 *   · GeoJSON from the same Geofabrik GCC shapefile the other outdoor layers
 *     came from: `ogr2ogr -f GeoJSON -where "fclass='fuel'" fuel-raw.geojson
 *     gis_osm_traffic_free_1.shp` (and the `_a_` polygons layer, merged).
 *
 * Kept: the OSM id, `name` (Arabic first when tagged), `brand`, one point
 * (a polygon's first vertex / Overpass `center`). Nothing is invented,
 * snapped or completed; features outside Saudi bounds are dropped.
 * Licence: ODbL — attribute «© OpenStreetMap contributors».
 */

const fs = require('fs');
const path = require('path');
const { validCoord } = require('../lib/outdoor');

function pointOf(geom) {
  if (!geom) return null;
  if (geom.type === 'Point') return geom.coordinates;
  if (geom.type === 'Polygon') return geom.coordinates?.[0]?.[0] || null;
  if (geom.type === 'MultiPolygon') return geom.coordinates?.[0]?.[0]?.[0] || null;
  return null;
}

const clean = (s) => {
  const t = String(s ?? '').replace(/\s+/g, ' ').trim();
  return t ? t.slice(0, 80) : null;
};

function feature(osmId, lng, lat, tags) {
  return {
    type: 'Feature',
    properties: {
      osm_id: String(osmId),
      fclass: 'fuel',
      name: clean(tags['name:ar']) || clean(tags.name),
      brand: clean(tags.brand) || clean(tags.operator),
    },
    geometry: { type: 'Point', coordinates: [Math.round(lng * 1e7) / 1e7, Math.round(lat * 1e7) / 1e7] },
  };
}

/** Overpass JSON or GeoJSON → our FeatureCollection. Pure, for tests. */
function convert(raw) {
  const out = new Map();
  if (Array.isArray(raw?.elements)) {
    for (const el of raw.elements) {
      const tags = el.tags || {};
      if (tags.amenity !== 'fuel') continue;
      const lat = el.lat ?? el.center?.lat;
      const lng = el.lon ?? el.center?.lon;
      if (!validCoord(lng, lat)) continue;
      const id = `${el.type?.[0] || 'n'}${el.id}`;
      out.set(id, feature(id, lng, lat, tags));
    }
  } else if (Array.isArray(raw?.features)) {
    for (const f of raw.features) {
      const props = f.properties || {};
      if (props.fclass && props.fclass !== 'fuel') continue;
      if (props.amenity && props.amenity !== 'fuel') continue;
      const c = pointOf(f.geometry);
      if (!c || !validCoord(c[0], c[1])) continue;
      const id = String(props.osm_id || props['@id'] || `${c[0].toFixed(5)},${c[1].toFixed(5)}`);
      out.set(id, feature(id, c[0], c[1], props));
    }
  } else {
    throw new Error('input is neither Overpass JSON nor GeoJSON');
  }
  return {
    type: 'FeatureCollection',
    name: 'fuel',
    attribution: '© OpenStreetMap contributors, ODbL',
    features: [...out.values()],
  };
}

if (require.main === module) {
  const input = process.argv[2];
  const i = process.argv.indexOf('--out');
  const outFile = i > 0 ? process.argv[i + 1] : path.join(__dirname, '../data/outdoor/fuel.geojson');
  if (!input) {
    console.error('usage: node apps/api/scripts/build-outdoor-fuel.js <overpass.json|raw.geojson> [--out file]');
    process.exit(2);
  }
  const fc = convert(JSON.parse(fs.readFileSync(input, 'utf8')));
  /* One feature per line, like the other layers: small diffs on refresh. */
  const body = `{\n"type": "FeatureCollection",\n"name": "fuel",\n"attribution": "${fc.attribution}",\n"features": [\n${fc.features.map((f) => JSON.stringify(f)).join(',\n')}\n]\n}\n`;
  fs.writeFileSync(outFile, body);
  const named = fc.features.filter((f) => f.properties.name).length;
  console.log(`wrote ${fc.features.length} fuel stations (${named} named) → ${outFile}`);
}

module.exports = { convert };
