'use strict';

/**
 * «كاميرات الرصد» (ساهر) — the data behind the map layer, the on-route voice
 * alert, and our own crowd-sourced base. Schema: migrations/018_sary_speed_cameras.sql.
 *
 * Two tables, one rule: speed_cameras is public (what the app draws and alerts
 * on); camera_reports is private (raw driver taps). A reporter's identity never
 * crosses into speed_cameras, and inBBox() — the only public read — selects no
 * identity column at all.
 *
 * Imports are idempotent: upsert on (source, source_id), so re-running the OSM
 * import never duplicates a point and never touches user-sourced cameras (which
 * carry no source_id). Reports are promoted into a user camera only when enough
 * separate reporters agree at one spot.
 *
 * Injected `q(text, params) -> rows` so tests drive it with a plain pool; pass a
 * `pool` and it wraps `pool.query`.
 */

const EARTH_M = 6371000;

/** Great-circle distance in metres. */
function haversine(aLat, aLon, bLat, bLon) {
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(bLat - aLat);
  const dLon = toRad(bLon - aLon);
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(aLat)) * Math.cos(toRad(bLat)) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_M * Math.asin(Math.min(1, Math.sqrt(s)));
}

const KINDS = new Set(['fixed', 'mobile', 'red_light', 'avg_speed']);
const SOURCES = new Set(['osm', 'official', 'user', 'other']);

/** A finite coordinate in range, or null. Keeps bad input out of SQL entirely. */
function coord(lat, lon) {
  const la = Number(lat);
  const lo = Number(lon);
  if (!Number.isFinite(la) || !Number.isFinite(lo)) return null;
  if (la < -90 || la > 90 || lo < -180 || lo > 180) return null;
  return { lat: la, lon: lo };
}

function kindOf(v, fallback = 'fixed') {
  const k = String(v || '').toLowerCase();
  return KINDS.has(k) ? k : fallback;
}

function speedLimitOf(v) {
  const n = Math.round(Number(v));
  return Number.isFinite(n) && n >= 10 && n <= 200 ? n : null;
}

function bearingOf(v) {
  if (v === null || v === undefined || v === '') return null;
  let n = Number(v);
  if (!Number.isFinite(n)) return null;
  n = ((n % 360) + 360) % 360; // normalise into [0, 360)
  return n;
}

/** Public shape — no identity, no source_id, no timestamps a tracker could use. */
function publicCamera(row) {
  return {
    id: row.id,
    lat: row.lat,
    lon: row.lon,
    bearing: row.bearing,
    kind: row.kind,
    speed_limit: row.speed_limit,
    source: row.source,
    confidence: Math.round(Number(row.confidence) * 100) / 100,
  };
}

