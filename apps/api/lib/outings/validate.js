'use strict';

/**
 * Pure input rules for shared outings. Everything a client sends passes through
 * here before it reaches SQL or another member's screen.
 */

const crypto = require('crypto');

const NAME_MAX = 40;
const OUTING_NAME_MAX = 60;
const AVATAR_MAX_CHARS = 24_000;

/** A fix older than this when it reaches us is history, not a live position. */
const MAX_FIX_AGE_MS = 60_000;
/** Beyond this the fix cannot place a person usefully on a map of the desert. */
const MAX_ACCURACY_M = 1_000;
/** ~200 km/h: faster than any car on these roads; above it is a GPS glitch. */
const MAX_SPEED_MPS = 55;
/** An SOS carries the sender's last real fix even when GPS has since gone
 * quiet; it is shown with its time, never as live, so it may be older. */
const SOS_FIX_MAX_AGE_MS = 30 * 60_000;

function cleanText(raw, max) {
  if (typeof raw !== 'string') return null;
  /* Collapse whitespace, drop control and bidi-override characters so a name
   * cannot reorder the text around it on someone else's screen. */
  const t = raw
    .replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (!t) return null;
  return [...t].slice(0, max).join('');
}

function displayName(raw) {
  return cleanText(raw, NAME_MAX);
}

/** A short line over your car («بوقف عند المحطة»). Empty clears it. */
const NOTE_MAX = 80;
function note(raw) {
  if (raw === '' || raw === null) return '';
  return cleanText(raw, NOTE_MAX);
}

/**
 * An optional phone number in E.164 (+9665XXXXXXXX). Saudi local forms
 * (05XXXXXXXX, 5XXXXXXXX, 9665XXXXXXXX, 009665…) are normalised; Arabic-Indic
 * digits are accepted. '' or null clears it. Returns undefined when invalid.
 */
function phone(raw) {
  if (raw === '' || raw === null) return null;
  if (typeof raw !== 'string') return undefined;
  let t = raw
    .replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06f0))
    .replace(/[\s\-().]/g, '');
  if (t.startsWith('00')) t = '+' + t.slice(2);
  /* Contacts often keep the trunk 0 after the country code: +966 05… */
  if (/^\+?96605\d{8}$/.test(t)) t = '+966' + t.replace(/^\+?9660/, '');
  if (/^05\d{8}$/.test(t)) t = '+966' + t.slice(1);
  else if (/^5\d{8}$/.test(t)) t = '+966' + t;
  else if (/^9665\d{8}$/.test(t)) t = '+' + t;
  return /^\+\d{8,15}$/.test(t) ? t : undefined;
}

function outingName(raw) {
  return cleanText(raw, OUTING_NAME_MAX);
}

/** Small images only, and only as a data URL of an image type we render. */
function avatar(raw) {
  if (raw == null || raw === '') return { ok: true, value: null };
  if (typeof raw !== 'string') return { ok: false };
  if (raw.length > AVATAR_MAX_CHARS) return { ok: false };
  if (!/^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/]+=*$/.test(raw)) return { ok: false };
  return { ok: true, value: raw };
}

function finite(v) {
  return typeof v === 'number' && Number.isFinite(v);
}

/**
 * A device fix → a position we are willing to show, or the reason we are not.
 *
 * The client sends `age_ms` (how old the fix was on its own clock when sent)
 * rather than a timestamp, so a phone whose clock is minutes off still yields
 * an honest `recorded_at` on ours.
 */
