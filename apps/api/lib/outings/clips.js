'use strict';

/**
 * Push-to-talk voice clips («اضغط وتكلم»).
 *
 * A clip is a passing word to the group, not a record: the bytes live in this
 * process's memory only, for CLIP_TTL_MS, and are gone sooner when the outing
 * ends, when the sender leaves or is removed, or when the server restarts.
 * Nothing is written to disk or to Postgres, and no third party sees it.
 *
 * The container is sniffed from the bytes, never taken from the client's
 * Content-Type, and served back as that type only.
 */

const crypto = require('crypto');

const CLIP_TTL_MS = 10 * 60_000;
/** 15 s of AAC at 128 kbps is ~240 KB; Opus is far smaller. Head-room, not an invitation. */
const CLIP_MAX_BYTES = 400 * 1024;
const CLIP_MIN_BYTES = 256;
const CLIP_MAX_MS = 15_000;
/** Recorders overshoot a stop by a few hundred ms. */
const CLIP_DURATION_SLACK_MS = 1_000;
const CLIP_MIN_MS = 300;
/** Whole-process ceiling so a busy evening cannot exhaust memory. */
const STORE_MAX_BYTES = 64 * 1024 * 1024;
/** Per outing: the newest few are what matters. */
const OUTING_MAX_CLIPS = 30;

/** Container from the first bytes → the one type we will serve it as. */
function sniffAudio(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 12) return null;
  /* ISO BMFF (MP4/M4A): [size:4]['ftyp'] — what iOS Safari records (AAC). */
  if (buf.toString('latin1', 4, 8) === 'ftyp') return 'audio/mp4';
  /* EBML header — WebM (Chrome/Firefox Opus). */
  if (buf[0] === 0x1a && buf[1] === 0x45 && buf[2] === 0xdf && buf[3] === 0xa3) return 'audio/webm';
  if (buf.toString('latin1', 0, 4) === 'OggS') return 'audio/ogg';
  return null;
}

function parseDurationMs(raw) {
  const n = Number(raw);
  if (!Number.isFinite(n)) return null;
  const ms = Math.round(n);
  if (ms < CLIP_MIN_MS || ms > CLIP_MAX_MS + CLIP_DURATION_SLACK_MS) return null;
  return Math.min(ms, CLIP_MAX_MS);
}

function createClipStore({ ttlMs = CLIP_TTL_MS, maxTotalBytes = STORE_MAX_BYTES, perOuting = OUTING_MAX_CLIPS, now = () => Date.now() } = {}) {
  const byOuting = new Map(); // outingId -> Map(clipId -> { meta, buf })
  let total = 0;

  function drop(outingId, clipId) {
    const room = byOuting.get(outingId);
    const rec = room?.get(clipId);
    if (!rec) return;
    room.delete(clipId);
    total -= rec.buf.length;
    if (!room.size) byOuting.delete(outingId);
  }

  function sweep() {
    const t = now();
    for (const [oid, room] of byOuting) {
      for (const [cid, rec] of room) if (rec.expiresAt <= t) drop(oid, cid);
    }
  }

  function oldest() {
    let best = null;
    for (const [oid, room] of byOuting) {
      for (const [cid, rec] of room) if (!best || rec.at < best.at) best = { oid, cid, at: rec.at };
    }
    return best;
  }

  function shape(outingId, rec) {
    return {
      id: rec.id,
      user_id: rec.userId,
      mime: rec.mime,
      duration_ms: rec.durationMs,
      bytes: rec.buf.length,
      at: new Date(rec.at).toISOString(),
      expires_at: new Date(rec.expiresAt).toISOString(),
      /* Needs the member's Bearer token too; it stops working at expires_at. */
      url: `/api/outings/${outingId}/clips/${rec.id}`,
    };
  }

  function put(outingId, userId, { buf, mime, durationMs }) {
    sweep();
    const at = now();
    const rec = { id: crypto.randomBytes(16).toString('hex'), userId, mime, durationMs, buf, at, expiresAt: at + ttlMs };
    if (!byOuting.has(outingId)) byOuting.set(outingId, new Map());
    const room = byOuting.get(outingId);
    room.set(rec.id, rec);
    total += buf.length;
    while (room.size > perOuting) drop(outingId, room.keys().next().value);
    while (total > maxTotalBytes) {
      const o = oldest();
      if (!o) break;
      drop(o.oid, o.cid);
    }
    return shape(outingId, rec);
  }

  function get(outingId, clipId) {
    const rec = byOuting.get(outingId)?.get(clipId);
    if (!rec) return null;
    if (rec.expiresAt <= now()) {
      drop(outingId, clipId);
      return null;
    }
    return { meta: shape(outingId, rec), buf: rec.buf };
  }

  function list(outingId) {
    const room = byOuting.get(outingId);
    if (!room) return [];
    const t = now();
    const out = [];
    for (const [cid, rec] of [...room]) {
      if (rec.expiresAt <= t) drop(outingId, cid);
      else out.push(shape(outingId, rec));
    }
    return out;
  }

  function dropOuting(outingId) {
    for (const cid of [...(byOuting.get(outingId)?.keys() || [])]) drop(outingId, cid);
  }

  function dropUser(outingId, userId) {
    for (const [cid, rec] of [...(byOuting.get(outingId) || [])]) if (rec.userId === userId) drop(outingId, cid);
  }

  function lastAt(outingId, userId) {
    let t = 0;
    for (const rec of byOuting.get(outingId)?.values() || []) if (rec.userId === userId && rec.at > t) t = rec.at;
    return t;
  }

  return { put, get, list, dropOuting, dropUser, lastAt, sweep, stats: () => ({ bytes: total, outings: byOuting.size }) };
}

module.exports = {
  CLIP_TTL_MS,
  CLIP_MAX_BYTES,
  CLIP_MIN_BYTES,
  CLIP_MAX_MS,
  sniffAudio,
  parseDurationMs,
  createClipStore,
};
