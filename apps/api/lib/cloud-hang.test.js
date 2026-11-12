'use strict';

/**
 * Regression tests for the 2026-11-12 hang of GET /weather/clouds/tiles and /clouds/outlook:
 * the capabilities fetch waited in the per-host queue behind the pre-warm tiles (EUMETView ~30 s a
 * tile), with no queue timeout, no dedupe and no stale fallback. See docs in the PR description.
 */

process.env.CLOUD_CAPS_TIMEOUT_MS = '150';
process.env.CLOUD_TILE_TIMEOUT_MS = '400';
process.env.WEATHER_ROUTE_DEADLINE_MS = '600';

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const fetcher = require('./weather/fetcher');
const clouds = require('./weather/clouds');

const CAPS_XML = (iso) => `<Dimension name="time">2026-11-10T00:00:00Z/${iso}/PT10M</Dimension>`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const realFetch = globalThis.fetch;
const never = () => new Promise(() => {});

function resp(body, type) {
  return new Response(body, { headers: { 'content-type': type } });
}

test.afterEach(() => {
  globalThis.fetch = realFetch;
  fetcher.setFetch(null);
  clouds._reset();
});

test('limiter: background jobs never take the reserved slots; interactive jobs go first', async () => {
  const run = fetcher.limiter(4, { reserve: 2 });
  const gates = [];
  const started = [];
  const job = (name) => () => new Promise((resolve) => {
    started.push(name);
    gates.push(resolve);
  });
  const bg = [1, 2, 3, 4].map((i) => run(job(`bg${i}`), { background: true }));
  await sleep(10);
  assert.deepEqual(started, ['bg1', 'bg2'], 'only n - reserve background jobs run');
  const ui = [run(job('ui1')), run(job('ui2'))];
  await sleep(10);
  assert.deepEqual(started.slice(2), ['ui1', 'ui2'], 'a person gets a slot at once');
  gates.splice(0).forEach((g) => g());
  await Promise.all([...ui, bg[0], bg[1]]);
  gates.splice(0).forEach((g) => g());
  await sleep(10);
  gates.splice(0).forEach((g) => g());
  await Promise.all(bg);
});

test('limiter: a queued job gives up after queueTimeoutMs instead of waiting for ever', async () => {
  const run = fetcher.limiter(1);
  run(never); // the slot is held by a call that never ends
  const t0 = Date.now();
  await assert.rejects(run(async () => 1, { queueTimeoutMs: 80 }), { code: 'QUEUE_TIMEOUT' });
  assert.ok(Date.now() - t0 < 500);
});

test('memo: an in-flight entry is cleared when the work never settles, and the next call retries', async () => {
  const cache = new fetcher.Lru(10);
  const inflight = new Map();
  let calls = 0;
  const hung = fetcher.memo(cache, inflight, 'k', () => { calls++; return never(); }, { timeoutMs: 60 });
  assert.equal(inflight.size, 1);
  await assert.rejects(hung, { code: 'INFLIGHT_TIMEOUT' });
  assert.equal(inflight.size, 0, 'hung promise must not be kept');
  const v = await fetcher.memo(cache, inflight, 'k', async () => { calls++; return 'ok'; });
  assert.equal(v, 'ok');
  assert.equal(calls, 2);
  assert.equal(inflight.size, 0);
  /* rejection clears too */
  await assert.rejects(fetcher.memo(cache, inflight, 'e', async () => { throw new Error('boom'); }), /boom/);
  assert.equal(inflight.size, 0);
});

test('fetchBuffer: hard timeout even when the socket never answers and ignores abort', async () => {
  globalThis.fetch = () => never();
  const t0 = Date.now();
  await assert.rejects(fetcher.fetchBuffer('https://example.test/x', { timeoutMs: 100 }), { code: 'UPSTREAM_TIMEOUT' });
  assert.ok(Date.now() - t0 < 1500, `took ${Date.now() - t0} ms`);
});

test('framesPayload: cold start with a hung upstream settles within the caps timeout (ok:false), never hangs', async () => {
  globalThis.fetch = () => never();
  const t0 = Date.now();
  const body = await clouds.framesPayload(Date.parse('2026-11-12T14:05:00Z'));
  assert.equal(body.ok, false);
  assert.equal(body.stale, true);
  assert.equal(body.frames.length, 0);
  assert.ok(Date.now() - t0 < 2000, `took ${Date.now() - t0} ms`);
  /* the in-flight capabilities promise was cleared: a recovered upstream is used by the next call */
  globalThis.fetch = async () => resp(CAPS_XML('2026-11-12T13:00:00.000Z'), 'text/xml');
  const again = await clouds.framesPayload(Date.parse('2026-11-12T14:05:00Z'));
  assert.equal(again.ok, true);
});

test('framesPayload: honest freshness — real frame times, image_age_min, age_min, stale flag', async () => {
  const now = Date.parse('2026-11-12T14:05:00Z');
  globalThis.fetch = async () => resp(CAPS_XML('2026-11-12T13:00:00.000Z'), 'text/xml');
  const b = await clouds.framesPayload(now);
  assert.equal(b.ok, true);
  assert.equal(b.newest_frame_time, '2026-11-12T13:00:00.000Z');
  assert.equal(b.age_min, 65);
  assert.equal(b.stale, false);
  assert.equal(b.latest_image, '2026-11-12T13:00:00.000Z');
  assert.equal(b.frames.at(-1).image_age_min, 65);
  assert.equal(b.frames[0].image_age_min, 185); // oldest of the 2 h window
  assert.ok(b.frames.every((f) => typeof f.image_age_min === 'number' && f.tile_url && f.label_ar && f.id && f.time), 'iOS fields kept');
  assert.ok(b.upstream_checked_at);
});

