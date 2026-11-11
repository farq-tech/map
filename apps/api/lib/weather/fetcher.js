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

function limiter(n) {
  let active = 0;
  const queue = [];
  const next = () => {
    if (active >= n || !queue.length) return;
    active++;
    const { fn, resolve, reject } = queue.shift();
    fn().then(resolve, reject).finally(() => {
      active--;
      next();
    });
  };
  return (fn) => new Promise((resolve, reject) => {
    queue.push({ fn, resolve, reject });
    next();
  });
}

/* One queue per upstream host: the GIBS warm-up must not hold back a cloud tile. */
const limits = new Map();
function limitFor(url) {
  const host = new URL(url).host;
  if (!limits.has(host)) limits.set(host, limiter(Number(process.env.WEATHER_UPSTREAM_CONCURRENCY) || 6));
  return limits.get(host);
}

async function realFetchBuffer(url, { timeoutMs = 30_000, headers = {} } = {}) {
  return limitFor(url)(async () => {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const r = await fetch(url, { signal: ctrl.signal, headers: { 'user-agent': UA, ...headers } });
      const buf = Buffer.from(await r.arrayBuffer());
      return { status: r.status, type: r.headers.get('content-type') || '', body: buf, expires: r.headers.get('expires') || null };
    } finally {
      clearTimeout(t);
    }
  });
}

let impl = realFetchBuffer;
/** Replace the network (tests). Pass null to restore. */
function setFetch(fn) {
  impl = fn || realFetchBuffer;
}
function fetchBuffer(url, opts) {
  return impl(url, opts);
}

/** One in-flight promise per key: concurrent requests for the same tile share a fetch. */
function memo(cache, inflight, key, fn) {
  const hit = cache.get(key);
  if (hit !== undefined) return Promise.resolve(hit);
  if (inflight.has(key)) return inflight.get(key);
  const p = fn().then(
    (v) => {
      inflight.delete(key);
      if (v !== undefined && v !== null) cache.set(key, v);
      return v;
    },
    (e) => {
      inflight.delete(key);
      throw e;
    },
  );
  inflight.set(key, p);
  return p;
}

module.exports = { Lru, limiter, fetchBuffer, setFetch, memo };
