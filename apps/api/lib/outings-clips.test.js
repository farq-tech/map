'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createClipStore, sniffAudio, parseDurationMs, CLIP_TTL_MS } = require('./outings/clips');
const v = require('./outings/validate');

const mp4 = () => Buffer.concat([Buffer.from([0, 0, 0, 0x18]), Buffer.from('ftypM4A '), Buffer.alloc(400, 1)]);
const webm = () => Buffer.concat([Buffer.from([0x1a, 0x45, 0xdf, 0xa3]), Buffer.alloc(400, 2)]);

test('audio is identified by its bytes, not by what the client claims', () => {
  assert.equal(sniffAudio(mp4()), 'audio/mp4');
  assert.equal(sniffAudio(webm()), 'audio/webm');
  assert.equal(sniffAudio(Buffer.concat([Buffer.from('OggS'), Buffer.alloc(20)])), 'audio/ogg');
  assert.equal(sniffAudio(Buffer.from('<html><script>alert(1)</script></html>')), null);
  assert.equal(sniffAudio(Buffer.alloc(4)), null);
});

test('clip length: 0.3–15 s, a little overshoot tolerated and clamped', () => {
  assert.equal(parseDurationMs('4200'), 4200);
  assert.equal(parseDurationMs('15600'), 15_000);
  assert.equal(parseDurationMs('17000'), null);
  assert.equal(parseDurationMs('100'), null);
  assert.equal(parseDurationMs(undefined), null);
});

test('clips expire after 10 minutes and are scoped to their outing', () => {
  let t = 1_000_000;
  const store = createClipStore({ now: () => t });
  const meta = store.put('o1', 'u1', { buf: mp4(), mime: 'audio/mp4', durationMs: 3000 });
  assert.match(meta.id, /^[0-9a-f]{32}$/);
  assert.equal(meta.url, `/api/outings/o1/clips/${meta.id}`);
  assert.equal(new Date(meta.expires_at) - new Date(meta.at), CLIP_TTL_MS);
  assert.ok(store.get('o1', meta.id));
  assert.equal(store.get('o2', meta.id), null, 'another outing cannot fetch it by id');
  assert.equal(store.list('o1').length, 1);
  t += CLIP_TTL_MS + 1;
  assert.equal(store.get('o1', meta.id), null, 'gone after its ten minutes');
  assert.equal(store.list('o1').length, 0);
  assert.equal(store.stats().bytes, 0, 'and its bytes are released');
});

test('a sender leaving takes their clips; the store never grows without bound', () => {
  const store = createClipStore({ maxTotalBytes: 2_000, perOuting: 3 });
  const a = store.put('o', 'a', { buf: mp4(), mime: 'audio/mp4', durationMs: 1000 });
  store.put('o', 'b', { buf: mp4(), mime: 'audio/mp4', durationMs: 1000 });
  store.dropUser('o', 'a');
  assert.equal(store.get('o', a.id), null);
  for (let i = 0; i < 10; i += 1) store.put('o', 'b', { buf: mp4(), mime: 'audio/mp4', durationMs: 1000 });
  assert.ok(store.list('o').length <= 3);
  assert.ok(store.stats().bytes <= 2_000);
  store.dropOuting('o');
  assert.equal(store.stats().bytes, 0);
});

test('trip summary: three plausible totals, nothing else', () => {
  assert.deepEqual(v.tripSummary({ distance_m: 42_300.4, duration_s: 7200, moving_s: 5400 }).value, { distance_m: 42_300, duration_s: 7200, moving_s: 5400 });
  assert.equal(v.tripSummary({ distance_m: 1, duration_s: 10, moving_s: 10, points: [[46, 24]] }).ok, false, 'no room for a point');
  assert.equal(v.tripSummary({ distance_m: -1, duration_s: 10 }).ok, false);
  assert.equal(v.tripSummary({ distance_m: 10, duration_s: 10, moving_s: 20 }).ok, false, 'moving longer than the trip');
  assert.equal(v.tripSummary({ distance_m: 500_000, duration_s: 3600, moving_s: 3600 }).reason, 'implausible_summary', '500 km in an hour');
  assert.equal(v.tripSummary({ distance_m: 1000, duration_s: 9000, moving_s: 600 }, { spanS: 3600 }).reason, 'implausible_summary', 'longer than the outing ran');
  assert.equal(v.tripSummary({ distance_m: 0, duration_s: 0, moving_s: 0 }).ok, true, 'a parked phone shares zeros honestly');
});
