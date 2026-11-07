'use strict';

/**
 * `/api/desert/categories/search?q=مطر|ربيع&near=lat,lng` — ranked named desert places (OSM:
 * روضة، فيضة، شعيب، وادي) and unnamed rain / green hotspots, by what the satellites saw:
 * «نزل مطر هنا قبل ٣ أيام»، «هنا خضّر». Never invents a place: names are OSM's, hotspots are
 * grid cells labelled «منطقة قرب <أقرب مكان مسمّى>».
 */

const outdoor = require('../outdoor');
const rain = require('./rain');
const green = require('./green');
const { KSA, haversineKm, inKsa } = require('./mercator');

const RAIN_RE = /مطر|امطار|أمطار|سيل|سيول|غيث|رعد|rain|flood/i;
const GREEN_RE = /ربيع|ربّع|ربع|خضر|خضار|عشب|نفل|خزامى|روض|فيض|green|spring|bloom/i;
const PLACE_KINDS = new Set(['rawdah', 'fayad', 'shaib', 'wadi', 'camp', 'spring']);
const KIND_AR = { rawdah: 'روضة', fayad: 'فيضة', shaib: 'شعيب', wadi: 'وادي', camp: 'مخيم', spring: 'عين' };

/** Resolves to `fallback` if `p` takes longer than `ms` (cold caches must not hang a search). */
function within(p, ms, fallback = null) {
  return Promise.race([p.catch(() => fallback), new Promise((r) => setTimeout(() => r(fallback), ms).unref())]);
}

const toAr = (n) => String(n).replace(/\d/g, (c) => '٠١٢٣٤٥٦٧٨٩'[c]);

/** `مطر|ربيع` → intents. Unknown words → both. */
function parseIntents(q) {
  const s = String(q || '');
  const out = [];
  if (RAIN_RE.test(s)) out.push('rain');
  if (GREEN_RE.test(s)) out.push('green');
  return out.length ? out : ['rain', 'green'];
}

function rainHeadline(mm, hoursAgo) {
  const when = rain.agoAr(hoursAgo);
  const amount = mm >= 1 ? ` (حوالي ${toAr(Math.round(mm))} ملم)` : '';
  return when ? `نزل مطر هنا ${when}${amount}` : `نزل مطر هنا خلال الأسبوع${amount}`;
}

function greenHeadline(rise) {
  if (rise >= 0.2) return 'هنا خضّر بقوة (ربيع كثيف)';
  if (rise >= 0.12) return 'هنا خضّر';
  return 'بدت الخضرة هنا';
}

/** 0..1 scores. Pure. */
function rainScore(mm, hoursAgo) {
  if (!(mm >= 1)) return 0;
  const amount = Math.min(1, Math.log1p(mm) / Math.log1p(60));
  const fresh = Number.isFinite(hoursAgo) ? Math.max(0.25, 1 - hoursAgo / (7 * 24)) : 0.4;
  return amount * fresh;
}
function greenScore(rise) {
  return rise > 0 ? Math.min(1, rise / 0.3) : 0;
}
function distanceFactor(km, radius) {
  return km == null ? 1 : Math.max(0.35, 1 - km / (radius * 1.5));
}

function round(n, d = 1) {
  const k = 10 ** d;
  return Math.round(n * k) / k;
}

/**
 * Ranks places. `deps` (tests) can provide { places, rainSum, greenState, nowMs }.
 */
