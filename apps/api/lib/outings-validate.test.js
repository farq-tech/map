'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const v = require('./outings/validate');

test('names are trimmed, capped and stripped of bidi overrides', () => {
  assert.equal(v.displayName('  أبو   فهد  '), 'أبو فهد');
  assert.equal(v.displayName('‮evil'), 'evil');
  assert.equal(v.displayName('   '), null);
  assert.equal(v.displayName(42), null);
  assert.equal([...v.outingName('ط'.repeat(200))].length, v.OUTING_NAME_MAX);
});

test('avatar accepts only small image data URLs', () => {
  assert.deepEqual(v.avatar(null), { ok: true, value: null });
  assert.equal(v.avatar('data:image/jpeg;base64,AAAA').ok, true);
  assert.equal(v.avatar('data:text/html;base64,AAAA').ok, false);
  assert.equal(v.avatar('https://example.com/x.png').ok, false);
  assert.equal(v.avatar('data:image/png;base64,' + 'A'.repeat(v.AVATAR_MAX_CHARS)).ok, false);
});

test('a fix is refused when it cannot honestly place a person', () => {
  const now = 1_700_000_000_000;
  assert.equal(v.fix({ lat: 24.7, lng: 46.6 }, now).ok, true);
  assert.equal(v.fix({ lat: 0, lng: 0 }, now).reason, 'invalid_coordinates');
  assert.equal(v.fix({ lat: 91, lng: 46 }, now).reason, 'invalid_coordinates');
  assert.equal(v.fix({ lat: '24.7', lng: 46.6 }, now).reason, 'invalid_coordinates');
  assert.equal(v.fix({ lat: 24.7, lng: 46.6, accuracy: 5000 }, now).reason, 'inaccurate');
  assert.equal(v.fix({ lat: 24.7, lng: 46.6, age_ms: 120_000 }, now).reason, 'stale');
  assert.equal(v.fix({ lat: 24.7, lng: 46.6, speed: 400 }, now).reason, 'implausible_speed');
});

test('recorded_at comes from our clock minus the device-reported age', () => {
  const now = 1_700_000_000_000;
  const r = v.fix({ lat: 24.71234567, lng: 46.67, age_ms: 2500, heading: -90, speed: 12.345 }, now);
  assert.equal(r.ok, true);
  assert.equal(r.value.recorded_at.getTime(), now - 2500);
  assert.equal(r.value.lat, 24.712346);
  assert.equal(r.value.heading, 270);
  assert.equal(r.value.speed, 12.3);
});

test('secrets are 256-bit base64url and stored as digests', () => {
  const a = v.newSecret();
  assert.equal(v.isSecretShaped(a), true);
  assert.notEqual(a, v.newSecret());
  assert.equal(v.digest(a).length, 32);
  assert.equal(v.isSecretShaped('short'), false);
});
