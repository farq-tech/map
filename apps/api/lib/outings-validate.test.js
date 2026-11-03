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

test('phone numbers are normalised to E.164, Saudi forms included', () => {
  assert.equal(v.phone('0551234567'), '+966551234567');
  assert.equal(v.phone('055 123 4567'), '+966551234567');
  assert.equal(v.phone('٠٥٥١٢٣٤٥٦٧'), '+966551234567');
  assert.equal(v.phone('551234567'), '+966551234567');
  assert.equal(v.phone('00966551234567'), '+966551234567');
  assert.equal(v.phone('+44 20 7946 0958'), '+442079460958');
  assert.equal(v.phone(''), null);
  assert.equal(v.phone('call me'), undefined);
  assert.equal(v.phone('123'), undefined);
});

test('battery and rally inputs', () => {
  assert.deepEqual(v.battery({ level: 0.123, charging: false }), { level: 0.12, charging: false });
  assert.equal(v.battery({ level: 1.2, charging: false }), null);
  assert.equal(v.battery({ level: 0.5 }), null, 'charging state is required, never assumed');
  assert.equal(v.battery(undefined), null);
  assert.deepEqual(v.rally({ lat: 24.1234567, lng: 46.7654321, label: ' عند‮ الشجرة ' }), { lat: 24.123457, lng: 46.765432, label: 'عند الشجرة' });
  assert.equal(v.rally({ lat: 0, lng: 0 }), null);
  assert.equal(v.rally({ lat: 'x', lng: 1 }), null);
  assert.equal(v.fix({ lat: 24, lng: 46, age_ms: 5 * 60_000 }).reason, 'stale', 'a live fix stays strict');
  assert.equal(v.fix({ lat: 24, lng: 46, age_ms: 5 * 60_000 }, Date.now(), { maxAgeMs: v.SOS_FIX_MAX_AGE_MS }).ok, true);
});