async function search({ q, near, radiusKm = 250, limit = 20, nowMs = Date.now(), deps = {} }) {
  const intents = parseIntents(q);
  const radius = Math.max(10, Math.min(800, Number(radiusKm) || 250));
  const lim = Math.max(1, Math.min(50, Number(limit) || 20));

  let rainSum = deps.rainSum;
  let rainLatest = null;
  if (intents.includes('rain') && rainSum === undefined) {
    rainLatest = await within(rain.ensureWindow(7, { waitMs: 15_000, nowMs }), 20_000);
    rainSum = rainLatest ? rain.windowSum(7, rainLatest) : null;
  }
  let greenState = deps.greenState;
  if (intents.includes('green') && greenState === undefined) greenState = await within(green.state(nowMs), 20_000);

  const index = deps.places || outdoor.loadIndex().map((f) => f.properties);
  const places = index.filter((p) => PLACE_KINDS.has(p.kind) && p.name && Number.isFinite(p.lat) && Number.isFinite(p.lng));

  const results = [];
  for (const p of places) {
    const km = near ? haversineKm(near, p) : null;
    if (km != null && km > radius) continue;
    const signals = {};
    let score = 0;
    let headline = null;
    if (rainSum && intents.includes('rain')) {
      const r = rain.pointInfo(rainSum, p.lng, p.lat, nowMs);
      signals.rain_mm_7d = r.mm;
      signals.last_rain_days_ago = Number.isFinite(r.hoursAgo) ? round(r.hoursAgo / 24) : null;
      const s = rainScore(r.mm, r.hoursAgo);
      if (s > score) {
        score = s;
        headline = rainHeadline(r.mm, r.hoursAgo);
      }
    }
    if (greenState && intents.includes('green')) {
      const g = green.pointInfo(greenState, p.lng, p.lat);
      signals.ndvi = g.ndvi;
      signals.green_rise = g.rise;
      const s = greenScore(g.rise) * (p.kind === 'rawdah' || p.kind === 'fayad' ? 1.15 : 1);
      if (s > score) {
        score = Math.min(1, s);
        headline = greenHeadline(g.rise);
      }
    }
    if (score <= 0) continue;
    results.push({
      id: p.id,
      type: 'place',
      name_ar: p.name,
      kind: p.kind,
      kind_ar: KIND_AR[p.kind] || null,
      lat: p.lat,
      lng: p.lng,
      distance_km: km == null ? null : round(km),
      score: round(score * distanceFactor(km, radius), 3),
      headline_ar: headline,
      signals,
      source: 'osm',
    });
  }

  /* One row per name nearby: OSM splits a wadi into many segments. Keep the best. */
  results.sort((a, b) => b.score - a.score);
  const deduped = [];
  for (const r of results) {
    if (deduped.some((d) => d.name_ar === r.name_ar && haversineKm(d, r) < 25)) continue;
    deduped.push(r);
  }
  results.length = 0;
  results.push(...deduped);

  /* Unnamed hotspots: the strongest grid cells near the person, labelled by the nearest name. */
  const box = near
    ? { west: near.lng - radius / 100, east: near.lng + radius / 100, south: near.lat - radius / 111, north: near.lat + radius / 111 }
    : KSA;
  const areas = [];
  const step = 0.25;
  for (let lat = Math.max(KSA.south, box.south); lat <= Math.min(KSA.north, box.north); lat += step) {
    for (let lng = Math.max(KSA.west, box.west); lng <= Math.min(KSA.east, box.east); lng += step) {
      const km = near ? haversineKm(near, { lat, lng }) : null;
      if (km != null && km > radius) continue;
      if (!inKsa(lng, lat)) continue;
      let score = 0;
      let headline = null;
      const signals = {};
      if (rainSum && intents.includes('rain')) {
        const r = rain.pointInfo(rainSum, lng, lat, nowMs);
        const s = rainScore(r.mm, r.hoursAgo);
        signals.rain_mm_7d = r.mm;
        signals.last_rain_days_ago = Number.isFinite(r.hoursAgo) ? round(r.hoursAgo / 24) : null;
        if (s > score && r.mm >= 5) {
          score = s;
          headline = rainHeadline(r.mm, r.hoursAgo);
        }
      }
      if (greenState && intents.includes('green')) {
        const g = green.pointInfo(greenState, lng, lat);
        signals.ndvi = g.ndvi;
        signals.green_rise = g.rise;
        const s = greenScore(g.rise);
        if (s > score && g.rise >= 0.1) {
          score = s;
          headline = greenHeadline(g.rise);
        }
      }
      if (score > 0) areas.push({ lat: round(lat, 3), lng: round(lng, 3), km, score, headline, signals });
    }
  }
  areas.sort((a, b) => b.score - a.score);
  const picked = [];
  for (const a of areas) {
    if (picked.length >= 5) break;
    if (picked.some((b) => haversineKm(a, b) < 40)) continue;
    picked.push(a);
  }
  for (const a of picked) {
    let nearest = null;
    let best = Infinity;
    for (const p of places) {
      const d = Math.abs(p.lat - a.lat) + Math.abs(p.lng - a.lng);
      if (d < best) {
        best = d;
        nearest = p;
      }
    }
    const nkm = nearest ? haversineKm(a, nearest) : null;
    results.push({
      id: `area:${a.lat},${a.lng}`,
      type: 'area',
      name_ar: nearest && nkm <= 40 ? `منطقة قرب ${nearest.name}` : 'منطقة بلا اسم معروف',
      kind: 'area',
      kind_ar: 'منطقة',
      lat: a.lat,
      lng: a.lng,
      distance_km: a.km == null ? null : round(a.km),
      score: round(a.score * distanceFactor(a.km, radius) * 0.95, 3),
      headline_ar: a.headline,
      signals: a.signals,
      source: 'satellite',
    });
  }

  results.sort((a, b) => b.score - a.score);
  return {
    ok: true,
    query: String(q || ''),
    intents,
    near: near || null,
    radius_km: radius,
    count: Math.min(lim, results.length),
    results: results.slice(0, lim),
    data: {
      rain: rainSum ? { window_days: 7, until: new Date(rainSum.to).toISOString(), complete: rainSum.coverage.frames_ok + rainSum.coverage.frames_missing >= rainSum.coverage.frames_expected } : null,
      green: greenState ? { composite_date: greenState.ymd, baseline_dates: greenState.base.split(',') } : null,
    },
    warming: (intents.includes('rain') && !rainSum) || (intents.includes('green') && !greenState),
    attribution: [
      '© OpenStreetMap contributors (ODbL)',
      ...(intents.includes('rain') ? [rain.ATTRIBUTION] : []),
      ...(intents.includes('green') ? [green.ATTRIBUTION] : []),
    ],
    generated_at: new Date(nowMs).toISOString(),
  };
}

module.exports = { search, parseIntents, rainScore, greenScore, rainHeadline, greenHeadline };
