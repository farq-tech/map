'use strict';

/**
 * Upstream fetches for the weather layers: a timeout, a small concurrency cap (we are a polite
 * client of NASA GIBS and EUMETSAT), and an in-memory LRU so a tile is fetched once.
 * Tests replace `fetchBuffer` with a fake through `setFetch`.
 */

const UA = 'SaryAlbarq-API/1.0 (+https://github.com/farq-tech/map)';

class Lru {
  constructor(max) {
    this.max = max;
    this.map = new Map();
  }
  get(k) {
    if (!this.map.has(k)) return undefined;
    const v = this.map.get(k);
    this.map.delete(k);
    this.map.set(k, v);
    return v;
  }
  set(k, v) {
    this.map.delete(k);
    this.map.set(k, v);
    while (this.map.size > this.max) this.map.delete(this.map.keys().next().value);
  }
  has(k) {
    return this.map.has(k);
  }
  get size() {
    return this.map.size;
  }
}

/**
 * Concurrency cap with two classes. `interactive` work (a person is waiting) may use every slot;
 * `background` work (pre-warm) may use at most `n - reserve` slots, so it can never starve a user
 * request. Interactive jobs are always dequeued first. A queued job that waits longer than
 * `queueTimeoutMs` is rejected (it never waits for ever behind a slow upstream).
 */
function limiter(n, { reserve = 0 } = {}) {
  let active = 0;
  let activeBg = 0;
  const hi = [];
  const lo = [];
  const bgCap = Math.max(1, n - reserve);
  const next = () => {
    while (active < n) {
      let job = null;
      if (hi.length) job = hi.shift();
      else if (lo.length && activeBg < bgCap) job = lo.shift();
      if (!job) return;
      clearTimeout(job.timer);
      active++;
      if (job.bg) activeBg++;
      Promise.resolve().then(job.fn).then(job.resolve, job.reject).finally(() => {
        active--;
        if (job.bg) activeBg--;
        next();
      });
    }
  };
  const run = (fn, { background = false, queueTimeoutMs = 0 } = {}) => new Promise((resolve, reject) => {
    const job = { fn, resolve, reject, bg: background, timer: null };
    if (queueTimeoutMs > 0) {
      job.timer = setTimeout(() => {
        const q = background ? lo : hi;
        const i = q.indexOf(job);
        if (i >= 0) {
          q.splice(i, 1);
          const e = new Error('queue_timeout');
          e.code = 'QUEUE_TIMEOUT';
          reject(e);
        }
      }, queueTimeoutMs);
      if (job.timer.unref) job.timer.unref();
    }
    (background ? lo : hi).push(job);
    next();
  });
  run.stats = () => ({ active, activeBg, queuedInteractive: hi.length, queuedBackground: lo.length });
  return run;
}

/* One queue per upstream host: the GIBS warm-up must not hold back a cloud tile. */
const limits = new Map();
function limitFor(url) {
  const host = new URL(url).host;
  if (!limits.has(host)) {
    const n = Number(process.env.WEATHER_UPSTREAM_CONCURRENCY) || 6;
    limits.set(host, limiter(n, { reserve: Number(process.env.WEATHER_UPSTREAM_RESERVE) || Math.ceil(n / 2) }));
  }
  return limits.get(host);
}

/** Reject after `ms` whatever `p` does (the work may carry on; the caller no longer waits for it). */
function withDeadline(p, ms, code = 'TIMEOUT') {
  let timer;
  const t = new Promise((_, reject) => {
    timer = setTimeout(() => {
      const e = new Error(code.toLowerCase());
      e.code = code;
      reject(e);
    }, ms);
    if (timer.unref) timer.unref();
  });
  return Promise.race([Promise.resolve(p), t]).finally(() => clearTimeout(timer));
}

function logUpstream(label, host, status, ms, extra = '') {
  if (process.env.NODE_TEST_CONTEXT || process.env.WEATHER_UPSTREAM_LOG === '0') return;
  console.log(`[${label}] upstream ${host} ${status} ${ms} ms${extra}`);
}

/**
 * `timeoutMs` is a HARD cap on the network call itself (connect + headers + body: the abort signal
 * and a race both enforce it). `queueTimeoutMs` caps the wait for a free slot. `background: true`
 * marks pre-warm traffic (lower priority, fewer slots). `label` names the log line.
 */
async function realFetchBuffer(url, { timeoutMs = 30_000, queueTimeoutMs = 0, background = false, label = 'weather', headers = {} } = {}) {
  const host = new URL(url).host;
  return limitFor(url)(async () => {
    const started = Date.now();
    const ctrl = new AbortController();
    const abort = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const work = (async () => {
        const r = await fetch(url, { signal: ctrl.signal, headers: { 'user-agent': UA, ...headers } });
        const buf = Buffer.from(await r.arrayBuffer());
        return { status: r.status, type: r.headers.get('content-type') || '', body: buf, expires: r.headers.get('expires') || null };
      })();
      work.catch(() => {}); // a late failure after the deadline is not an unhandled rejection
      const out = await withDeadline(work, timeoutMs + 500, 'UPSTREAM_TIMEOUT');
      logUpstream(label, host, out.status, Date.now() - started, background ? ' bg' : '');
      return out;
    } catch (e) {
      ctrl.abort();
      logUpstream(label, host, e.code === 'UPSTREAM_TIMEOUT' || e.name === 'AbortError' ? 'timeout' : `error(${e.message})`, Date.now() - started, background ? ' bg' : '');
      throw e;
    } finally {
      clearTimeout(abort);
    }
  }, { background, queueTimeoutMs });
}

let impl = realFetchBuffer;
/** Replace the network (tests). Pass null to restore. */
function setFetch(fn) {
  impl = fn || realFetchBuffer;
}
function fetchBuffer(url, opts) {
  return impl(url, opts);
}

/**
 * One in-flight promise per key: concurrent requests for the same tile share a fetch. The entry is
 * ALWAYS removed: on success, on rejection and when `fn` has not settled after `timeoutMs`
 * (a never-settling promise must not be shared by every later request).
 */
function memo(cache, inflight, key, fn, { timeoutMs = 90_000 } = {}) {
  const hit = cache.get(key);
  if (hit !== undefined) return Promise.resolve(hit);
  if (inflight.has(key)) return inflight.get(key);
  const p = withDeadline(Promise.resolve().then(fn), timeoutMs, 'INFLIGHT_TIMEOUT').then(
    (v) => {
      if (inflight.get(key) === p) inflight.delete(key);
      if (v !== undefined && v !== null) cache.set(key, v);
      return v;
    },
    (e) => {
      if (inflight.get(key) === p) inflight.delete(key);
      throw e;
    },
  );
  inflight.set(key, p);
  return p;
}

module.exports = { Lru, limiter, fetchBuffer, setFetch, memo, withDeadline };
