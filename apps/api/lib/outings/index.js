'use strict';

/**
 * Wires shared outings into an Express app and its HTTP server:
 * REST at /api/outings, WebSocket at /api/outings/live, a periodic sweep.
 * Without a database URL the routes answer 503 outings_unconfigured and the
 * rest of the API is unaffected. Web Push is on only when VAPID_* are set
 * (see lib/outings/push.js), native iOS push only when APNS_* are set (see
 * lib/outings/apns.js); `push: { config, sender }` / `apns: { config, sender }`
 * override them in tests. Turn-by-turn routing (/routing) is on only when
 * VALHALLA_ORIGIN + VALHALLA_GATEWAY_TOKEN are set (see lib/outings/routing.js). Both go through one notifyMembers(), so every event
 * that is pushed reaches browsers and iPhones with the same rules.
 */

const createOutingsRouter = require('../../routes/outings');
const { createOutingsService, OutingError } = require('./service');
const { createHub } = require('./hub');
const { attachOutingsSocket } = require('./ws');
const { createPttRelay } = require('./ptt');
const { createPttChannels } = require('./ptt-channels');
const { getOutingsPool, migrate } = require('./db');
const { createPushNotifier, pushConfigFromEnv } = require('./push');
const { createApnsNotifier, apnsConfigFromEnv, combineNotifiers } = require('./apns');

/* Event types that also go out as a push when emitted by anyone (e.g. SOS).
 * Notes are pushed by service.setNote itself. */
const PUSHED_EVENTS = new Set(['sos']);

function setupOutings({ pool = getOutingsPool(), config, limits, now, ptt: pttOpts = {}, push: pushOpts = {}, apns: apnsOpts = {}, routing = {}, autoMigrate = process.env.SARY_AUTO_MIGRATE !== '0' } = {}) {
  const hub = createHub();
  /* Members looking at the outing right now already get the in-app alert. */
  const viewers = (outingId) => {
    const away = hub.awayUsers(outingId);
    return new Set([...hub.onlineUsers(outingId)].filter((u) => !away.has(u)));
  };
  const push = createPushNotifier({ pool, config: pushOpts.config || pushConfigFromEnv(), sender: pushOpts.sender, viewers, maxPerUser: pushOpts.maxPerUser });
  const apns = createApnsNotifier({ pool, config: apnsOpts.config || apnsConfigFromEnv(), sender: apnsOpts.sender, viewers, maxPerUser: apnsOpts.maxPerUser });
  const fanout = combineNotifiers(push, apns);
  const service = pool ? createOutingsService({ pool, events: hub, push: fanout, webPush: push, config, ...(now ? { now } : {}) }) : null;
  if (service && fanout.enabled) {
    const emit = hub.emit;
    hub.emit = (outingId, event, opts) => {
      emit(outingId, event, opts);
      if (PUSHED_EVENTS.has(event?.type)) void service.announce(outingId, event.user_id, event);
    };
  }
  /* «قناة الطلعة»: live walkie-talkie relay on the same socket (relay only, nothing stored),
   * with its channels «ترددات» (five public, plus the leader's private ones). */
  const pttChannels = service
    ? createPttChannels({
        q: (text, params) => pool.query(text, params).then((r) => r.rows),
        tx: async (fn) => {
          const client = await pool.connect();
          try {
            await client.query('BEGIN');
            const out = await fn((text, params) => client.query(text, params).then((r) => r.rows));
            await client.query('COMMIT');
            return out;
          } catch (e) {
            await client.query('ROLLBACK').catch(() => {});
            throw e;
          } finally {
            client.release();
          }
        },
        err: (code, status) => new OutingError(code, status),
        requireMember: (...a) => service.requireMember(...a),
        cfg: { maxMembers: config?.maxMembers },
        push: fanout,
      })
    : null;
  service?.setPttChannels(pttChannels);
  const ptt = service ? createPttRelay({ hub, service, apns, channels: pttChannels, ...(now ? { now } : {}), options: pttOpts }) : null;
  const router = createOutingsRouter({ service, hub, push, apns, pttChannels, limits, routing });
  let sweepTimer = null;
  let timerSweep = null;
  let silenceSweep = null;
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
    apns,
    ptt,
    router,
    ready,
    /** Live-socket lifetimes and close codes, plus the walkie-talkie relay's counters (numbers only). */
    socketStats() {
      return socket ? { ...socket.stats(), ptt: ptt ? { ...ptt.stats } : null } : null;
    },
    attach(server) {
      if (!service) return;
      socket = attachOutingsSocket(server, { service, hub, ptt });
      sweepTimer = setInterval(() => {
        service.sweep().catch((e) => console.warn('[outings] sweep:', e.code || e.message));
      }, 10 * 60_000);
      sweepTimer.unref?.();
      /* Return timers: armed + past due → overdue, snapshot, pushes. Every minute. */
      timerSweep = setInterval(() => {
        service.sweepReturnTimers().catch((e) => console.warn('[outings] timer sweep:', e.code || e.message));
      }, 60_000);
      timerSweep.unref?.();
      /* «انقطع الإرسال»: sharing on, no fix for 10 / 30 min → alert the others once each. Every minute. */
      silenceSweep = setInterval(() => {
        service.sweepSilence().catch((e) => console.warn('[outings] silence sweep:', e.code || e.message));
      }, 60_000);
      silenceSweep.unref?.();
    },
    close() {
      ptt?.close(); // release any held floor while sockets can still hear it
      clearInterval(sweepTimer);
      clearInterval(timerSweep);
      clearInterval(silenceSweep);
      socket?.close();
      apns.close();
    },
  };
}

module.exports = { setupOutings };
