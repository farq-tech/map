'use strict';

/**
 * Remote switches the native app reads at launch and on foreground
 * (GET /api/outdoor/app-config). Additive and public: no identity, no position.
 *
 * hiResImagery — the iOS «صور عالية الوضوح» over-zoom enhancement
 * (apps/ios/SaryAlbarq/docs/AI-SATELLITE.md). Kill switch: set the env var
 * HIRES_IMAGERY_ENABLED=0 on the API service and redeploy/restart; every
 * client turns it off at its next fetch. Unset or any other value = on.
 * A client that cannot reach this endpoint keeps the last value it saw.
 */
function appConfig(env = process.env) {
  const flag = String(env.HIRES_IMAGERY_ENABLED ?? '').trim().toLowerCase();
  const off = flag === '0' || flag === 'false' || flag === 'off';
  return {
    version: 1,
    hiResImagery: { enabled: !off },
  };
}

module.exports = { appConfig };
