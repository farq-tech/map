'use strict';

/**
 * Wires shared outings into an Express app and its HTTP server:
 * REST at /api/outings, WebSocket at /api/outings/live, a periodic sweep.
 * Without a database URL the routes answer 503 outings_unconfigured and the
 * rest of the API is unaffected. Web Push is on only when VAPID_* are set
 * (see lib/outings/push.js); `push: { config, sender }` overrides both in tests.
 */

const createOutingsRouter = require('../../routes/outings');
const { createOutingsService } = require('./service');
const { createHub } = require('./hub');
const { attachOutingsSocket } = require('./ws');
const { getOutingsPool, migrate } = require('./db');
const { createPushNotifier, pushConfigFromEnv } = require('./push');

/* Event types that also go out as a push when emitted by anyone (e.g. SOS).
 * Notes are pushed by service.setNote itself. */
const PUSHED_EVENTS = new Set(['sos']);

function setupOutings({ pool = getOutingsPool(), config, limits, push: pushOpts = {}, autoMigrate = process.env.SARY_AUTO_MIGRATE !== '0' } = {}) {
  const hub = createHub();
  /* Members looking at the outing right now already get the in-app alert. */
  const viewers = (outingId) => {
    const away = hub.awayUsers(outingId);
    return new Set([...hub.onlineUsers(outingId)].filter((u) => !away.has(u)));
  };
  const push = createPushNotifier({ pool, config: pushOpts.config || pushConfigFromEnv(), sender: pushOpts.sender, viewers, maxPerUser: pushOpts.maxPerUser });
  const service = pool ? createOutingsService({ pool, events: hub, push, config }) : null;
  if (service && push.enabled) {
    const emit = hub.emit;
    hub.emit = (outingId, event, opts) => {
      emit(outingId, event, opts);
      if (PUSHED_EVENTS.has(event?.type)) void service.announce(outingId, event.user_id, event);
    };
  }
  const router = createOutingsRouter({ service, hub, push, limits });
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
    push,
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