function createCameras({
  pool,
  q,
  now = () => new Date(),
  promoteWithinM = 50,
  minReporters = 3,
  maxBBox = 2000,
} = {}) {
  const query = q || ((text, params) => pool.query(text, params).then((r) => r.rows));

  /**
   * Cameras inside a lon/lat box, newest-confidence first. Public fields only.
   * Caller passes west,south,east,north (degrees); we clamp the result count.
   */
  async function inBBox({ west, south, east, north, limit } = {}) {
    const w = Number(west);
    const s = Number(south);
    const e = Number(east);
    const n = Number(north);
    if (![w, s, e, n].every(Number.isFinite) || w > e || s > n) {
      return { ok: false, error: 'bad_bbox' };
    }
    const lim = Math.max(1, Math.min(maxBBox, Number(limit) || maxBBox));
    const rows = await query(
      `SELECT id, lat, lon, bearing, kind, speed_limit, source, confidence
         FROM sary.speed_cameras
        WHERE lon BETWEEN $1 AND $2 AND lat BETWEEN $3 AND $4
        ORDER BY confidence DESC, updated_at DESC
        LIMIT $5`,
      [w, e, s, n, lim],
    );
    return { ok: true, cameras: rows.map(publicCamera) };
  }

  /**
   * Idempotent upsert of external cameras. Each feature needs lat, lon, source,
   * source_id; a re-import updates in place on (source, source_id). User cameras
   * (no source_id) are never produced here and never overwritten.
   */
  async function importFeatures(features, { source: defSource, defaultConfidence } = {}) {
    let upserted = 0;
    let skipped = 0;
    for (const f of features || []) {
      const c = coord(f.lat, f.lon);
      const source = SOURCES.has(f.source) ? f.source : SOURCES.has(defSource) ? defSource : 'other';
      const sourceId = f.source_id != null ? String(f.source_id).slice(0, 128) : null;
      if (!c || source === 'user' || !sourceId) {
        skipped += 1; // imports must be keyable and must not masquerade as user reports
        continue;
      }
      const conf = Number.isFinite(Number(f.confidence))
        ? Math.max(0, Math.min(1, Number(f.confidence)))
        : Number.isFinite(Number(defaultConfidence))
          ? defaultConfidence
          : source === 'official' ? 0.9 : 0.6;
      await query(
        `INSERT INTO sary.speed_cameras (lat, lon, bearing, kind, speed_limit, source, source_id, confidence, updated_at)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8, now())
         ON CONFLICT (source, source_id) WHERE source_id IS NOT NULL
         DO UPDATE SET lat = EXCLUDED.lat, lon = EXCLUDED.lon, bearing = EXCLUDED.bearing,
                       kind = EXCLUDED.kind, speed_limit = EXCLUDED.speed_limit,
                       confidence = EXCLUDED.confidence, updated_at = now()`,
        [c.lat, c.lon, bearingOf(f.bearing), kindOf(f.kind), speedLimitOf(f.speed_limit), source, sourceId, conf],
      );
      upserted += 1;
    }
    return { upserted, skipped };
  }

  /** Reads a GeoJSON FeatureCollection into importFeatures(). */
  async function importGeoJSON(geojson, opts = {}) {
    const fc = typeof geojson === 'string' ? JSON.parse(geojson) : geojson;
    const feats = Array.isArray(fc?.features) ? fc.features : [];
    const mapped = feats.map((ft) => {
      const g = ft.geometry || {};
      const [lon, lat] = Array.isArray(g.coordinates) ? g.coordinates : [];
      const p = ft.properties || {};
      return {
        lat,
        lon,
        bearing: p.bearing ?? p.direction,
        kind: p.kind ?? p.camera_type ?? p.type,
        speed_limit: p.speed_limit ?? p.maxspeed,
        source: p.source,
        source_id: p.source_id ?? p.id ?? ft.id,
      };
    });
    return importFeatures(mapped, opts);
  }

  /** Pending reports near a point (small window prefilter, then precise distance). */
  async function nearbyPending(lat, lon, radiusM) {
    const dLat = radiusM / 111_320 + 1e-6;
    const dLon = radiusM / (111_320 * Math.cos((lat * Math.PI) / 180) || 1) + 1e-6;
    const rows = await query(
      `SELECT id, user_id, client_id, lat, lon, kind
         FROM sary.camera_reports
        WHERE status = 'pending'
          AND lat BETWEEN $1 AND $2 AND lon BETWEEN $3 AND $4`,
      [lat - dLat, lat + dLat, lon - dLon, lon + dLon],
    );
    return rows.filter((r) => haversine(lat, lon, r.lat, r.lon) <= radiusM);
  }

  /** The nearest existing camera within radius, or null. */
  async function nearestCamera(lat, lon, radiusM) {
    const dLat = radiusM / 111_320 + 1e-6;
    const dLon = radiusM / (111_320 * Math.cos((lat * Math.PI) / 180) || 1) + 1e-6;
    const rows = await query(
      `SELECT id, lat, lon, confidence, confirmations
         FROM sary.speed_cameras
        WHERE lat BETWEEN $1 AND $2 AND lon BETWEEN $3 AND $4`,
      [lat - dLat, lat + dLat, lon - dLon, lon + dLon],
    );
    let best = null;
    let bestD = Infinity;
    for (const r of rows) {
      const d = haversine(lat, lon, r.lat, r.lon);
      if (d <= radiusM && d < bestD) {
        best = r;
        bestD = d;
      }
    }
    return best;
  }

  /** A reporter is one identity: the signed-in user, else the device, else the row. */
  const reporterKey = (r) => r.user_id || r.client_id || `r:${r.id}`;

  /**
   * Record a «كاميرا هنا» tap, then see if it should become a camera.
   *  · lands on an existing camera (≤ radius) → attach, bump its confidence.
   *  · reaches `minReporters` distinct reporters at one spot → a new user camera.
   *  · otherwise → stays pending, waiting for others to agree.
   * A retried tap (same user+client_id) is the same report, not a new voice.
   */
  async function report({ userId = null, clientId = null, lat, lon, kind } = {}) {
    const c = coord(lat, lon);
    if (!c) return { ok: false, error: 'bad_coord' };
    const k = kindOf(kind);
    const cid = clientId && /^[A-Za-z0-9_-]{1,64}$/.test(String(clientId)) ? String(clientId) : null;

    let rows;
    if (userId && cid) {
      rows = await query(
        `INSERT INTO sary.camera_reports (user_id, client_id, lat, lon, kind)
         VALUES ($1,$2,$3,$4,$5)
         ON CONFLICT (user_id, client_id) WHERE client_id IS NOT NULL AND user_id IS NOT NULL
         DO UPDATE SET lat = EXCLUDED.lat, lon = EXCLUDED.lon, kind = EXCLUDED.kind
         RETURNING *`,
        [userId, cid, c.lat, c.lon, k],
      );
    } else {
      rows = await query(
        `INSERT INTO sary.camera_reports (user_id, client_id, lat, lon, kind)
         VALUES ($1,$2,$3,$4,$5) RETURNING *`,
        [userId, cid, c.lat, c.lon, k],
      );
    }
    const row = rows[0];

    // Already a camera here? Attach to it and raise its confidence; stay quiet.
    const near = await nearestCamera(c.lat, c.lon, promoteWithinM);
    if (near) {
      await query(
        `UPDATE sary.speed_cameras
            SET confirmations = confirmations + 1,
                confidence = LEAST(1, confidence + 0.05),
                updated_at = now()
          WHERE id = $1`,
        [near.id],
      );
      await query(`UPDATE sary.camera_reports SET status = 'duplicate', camera_id = $2 WHERE id = $1`, [row.id, near.id]);
      return { ok: true, report: { id: row.id, status: 'duplicate' }, camera_id: near.id, promoted: false };
    }

    // Enough separate reporters agree? Promote to a user camera at the centroid.
    const pending = await nearbyPending(c.lat, c.lon, promoteWithinM);
    const reporters = new Set(pending.map(reporterKey));
    if (reporters.size >= minReporters) {
      const avgLat = pending.reduce((s, r) => s + r.lat, 0) / pending.length;
      const avgLon = pending.reduce((s, r) => s + r.lon, 0) / pending.length;
      const kindCounts = pending.reduce((m, r) => ((m[r.kind] = (m[r.kind] || 0) + 1), m), {});
      const topKind = Object.entries(kindCounts).sort((a, b) => b[1] - a[1])[0]?.[0] || k;
      const created = await query(
        `INSERT INTO sary.speed_cameras (lat, lon, kind, source, confidence, confirmations, updated_at)
         VALUES ($1,$2,$3,'user',$4,$5, now()) RETURNING id`,
        [avgLat, avgLon, topKind, Math.min(1, 0.4 + 0.1 * reporters.size), reporters.size],
      );
      const cameraId = created[0].id;
      const ids = pending.map((r) => r.id);
      await query(
        `UPDATE sary.camera_reports SET status = 'promoted', camera_id = $2 WHERE id = ANY($1::uuid[])`,
        [ids, cameraId],
      );
      return { ok: true, report: { id: row.id, status: 'promoted' }, camera_id: cameraId, promoted: true };
    }

    return { ok: true, report: { id: row.id, status: 'pending' }, promoted: false };
  }

  /** Raise a camera's confidence (a driver said «نعم، موجودة»). */
  async function confirm(id) {
    const rows = await query(
      `UPDATE sary.speed_cameras
          SET confirmations = confirmations + 1,
              confidence = LEAST(1, confidence + 0.1),
              updated_at = now()
        WHERE id = $1
        RETURNING *`,
      [id],
    );
    if (!rows.length) return { ok: false, error: 'not_found' };
    return { ok: true, camera: publicCamera(rows[0]) };
  }

  /**
   * Lower a camera's confidence (a driver said «ما فيه»). A crowd-sourced camera
   * that falls to the floor is removed; an official/OSM one only loses confidence.
   */
  async function dismiss(id) {
    const rows = await query(
      `UPDATE sary.speed_cameras
          SET confidence = GREATEST(0, confidence - 0.2),
              updated_at = now()
        WHERE id = $1
        RETURNING *`,
      [id],
    );
    if (!rows.length) return { ok: false, error: 'not_found' };
    const cam = rows[0];
    if (cam.source === 'user' && cam.confidence <= 0.1) {
      await query(`DELETE FROM sary.speed_cameras WHERE id = $1`, [id]);
      return { ok: true, camera: null, removed: true };
    }
    return { ok: true, camera: publicCamera(cam), removed: false };
  }

  return { inBBox, importFeatures, importGeoJSON, report, confirm, dismiss };
}

module.exports = { createCameras, haversine, publicCamera, coord, kindOf, bearingOf, speedLimitOf };
