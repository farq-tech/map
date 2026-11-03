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
function fix(raw, now = Date.now()) {
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
  if (age > MAX_FIX_AGE_MS) return { ok: false, reason: 'stale' };
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

module.exports = {
  NAME_MAX,
  OUTING_NAME_MAX,
  AVATAR_MAX_CHARS,
  MAX_FIX_AGE_MS,
  MAX_ACCURACY_M,
  MAX_SPEED_MPS,
  NOTE_MAX,
  displayName,
  note,
  phone,
  outingName,
  avatar,
  fix,
  isUuid,
  newSecret,
  isSecretShaped,
  digest,
  RECOVERY_LEN,
  newRecoveryCode,
  recoveryCode,
  sameDigest,
};
