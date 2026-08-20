'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  MIN_AREA_COMPARISONS,
  MIN_VERDICT_MARGIN_PCT,
  aggregateByKey,
  emptyStats,
  statsToProperties,
} = require('./opportunity-aggregate');

const stats = (wins, comparisons) => ({ ...emptyStats(), wins, comparisons });

test('a big enough sample with a clear lead is a verdict, and says how clear', () => {
  const p = statsToProperties(stats({ jahez: 60, mrsool: 20 }, 80));
  assert.equal(p.enough_for_app_verdict, true);
  assert.equal(p.app_verdict_too_close, false);
  assert.equal(p.cheapest_app, 'jahez');
  assert.equal(p.cheapest_app_wins, 60);
  assert.equal(p.cheapest_app_share, 75);
  assert.equal(p.cheapest_app_margin, 50);
  assert.equal(p.runner_up_app, 'mrsool');
});

test('an exact tie is never painted as a win — الجنادرية, jahez 27 to hungerstation 27', () => {
  const p = statsToProperties(stats({ jahez: 27, hungerstation: 27 }, 54));
  assert.equal(p.cheapest_app, null);
  assert.equal(p.enough_for_app_verdict, false);
  assert.equal(p.app_verdict_too_close, true, 'too close is not the same as no data');
});

test('a one-comparison lead over hundreds is too close to call — الأندلس, 97 to 96', () => {
  const p = statsToProperties(stats({ jahez: 97, mrsool: 96 }, 193));
  assert.equal(p.cheapest_app, null);
  assert.equal(p.app_verdict_too_close, true);
});

test('too few comparisons is silence, not closeness', () => {
  const p = statsToProperties(stats({ jahez: 4 }, 4));
  assert.ok(4 < MIN_AREA_COMPARISONS);
  assert.equal(p.cheapest_app, null);
  assert.equal(p.enough_for_app_verdict, false);
  assert.equal(p.app_verdict_too_close, false);
});

test('the margin threshold is the boundary it claims to be', () => {
  const below = statsToProperties(stats({ a: 52, b: 48 }, 100));
  const at = statsToProperties(stats({ a: 100 - (100 - MIN_VERDICT_MARGIN_PCT) / 2, b: (100 - MIN_VERDICT_MARGIN_PCT) / 2 }, 100));
  assert.equal(below.cheapest_app, null, '4 points is not a verdict');
  assert.equal(at.cheapest_app, 'a');
  assert.ok(at.cheapest_app_margin >= MIN_VERDICT_MARGIN_PCT);
});

test('an empty area says nothing at all', () => {
  const p = statsToProperties(emptyStats());
  assert.deepEqual(
    { app: p.cheapest_app, close: p.app_verdict_too_close, max: p.max_gap, top: p.top_place_id },
    { app: null, close: false, max: null, top: null },
  );
});

test('aggregateByKey folds by the key it is given and skips what it cannot place', () => {
  const f = (key, gap, wins) => ({ properties: { district_id: key, has_difference: gap > 0, gap, place_id: `p${gap}`, wins } });
  const groups = aggregateByKey(
    [f('a', 10, { jahez: 2 }), f('a', 30, { jahez: 1 }), f(null, 99, { jahez: 9 }), f('b', 0, null)],
    (x) => x.properties.district_id,
  );
  assert.deepEqual([...groups.keys()], ['a', 'b']);
  assert.equal(groups.get('a').opportunities, 2);
  assert.equal(groups.get('a').max_gap, 30);
  assert.equal(groups.get('a').comparisons, 3);
  assert.equal(groups.get('b').opportunities, 0);
});
