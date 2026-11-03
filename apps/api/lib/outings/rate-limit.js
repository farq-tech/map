'use strict';

/** Fixed-window counter per key. In memory: one instance today, see hub.js. */
function createRateLimiter({ limit, windowMs, now = () => Date.now() }) {
  const hits = new Map();
  return function allow(key) {
    const t = now();
    const row = hits.get(key);
    if (!row || t - row.start >= windowMs) {
      hits.set(key, { start: t, n: 1 });
      if (hits.size > 10_000) {
        for (const [k, r] of hits) if (t - r.start >= windowMs) hits.delete(k);
      }
      return true;
    }
    row.n += 1;
    return row.n <= limit;
  };
}

module.exports = { createRateLimiter };
