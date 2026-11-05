'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { appConfig } = require('./app-config');

test('hiResImagery is on by default', () => {
  assert.deepEqual(appConfig({}), { version: 1, hiResImagery: { enabled: true } });
});

test('HIRES_IMAGERY_ENABLED=0/false/off is the kill switch', () => {
  for (const v of ['0', 'false', 'OFF', ' off ']) {
    assert.equal(appConfig({ HIRES_IMAGERY_ENABLED: v }).hiResImagery.enabled, false, v);
  }
});

test('any other value keeps it on', () => {
  for (const v of ['1', 'true', 'yes', '']) {
    assert.equal(appConfig({ HIRES_IMAGERY_ENABLED: v }).hiResImagery.enabled, true, v);
  }
});
