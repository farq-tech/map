'use strict';

/**
 * Route SURFACE split («زفلت ١٢ كم ← ترابي ٢ كم ← بر مفتوح ٤ كم») for the Valhalla routes.
 *
 * Why a second request: the OSRM-shaped answer the app decodes carries no surface at all (no
 * intersection `classes`, no annotations), and the gateway allows only route / optimized_route /
 * isochrone / sources_to_targets, so `trace_attributes` (per-edge surface) is not reachable. Valhalla's
 * own JSON /route answer, however, flags each maneuver that runs on rough / unpaved ground
 * (`rough: true`) and gives its length: the same /route action the gateway already allows.
 *
 * What we claim, and what we do not:
 *  - `unpaved`  a maneuver Valhalla flags `rough` (an unpaved or rough edge in its own graph).
 *  - `paved`    a maneuver Valhalla does not flag, on a named road or a highway.
 *  - `unknown`  a maneuver Valhalla does not flag AND with no street name (an unnamed way is very often
 *               an untagged track), so we do not call it asphalt.
 *  - `offroad` is always 0 here: Valhalla only routes on mapped roads and tracks; off-road legs come
 *               from the app's own desert planner.
 * Granularity is the maneuver (a long step on one road is one segment), not the single edge.
 * OSM surface tags are sparse in Qassim (about 1% of tracks tagged), so `known_share` is returned and
 * the app should show «غير معروف» rather than assume asphalt when it is low.
 */

const SURFACE_TIMEOUT_MS = 3_000;

const KINDS = ['paved', 'unpaved', 'offroad', 'unknown'];

function finiteKm(v) {
  return typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : null;
}

/** The body for the second request: the same route, Valhalla's native JSON, maneuvers only, no voice/banner. */
function surfaceBody(routeBody) {
  const { banner_instructions: _b, voice_instructions: _v, shape_format: _s, format: _f, directions_type: _d, ...rest } = routeBody;
  return { ...rest, format: 'json', directions_type: 'maneuvers' };
}

function classifyManeuver(m) {
  if (m.rough === true) return 'unpaved';
  const names = Array.isArray(m.street_names) ? m.street_names.filter((n) => typeof n === 'string' && n.trim()) : [];
  if (m.highway === true || names.length > 0) return 'paved';
  return 'unknown';
}

/** One Valhalla `trip` → the breakdown, or null when it carries no usable maneuvers. */
function breakdownFromTrip(trip) {
  const legs = Array.isArray(trip?.legs) ? trip.legs : [];
  const segments = [];
  let at = 0;
  let sawFlag = false;
  for (const leg of legs) {
    for (const m of Array.isArray(leg?.maneuvers) ? leg.maneuvers : []) {
      const km = finiteKm(m?.length);
      if (km == null) return null;
      if (Object.prototype.hasOwnProperty.call(m, 'rough')) sawFlag = true;
      /* A zero-length maneuver (departure / arrival) carries no surface. */
      if (km === 0) continue;
      const kind = classifyManeuver(m);
      const last = segments[segments.length - 1];
      if (last && last.kind === kind) {
        last.to_km = round3(at + km);
        last.km = round3(last.to_km - last.from_km);
      } else {
        segments.push({ kind, from_km: round3(at), to_km: round3(at + km), km: round3(km) });
      }
      at += km;
    }
  }
  if (!segments.length) return null;
  const totals = Object.fromEntries(KINDS.map((k) => [k, 0]));
  for (const s of segments) totals[s.kind] += s.km;
  for (const k of KINDS) totals[k] = round3(totals[k]);
  const total = round3(at);
  const known = total > 0 ? (totals.paved + totals.unpaved + totals.offroad) / total : 0;
  return {
    source: 'valhalla-maneuvers',
    granularity: 'maneuver',
    /* No maneuver carried the flag at all: Valhalla did not tell us about surface; do not read it as all-paved. */
    flag_present: sawFlag,
    total_km: total,
    totals_km: totals,
    known_share: round3(sawFlag ? known : 0),
    segments,
  };
}

function round3(v) {
  return Math.round(v * 1000) / 1000;
}

/**
 * Add `surface_breakdown` to every route of the OSRM answer that has a matching Valhalla trip
 * (routes[0] ↔ trip, routes[i] ↔ alternates[i-1].trip). A route without one is left exactly as it was.
 * Never throws: a malformed second answer just leaves the response unchanged.
 */
function attachSurfaces(osrmJson, valhallaJson) {
  try {
    const trips = [valhallaJson?.trip, ...(Array.isArray(valhallaJson?.alternates) ? valhallaJson.alternates.map((a) => a?.trip) : [])];
    const routes = osrmJson.routes.map((r, i) => {
      const b = breakdownFromTrip(trips[i]);
      /* The two answers must describe the same length, or we are looking at different routes. */
      if (b && typeof r?.distance === 'number' && r.distance > 0) {
        const diff = Math.abs(b.total_km * 1000 - r.distance) / r.distance;
        if (diff > 0.05) return r;
      }
      return b ? { ...r, surface_breakdown: b } : r;
    });
    return { ...osrmJson, routes };
  } catch {
    return osrmJson;
  }
}

module.exports = { surfaceBody, breakdownFromTrip, attachSurfaces, classifyManeuver, SURFACE_TIMEOUT_MS, KINDS };
