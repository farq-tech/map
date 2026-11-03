'use strict';

/**
 * Wires shared outings into an Express app and its HTTP server:
 * REST at /api/outings, WebSocket at /api/outings/live, a periodic sweep.
 * Without a database URL the routes answer 503 outings_unconfigured and the
 * rest of the API is unaffected.
 */

const createOutingsRouter = require('../../routes/outings');
const { createOutingsService } = require('./service');
const { createHub } = require('./hub');
const { attachOutingsSocket } = require('./ws');
const { getOutingsPool, migrate } = require('./db');

function setupOutings({ pool = getOutingsPool(), config, limits, autoMigrate = process.env.SARY_AUTO_MIGRATE !== '0' } = {}) {
  const hub = createHub();
  const service = pool ? createOutingsService({ pool, events: hub, config }) : null;
  const router = createOutingsRouter({ service, hub, limits });
  let sweepTimer = null;
  let socket = null;
  const ready = service && autoMigrate
    ? migrate(pool, { log: console.log }).catch((e) => {
        console.warn('[outings] migration failed:', e.code || e.message);
      })
    : Promise.resolve();

  return {
    hub,
    service,
    router,
    ready,
    attach(server) {
      if (!service) return;
      socket = attachOutingsSocket(server, { service, hub });
      sweepTimer = setInterval(() => {
        service.sweep().catch((e) => console.warn('[outings] sweep:', e.code || e.message));
      }, 10 * 60_000);
      sweepTimer.unref?.();
    },
    close() {
      clearInterval(sweepTimer);
      socket?.close();
    },
  };
}

module.exports = { setupOutings };