function fix(raw, now = Date.now(), { maxAgeMs = MAX_FIX_AGE_MS } = {}) {
  if (!raw || typeof raw !== 'object') return { ok: false, reason: 'invalid' };
  const { lat, lng } = raw;
  if (!finite(lat) || !finite(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    return { ok: false, reason: 'invalid_coordinates' };
  }
  if (lat === 0 && lng === 0) return { ok: false, reason: 'invalid_coordinates' };
  const accuracy = raw.accuracy == null ? null : raw.accuracy;
  if (accuracy !== null && (!finite(accuracy) || accuracy < 0)) return { ok: false, reason: 'invalid_accuracy' };
  if (accuracy !== null && accuracy > MAX_ACCURACY_M) return { ok: false, reason: 'inaccurate' };
  const age = raw.age_ms == null ? 0 : raw.age_ms;
  if (!finite(age) || age < 0) return { ok: false, reason: 'invalid_age' };
  if (age > maxAgeMs) return { ok: false, reason: 'stale' };
  let speed = raw.speed == null ? null : raw.speed;
  if (speed !== null && (!finite(speed) || speed < 0)) speed = null;
  if (speed !== null && speed > MAX_SPEED_MPS) return { ok: false, reason: 'implausible_speed' };
  let heading = raw.heading == null ? null : raw.heading;
  if (heading !== null) {
    heading = finite(heading) ? ((heading % 360) + 360) % 360 : null;
  }
  const mode = ['precise', 'balanced', 'saver'].includes(raw.mode) ? raw.mode : null;
  return {
    ok: true,
    value: {
      mode,
      lat: Math.round(lat * 1e6) / 1e6,
      lng: Math.round(lng * 1e6) / 1e6,
      accuracy: accuracy === null ? null : Math.round(accuracy * 10) / 10,
      heading: heading === null ? null : Math.round(heading),
      speed: speed === null ? null : Math.round(speed * 10) / 10,
      recorded_at: new Date(now - Math.round(age)),
    },
  };
}

/**
 * Battery Status API reading sent with the link heartbeat: { level 0..1,
 * charging }. Anything else (iOS has no such API) is null — never a guess.
 */
function battery(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const { level, charging } = raw;
  if (!finite(level) || level < 0 || level > 1 || typeof charging !== 'boolean') return null;
  return { level: Math.round(level * 100) / 100, charging };
}

/** A meeting point the owner drops on the map, with an optional short label. */
const RALLY_LABEL_MAX = 40;
function rally(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const { lat, lng } = raw;
  if (!finite(lat) || !finite(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  if (lat === 0 && lng === 0) return null;
  const label = raw.label == null || raw.label === '' ? null : cleanText(raw.label, RALLY_LABEL_MAX);
  return { lat: Math.round(lat * 1e6) / 1e6, lng: Math.round(lng * 1e6) / 1e6, label };
}

/**
 * An opt-in trip summary: totals only, computed on the person's own phone.
 * Anything that is not three plausible numbers is refused — there is no field
 * here that could carry a point. `spanS` is how long the outing ran on our clock.
 */
const TRIP_MAX_DISTANCE_M = 3_000_000;
const TRIP_MAX_DURATION_S = 14 * 24 * 3600;
function tripSummary(raw, { spanS = null } = {}) {
  if (!raw || typeof raw !== 'object') return { ok: false, reason: 'invalid_summary' };
  const keys = Object.keys(raw);
  if (keys.some((k) => !['distance_m', 'duration_s', 'moving_s'].includes(k))) return { ok: false, reason: 'invalid_summary' };
  const int = (x) => (finite(x) && x >= 0 ? Math.round(x) : null);
  const distance = int(raw.distance_m);
  const duration = int(raw.duration_s);
  const moving = raw.moving_s == null ? duration : int(raw.moving_s);
  if (distance === null || duration === null || moving === null) return { ok: false, reason: 'invalid_summary' };
  if (distance > TRIP_MAX_DISTANCE_M || duration > TRIP_MAX_DURATION_S || moving > duration) return { ok: false, reason: 'implausible_summary' };
  /* Faster on average than any car on these roads is a broken tracker, not a trip. */
  if (distance > MAX_SPEED_MPS * Math.max(moving, 1) + 500) return { ok: false, reason: 'implausible_summary' };
  /* A device can only have been in the outing while it ran (plus a little clock slack). */
  if (spanS != null && duration > spanS + 600) return { ok: false, reason: 'implausible_summary' };
  return { ok: true, value: { distance_m: distance, duration_s: duration, moving_s: moving } };
}

function isUuid(v) {
  return typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
}

/** 32 random bytes, base64url: 256 bits — not guessable, not enumerable. */
function newSecret() {
  return crypto.randomBytes(32).toString('base64url');
}

function isSecretShaped(v) {
  return typeof v === 'string' && /^[A-Za-z0-9_-]{43}$/.test(v);
}

function digest(secret) {
  return crypto.createHash('sha256').update(String(secret)).digest();
}

/* ---------- recovery codes ---------- */

/** Crockford base32: no I, L, O, U — nothing to misread when copied by hand. */
const RECOVERY_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const RECOVERY_SELECTOR_LEN = 8; // 40 bits, only to find the row
const RECOVERY_VERIFIER_LEN = 20; // 100 bits, stored as a digest
const RECOVERY_LEN = RECOVERY_SELECTOR_LEN + RECOVERY_VERIFIER_LEN;

/** A fresh code, grouped in fours for reading aloud: XXXX-XXXX-…(7 groups). */
function newRecoveryCode() {
  let raw = '';
  for (let i = 0; i < RECOVERY_LEN; i += 1) raw += RECOVERY_ALPHABET[crypto.randomInt(RECOVERY_ALPHABET.length)];
  return raw.match(/.{4}/g).join('-');
}

/**
 * What a person typed or pasted → { selector, verifier }, or null. Forgiving
 * about spaces, dashes, case, Arabic-Indic digits and the usual look-alikes
 * (O→0, I/L→1), strict about everything else.
 */
function recoveryCode(raw) {
  if (typeof raw !== 'string' || raw.length > 120) return null;
  const t = raw
    .replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06f0))
    .toUpperCase()
    .replace(/[\s\-_.\u2010-\u2015]/g, '')
    .replace(/O/g, '0')
    .replace(/[IL]/g, '1');
  if (t.length !== RECOVERY_LEN) return null;
  for (const ch of t) if (!RECOVERY_ALPHABET.includes(ch)) return null;
  return { selector: t.slice(0, RECOVERY_SELECTOR_LEN), verifier: t.slice(RECOVERY_SELECTOR_LEN) };
}

/** Constant-time equality of two digests (Buffers); false on any length mismatch. */
function sameDigest(a, b) {
  if (!Buffer.isBuffer(a) || !Buffer.isBuffer(b) || a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}


/* ---------- outing features (return timer, waypoints, convoy, plan, checklist) ---------- */

function latLng(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const { lat, lng } = raw;
  if (!finite(lat) || !finite(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  if (lat === 0 && lng === 0) return null;
  return { lat: Math.round(lat * 1e6) / 1e6, lng: Math.round(lng * 1e6) / 1e6 };
}

const CONTACT_NAME_MAX = 40;
/** A return timer may be set from one minute to seven days ahead. */
const TIMER_MIN_AHEAD_MS = 60_000;
const TIMER_MAX_AHEAD_MS = 7 * 24 * 3600_000;

/** { due_at: ISO, contact_name } → { ok, value } or { ok:false, reason }. */
function returnTimer(raw, now = Date.now()) {
  if (!raw || typeof raw !== 'object') return { ok: false, reason: 'invalid_timer' };
  if (typeof raw.due_at !== 'string' || raw.due_at.length > 40) return { ok: false, reason: 'invalid_due_at' };
  const due = Date.parse(raw.due_at);
  if (!Number.isFinite(due)) return { ok: false, reason: 'invalid_due_at' };
  if (due < now + TIMER_MIN_AHEAD_MS || due > now + TIMER_MAX_AHEAD_MS) return { ok: false, reason: 'invalid_due_at' };
  const contact = cleanText(raw.contact_name, CONTACT_NAME_MAX);
  if (!contact) return { ok: false, reason: 'invalid_contact_name' };
  return { ok: true, value: { due_at: new Date(due), contact_name: contact } };
}

const WAYPOINT_KINDS = ['camp', 'water', 'danger', 'passable', 'stuck_spot', 'other'];
const WAYPOINT_TITLE_MAX = 40;
const WAYPOINT_NOTE_MAX = 140;
const WAYPOINT_PHOTO_MAX_BYTES = 150 * 1024;
const JPEG_PREFIX = 'data:image/jpeg;base64,';

/** A JPEG data URL of at most 150 KB of image bytes, or null. undefined = invalid. */
function waypointPhoto(raw) {
  if (raw == null || raw === '') return null;
  if (typeof raw !== 'string' || !raw.startsWith(JPEG_PREFIX)) return undefined;
  const b64 = raw.slice(JPEG_PREFIX.length);
  if (b64.length > Math.ceil(WAYPOINT_PHOTO_MAX_BYTES / 3) * 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(b64)) return undefined;
  const bytes = Buffer.from(b64, 'base64');
  if (bytes.length > WAYPOINT_PHOTO_MAX_BYTES || bytes.length < 4) return undefined;
  /* JPEG SOI marker: what the data URL says it is. */
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) return undefined;
  return raw;
}

function waypoint(raw) {
  if (!raw || typeof raw !== 'object') return { ok: false, reason: 'invalid_waypoint' };
  if (!WAYPOINT_KINDS.includes(raw.kind)) return { ok: false, reason: 'invalid_kind' };
  const title = cleanText(raw.title, WAYPOINT_TITLE_MAX);
  if (!title) return { ok: false, reason: 'invalid_title' };
  let noteText = null;
  if (raw.note != null && raw.note !== '') {
    noteText = cleanText(raw.note, WAYPOINT_NOTE_MAX);
    if (noteText === null) return { ok: false, reason: 'invalid_note' };
  }
  const p = latLng(raw);
  if (!p) return { ok: false, reason: 'invalid_coordinates' };
  const photo = waypointPhoto(raw.photo);
  if (photo === undefined) return { ok: false, reason: 'invalid_photo' };
  return { ok: true, value: { kind: raw.kind, title, note: noteText, lat: p.lat, lng: p.lng, photo } };
}

/** Optional stuck note: '' / null / undefined → null; too long is cut like a car note. */
function stuckNote(raw) {
  if (raw == null || raw === '') return { ok: true, value: null };
  const t = cleanText(raw, NOTE_MAX);
  return t === null ? { ok: false } : { ok: true, value: t };
}

const STUCK_REPLY_KINDS = ['coming', 'have_rope', 'cant'];

const CONVOY_GAP_MIN = 200;
const CONVOY_GAP_MAX = 5000;

/** PATCH body → { lead?, tail?, gap? } (undefined = keep), or null when invalid. */
function convoyPatch(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const out = {};
  for (const [k, key] of [['lead_user_id', 'lead'], ['tail_user_id', 'tail']]) {
    if (raw[k] === undefined) continue;
    if (raw[k] !== null && !isUuid(raw[k])) return null;
    out[key] = raw[k] === null ? null : raw[k].toLowerCase();
  }
  if (raw.max_gap_m !== undefined) {
    if (!finite(raw.max_gap_m) || raw.max_gap_m < CONVOY_GAP_MIN || raw.max_gap_m > CONVOY_GAP_MAX) return null;
    out.gap = Math.round(raw.max_gap_m);
  }
  if (!Object.keys(out).length) return null;
  return out;
}

const PLAN_MAX_POINTS = 5000;
const PLAN_NOTES_MAX = 1000;
const DESTINATION_NAME_MAX = 40;

/** Notes keep their line breaks (a packing list reads better that way) but nothing else odd. */
function planNotes(raw) {
  if (raw == null || raw === '') return '';
  if (typeof raw !== 'string') return null;
  const t = raw
    .replace(/\r\n?/g, '\n')
    .replace(/[\u0000-\u0009\u000b-\u001f\u007f‪-‮⁦-⁩]/g, '')
    .replace(/[ \t]+/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  return [...t].slice(0, PLAN_NOTES_MAX).join('');
}

/** A GeoJSON LineString of [lng, lat] pairs (2..5000), or null. undefined = invalid. */
function planRoute(raw) {
  if (raw === null) return null;
  if (!raw || typeof raw !== 'object' || raw.type !== 'LineString' || !Array.isArray(raw.coordinates)) return undefined;
  const c = raw.coordinates;
  if (c.length < 2 || c.length > PLAN_MAX_POINTS) return undefined;
  const coords = [];
  for (const pt of c) {
    if (!Array.isArray(pt) || pt.length < 2 || pt.length > 3) return undefined;
    const [lng, lat] = pt;
    if (!finite(lng) || !finite(lat) || lng < -180 || lng > 180 || lat < -90 || lat > 90) return undefined;
    coords.push([Math.round(lng * 1e6) / 1e6, Math.round(lat * 1e6) / 1e6]);
  }
  return { type: 'LineString', coordinates: coords };
}

/** «الوجهة»: { name ≤40, lat, lng } or null. undefined = invalid. */
function destination(raw) {
  if (raw === null) return null;
  if (!raw || typeof raw !== 'object') return undefined;
  const name = cleanText(raw.name, DESTINATION_NAME_MAX);
  if (!name) return undefined;
  const p = latLng(raw);
  if (!p) return undefined;
  return { name, lat: p.lat, lng: p.lng };
}

/** PUT body → { route?, notes?, destination? } (undefined = keep), or { error }. */
function planPut(raw) {
  if (!raw || typeof raw !== 'object') return { error: 'invalid_plan' };
  const out = {};
  if (raw.route !== undefined) {
    const r = planRoute(raw.route);
    if (r === undefined) return { error: 'invalid_route' };
    out.route = r;
  }
  if (raw.notes !== undefined) {
    const n = planNotes(raw.notes);
    if (n === null) return { error: 'invalid_notes' };
    out.notes = n;
  }
  if (raw.destination !== undefined) {
    const d = destination(raw.destination);
    if (d === undefined) return { error: 'invalid_destination' };
    out.destination = d;
  }
  if (!Object.keys(out).length) return { error: 'invalid_plan' };
  return { value: out };
}

const CHECKLIST_TITLE_MAX = 40;
function checklistTitle(raw) {
  return cleanText(raw, CHECKLIST_TITLE_MAX);
}

module.exports = {
  latLng,
  returnTimer,
  TIMER_MAX_AHEAD_MS,
  WAYPOINT_KINDS,
  WAYPOINT_PHOTO_MAX_BYTES,
  waypoint,
  waypointPhoto,
  stuckNote,
  STUCK_REPLY_KINDS,
  convoyPatch,
  PLAN_MAX_POINTS,
  planRoute,
  planNotes,
  destination,
  planPut,
  checklistTitle,
  cleanText,
  NAME_MAX,
  OUTING_NAME_MAX,
  AVATAR_MAX_CHARS,
  MAX_FIX_AGE_MS,
  MAX_ACCURACY_M,
  MAX_SPEED_MPS,
  SOS_FIX_MAX_AGE_MS,
  NOTE_MAX,
  RALLY_LABEL_MAX,
  battery,
  rally,
  displayName,
  note,
  phone,
  outingName,
  avatar,
  fix,
  tripSummary,
  isUuid,
  newSecret,
  isSecretShaped,
  digest,
  RECOVERY_LEN,
  newRecoveryCode,
  recoveryCode,
  sameDigest,
};