test('framesPayload: upstream hangs after one good read — stale-while-revalidate, served at once, flagged stale', async () => {
  const t1 = Date.parse('2026-11-12T14:05:00Z');
  globalThis.fetch = async () => resp(CAPS_XML('2026-11-12T13:00:00.000Z'), 'text/xml');
  assert.equal((await clouds.framesPayload(t1)).stale, false);
  globalThis.fetch = () => never(); // EUMETView stops answering
  /* 1 h later the 4-min cache is long expired, the refresh hangs: we still answer immediately */
  const t2 = t1 + 60 * 60_000;
  const t0 = Date.now();
  const b = await clouds.framesPayload(t2);
  assert.ok(Date.now() - t0 < 100, 'served from the last good read without waiting');
  assert.equal(b.ok, true);
  assert.equal(b.newest_frame_time, '2026-11-12T13:00:00.000Z');
  assert.equal(b.age_min, 125);
  assert.equal(b.stale, true, 'older than 90 min is flagged');
  await sleep(900); // the background refresh timed out and cleared itself
  assert.match(String(clouds.capsStatus(t2).last_error), /TIMEOUT/i);
  /* beyond the stale horizon (6 h) there is nothing honest to show */
  const late = await clouds.framesPayload(t1 + 7 * 3600_000);
  assert.equal(late.ok, false);
});

test('pre-warm cannot starve a user request: capabilities fetch passes while the warm holds its slots', async () => {
  const now = Date.parse('2026-11-12T14:05:00Z');
  const png = require('pngjs').PNG;
  const blank = png.sync.write(new png({ width: 256, height: 256 }));
  let tiles = 0;
  globalThis.fetch = (url) => {
    if (/GetCapabilities/.test(String(url))) return Promise.resolve(resp(CAPS_XML('2026-11-12T13:00:00.000Z'), 'text/xml'));
    tiles++;
    return new Promise((r) => setTimeout(() => r(resp(blank, 'image/png')), 300)); // a slow EUMETView
  };
  await clouds.latestImageTime(now);
  const w = clouds.warm(now, { concurrency: 6, budgetMs: 900 }); // greedy warm, short budget
  await sleep(100);
  assert.ok(tiles >= 3, 'warm is busy');
  const t0 = Date.now();
  const r = await fetcher.fetchBuffer('https://view.eumetsat.int/geoserver/mtg_fd/ir105_hrfi/ows?service=WMS&request=GetCapabilities', { timeoutMs: 1000, label: 'clouds' });
  assert.equal(r.status, 200);
  assert.ok(Date.now() - t0 < 150, `user call waited ${Date.now() - t0} ms behind the warm`);
  const out = await w;
  assert.equal(out.stopped, 'budget', 'warm stops at its budget');
  assert.ok(out.done < out.tiles);
  /* only one warm at a time */
  const [a, b] = await Promise.all([clouds.warm(now, { budgetMs: 100 }), clouds.warm(now, { budgetMs: 100 })]);
  assert.ok(a.skipped === 'already_running' || b.skipped === 'already_running');
});

test('warm stops after repeated upstream failures instead of queueing the rest', async () => {
  const now = Date.parse('2026-11-12T14:05:00Z');
  globalThis.fetch = (url) => (/GetCapabilities/.test(String(url))
    ? Promise.resolve(resp(CAPS_XML('2026-11-12T13:00:00.000Z'), 'text/xml'))
    : Promise.reject(new Error('ECONNRESET')));
  const out = await clouds.warm(now, { concurrency: 2 });
  assert.equal(out.stopped, 'upstream_failing');
  assert.ok(out.done < 20, `done ${out.done}`);
});

test('HTTP: /clouds/tiles and /clouds/outlook answer within the route deadline when the upstream hangs (tiles 503 timeout, outlook cold 202 warming)', async () => {
  fetcher.setFetch(never); // every upstream call hangs for ever (worst case: ignores any timeout)
  const createWeatherRouter = require('../routes/weather');
  const app = express();
  app.use('/api', createWeatherRouter());
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    /* Tiles: 503 timeout. Outlook with nothing last-good yet (cold cell): 202 `warming` (the window keeps loading
     * in the background), never a bare 503 (production, 2026-11-13). */
    for (const [path, status, error] of [['/api/weather/clouds/tiles', 503, 'timeout'], ['/api/weather/clouds/outlook?lat=24.7&lng=46.7', 202, 'warming']]) {
      const t0 = Date.now();
      const r = await fetch(base + path);
      const j = await r.json();
      assert.equal(r.status, status, path);
      assert.equal(j.ok, false);
      assert.equal(j.error, error);
      assert.ok(Date.now() - t0 < 2500, `${path} took ${Date.now() - t0} ms`);
    }
  } finally {
    server.close();
  }
});
