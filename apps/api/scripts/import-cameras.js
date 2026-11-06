'use strict';

/*
 * Import «كاميرات الرصد» from a GeoJSON FeatureCollection into sary.speed_cameras.
 *
 *   node apps/api/scripts/import-cameras.js [path/to/cameras.geojson]
 *
 * The path comes from the argument, else CAMERAS_GEOJSON_PATH, else
 * ~/code/map-wt/cameras/cameras.geojson (where the research agent writes it).
 * Idempotent: upsert on (source, source_id), so re-running never duplicates and
 * never touches user-reported cameras. Each feature:
 *   geometry.coordinates = [lon, lat]
 *   properties: { source, source_id|id, kind|camera_type|type, speed_limit|maxspeed,
 *                 bearing|direction, confidence? }
 */

const path = require('path');
const fs = require('fs');
const os = require('os');
require('dotenv').config({ path: path.join(__dirname, '../.env') });
require('dotenv').config({ path: path.join(__dirname, '../../../.env') });
require('dotenv').config({ path: path.join(__dirname, '../../../.env.local') });

const { getOutingsPool, migrate } = require('../lib/outings/db');
const { createCameras } = require('../lib/cameras');

function resolvePath() {
  const fromArg = process.argv[2];
  const fromEnv = process.env.CAMERAS_GEOJSON_PATH;
  const fallback = path.join(os.homedir(), 'code', 'map-wt', 'cameras', 'cameras.geojson');
  return fromArg || fromEnv || fallback;
}

(async () => {
  const file = resolvePath();
  if (!fs.existsSync(file)) {
    console.error(`cameras geojson not found: ${file}`);
    console.error('Pass a path, or set CAMERAS_GEOJSON_PATH. The research agent writes it to ~/code/map-wt/cameras/cameras.geojson.');
    process.exit(2);
  }
  const pool = getOutingsPool();
  if (!pool) {
    console.error('No database URL: set SARY_DATABASE_URL (or DATABASE_URL).');
    process.exit(2);
  }
  try {
    /* Additive, idempotent — safe to run on a database that already has the tables. */
    await migrate(pool);
    const cameras = createCameras({ pool });
    const geojson = JSON.parse(fs.readFileSync(file, 'utf8'));
    const { upserted, skipped } = await cameras.importGeoJSON(geojson);
    console.log(`imported ${upserted} camera(s) from ${path.basename(file)} (${skipped} skipped)`);
  } catch (err) {
    console.error('import failed:', err.message);
    process.exitCode = 1;
  } finally {
    await pool.end();
  }
})();
