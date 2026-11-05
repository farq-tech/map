'use strict';

/**
 * /api/outings — shared outings (طلعات مشتركة).
 *
 * Identity: POST /me issues an opaque device token (stored hashed). Every other
 * call carries `Authorization: Bearer <token>`. Membership is checked on the
 * server for every read and write — see lib/outings/service.js.
 *
 * Invite tokens travel in request bodies, never in a path or query string, so
 * they do not land in access logs. The share link carries them in the URL
 * fragment (/outings/join#<token>), which browsers never send to a server.
 */

const express = require('express');
const { asyncHandler } = require('../lib/async-handler');
const { OutingError } = require('../lib/outings/service');
const { createRateLimiter } = require('../lib/outings/rate-limit');
const { battery } = require('../lib/outings/validate');
const { CLIP_MAX_BYTES } = require('../lib/outings/clips');
const { parseSubscription } = require('../lib/outings/push');
const { createRoutingRouter } = require('../lib/outings/routing');
const { catalog: groupAudioCatalog } = require('../lib/outings/group-audio-catalog');

function clientKey(req) {
  const fwd = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
  return fwd || req.socket.remoteAddress || 'unknown';
}

function createOutingsRouter({ service, hub, push, apns, pttChannels = null, limits = {}, routing = {} }) {
  const router = express.Router();
  /* Small bodies everywhere, except a waypoint (≤150 KB photo) and a plan (≤5000-point route). */
  const smallJson = express.json({ limit: '48kb' });
  const bigJson = express.json({ limit: '400kb' });
  const BIG_BODY = /^\/[^/]+\/(waypoints|plan)$/;
  router.use((req, res, next) => ((req.method === 'POST' || req.method === 'PUT') && BIG_BODY.test(req.path) ? bigJson : smallJson)(req, res, next));
  router.use((_req, res, next) => {
    /* Positions and member lists are personal: never cache them anywhere. */
    res.set('Cache-Control', 'no-store');
    next();
  });

  /* Turn-by-turn over Farq Valhalla. Status is public and answers even without a database. */
  router.use('/routing', createRoutingRouter({ authenticate: service ? service.authenticate : null, ...routing }));

  if (!service) {
    router.use((_req, res) => res.status(503).json({ ok: false, error: 'outings_unconfigured' }));
    return router;
  }

  const identityLimit = createRateLimiter({ limit: limits.identityPerHour ?? 10, windowMs: 60 * 60_000 });
  const inviteLimit = createRateLimiter({ limit: limits.invitePer10Min ?? 30, windowMs: 10 * 60_000 });
  const writeLimit = createRateLimiter({ limit: 120, windowMs: 60_000 });
  const diagLimit = createRateLimiter({ limit: limits.diagnosticsPerHour ?? 6, windowMs: 60 * 60_000 });
  /* Recovery codes carry 100 bits, so guessing is hopeless anyway; this keeps it that way cheaply. */
  const recoverLimit = createRateLimiter({ limit: limits.recoverPer15Min ?? 5, windowMs: 15 * 60_000 });
  const recoveryCodeLimit = createRateLimiter({ limit: 10, windowMs: 60 * 60_000 });
  /* Account deletion: one is enough; a handful per hour per address stops a loop or a scripted sweep. */
  const deleteLimit = createRateLimiter({ limit: limits.deletePerHour ?? 5, windowMs: 60 * 60_000 });
  /* Push-to-talk: a few clips a minute is a conversation; more is a flood. */
  const clipLimit = createRateLimiter({ limit: limits.clipsPer5Min ?? 20, windowMs: 5 * 60_000 });
  const clipFetchLimit = createRateLimiter({ limit: limits.clipFetchesPerMin ?? 120, windowMs: 60_000 });
  /* Return-timer watch link: public, so per address. A watcher polls every 30 s. */
  const watchLimit = createRateLimiter({ limit: limits.watchPer10Min ?? 60, windowMs: 10 * 60_000 });
  const watchSubLimit = createRateLimiter({ limit: limits.watchSubscribePer10Min ?? 10, windowMs: 10 * 60_000 });
  const timerLimit = createRateLimiter({ limit: limits.timerPer10Min ?? 20, windowMs: 10 * 60_000 });
  const waypointLimit = createRateLimiter({ limit: limits.waypointsPer10Min ?? 30, windowMs: 10 * 60_000 });
  /* A PTT token per channel join; a few an hour is plenty. */
  const pttTokenLimit = createRateLimiter({ limit: limits.pttTokensPer10Min ?? 20, windowMs: 10 * 60_000 });
  /* Raw audio bytes, capped. Only this route reads a body that is not JSON. */
  const rawAudio = express.raw({ type: ['audio/*', 'application/octet-stream'], limit: CLIP_MAX_BYTES });

  const auth = asyncHandler(async (req, res, next) => {
    const m = /^Bearer\s+(\S+)$/i.exec(String(req.headers.authorization || ''));
    const user = m ? await service.authenticate(m[1]) : null;
    if (!user) return res.status(401).json({ ok: false, error: 'unauthorized' });
    req.user = user;
    next();
  });

  router.post('/me', asyncHandler(async (req, res) => {
    if (!identityLimit(clientKey(req))) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const { user, token } = await service.createUser(req.body || {});
    res.status(201).json({ ok: true, user, token });
  }));

  router.get('/me', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, user: req.user, recovery: await service.recoveryStatus(req.user) });
  }));

  /* «احفظ رمز الاسترجاع»: a new code, shown once. Replaces any earlier one. */
  router.post('/me/recovery', auth, asyncHandler(async (req, res) => {
    if (!recoveryCodeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const r = await service.createRecoveryCode(req.user);
    res.status(201).json({ ok: true, recovery: r });
  }));

  /* A new device redeems the code (in the body, never the URL) for a new token. */
  router.post('/me/recover', asyncHandler(async (req, res) => {
    if (!recoverLimit(clientKey(req))) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const { user, token } = await service.recover(req.body?.code);
    res.json({ ok: true, user, token });
  }));

  router.patch('/me', auth, asyncHandler(async (req, res) => {
    const user = await service.updateProfile(req.user, req.body || {});
    res.json({ ok: true, user });
  }));

  /* «احذف حسابي» (App Store 5.1.1(v)): leaves every outing with the normal leave rules
   * (owner hand-over / end), then hard-deletes the identity and everything only it owns.
   * The token answers 401 from then on — so does a repeat. See service.deleteAccount. */
  router.delete('/me', asyncHandler(async (req, res, next) => {
    if (!deleteLimit(clientKey(req))) return res.status(429).json({ ok: false, error: 'rate_limited' });
    next();
  }), auth, asyncHandler(async (req, res) => {
    await service.deleteAccount(req.user);
    res.json({ ok: true });
  }));

  /* Web Push. Off (enabled:false) unless the API has VAPID keys. */
  router.get('/push/config', (_req, res) => {
    res.json({ ok: true, ...(push ? push.publicConfig() : { enabled: false, public_key: null }) });
  });

  router.post('/push/subscribe', auth, asyncHandler(async (req, res) => {
    if (!push?.enabled) return res.status(503).json({ ok: false, error: 'push_disabled' });
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const r = await push.subscribe(req.user, req.body?.subscription);
    if (!r.ok) return res.status(400).json(r);
    res.status(201).json({ ok: true });
  }));

  router.delete('/push/subscribe', auth, asyncHandler(async (req, res) => {
    if (!push) return res.json({ ok: true, removed: 0 });
    res.json({ ok: true, ...(await push.unsubscribe(req.user, req.body?.endpoint)) });
  }));

  /* Native iOS push (APNs). Off (enabled:false, 503 apns_disabled) unless the API has APNS_*.
   * Body: { token: <hex device token>, environment: 'sandbox'|'production', bundle_id?: <must match> }. */
  /* «رسائل المحادثة» notifications on/off, per person (default on). */
  router.get('/push/chat', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.chatPrefs(req.user)) });
  }));

  router.put('/push/chat', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.setChatPrefs(req.user, req.body || {})) });
  }));

  router.get('/push/apns', (_req, res) => {
    res.json({ ok: true, ...(apns ? apns.publicConfig() : { enabled: false, bundle_id: null }) });
  });

  router.post('/push/apns', auth, asyncHandler(async (req, res) => {
    if (!apns?.enabled) return res.status(503).json({ ok: false, error: 'apns_disabled' });
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const r = await apns.register(req.user, req.body || {});
    if (!r.ok) return res.status(400).json(r);
    res.status(201).json({ ok: true });
  }));

  router.delete('/push/apns', auth, asyncHandler(async (req, res) => {
    if (!apns) return res.json({ ok: true, removed: 0 });
    res.json({ ok: true, ...(await apns.unregister(req.user, req.body?.token)) });
  }));

  /* «مؤقت الرجوع» watch link — no identity: the capability token rides in the body, never a URL.
   * Registered before /:id/* so /watch/status is not read as an outing id. */
  router.post('/watch/status', asyncHandler(async (req, res) => {
    if (!watchLimit(clientKey(req))) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.json({ ok: true, ...(await service.watchStatus(req.body?.token)) });
  }));

  router.post('/watch/subscribe', asyncHandler(async (req, res) => {
    if (!watchSubLimit(clientKey(req))) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const r = await service.watchSubscribe(req.body?.token, req.body?.subscription, (raw) => parseSubscription(raw));
    res.status(201).json({ ok: true, ...r });
  }));

  /* Anonymous works (build 9–11, the web join page); with a token the answer
   * also says whether a used personal invite is the viewer's own. */
  router.post('/invites/preview', asyncHandler(async (req, res) => {
    if (!inviteLimit(clientKey(req))) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const m = /^Bearer\s+(\S+)$/i.exec(String(req.headers.authorization || ''));
    const viewer = m ? await service.authenticate(m[1]) : null;
    const invite = await service.previewInvite(req.body?.token, viewer);
    res.json({ ok: true, invite });
  }));

  router.post('/invites/join', auth, asyncHandler(async (req, res) => {
    if (!inviteLimit(clientKey(req))) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const r = await service.joinByInvite(req.user, req.body?.token);
    res.json({ ok: true, ...r });
  }));

  router.get('/', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.listOutings(req.user)) });
  }));

  router.post('/', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const r = await service.createOuting(req.user, req.body || {});
    res.status(201).json({ ok: true, ...r });
  }));

  router.get('/:id', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.getOuting(req.user, req.params.id)) });
  }));

  /* HTTP fallback for a network where WebSockets do not get through. */
  router.get('/:id/live', auth, asyncHandler(async (req, res) => {
    const snapshot = await service.getOuting(req.user, req.params.id);
    hub?.touchPoll(req.params.id, req.user.id);
    res.json({ ok: true, ...snapshot });
  }));

  /* HTTP fallback heartbeat: "still here", no coordinates. */
  router.post('/:id/heartbeat', auth, asyncHandler(async (req, res) => {
    await service.requireMember(req.user, req.params.id);
    hub?.heartbeat(req.params.id, req.user.id, req.body?.gps, battery(req.body?.battery));
    res.json({ ok: true });
  }));

  router.post('/:id/positions', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const r = await service.recordPosition(req.user, req.params.id, req.body?.fix);
    if (r.ok) hub?.touchPoll(req.params.id, req.user.id);
    res.status(r.ok ? 200 : r.reason === 'not_a_member' ? 404 : 409).json(r.ok ? { ok: true } : { ok: false, error: r.reason });
  }));

  /* Opt-in field-test aggregates. Numbers only — see lib/outings/diagnostics.js. */
  router.post('/:id/diagnostics', auth, asyncHandler(async (req, res) => {
    if (!diagLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    await service.recordDiagnostics(req.user, req.params.id, req.body?.report);
    res.status(201).json({ ok: true });
  }));

  router.post('/:id/status', auth, asyncHandler(async (req, res) => {
    const outing = await service.setStatus(req.user, req.params.id, req.body?.action);
    res.json({ ok: true, outing });
  }));

  router.post('/:id/invites', auth, asyncHandler(async (req, res) => {
    const invite = await service.rotateInvite(req.user, req.params.id, req.body || {});
    res.status(201).json({ ok: true, invite });
  }));

  /* «دعوة شخصية»: one single-use link per person — lib/outings/invites.js. */
  router.get('/:id/invites/personal', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.listPersonal(req.user, req.params.id)) });
  }));

  router.post('/:id/invites/personal', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.status(201).json({ ok: true, ...(await service.createPersonal(req.user, req.params.id, req.body || {})) });
  }));

  router.post('/:id/invites/personal/:inviteId/resend', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.status(201).json({ ok: true, ...(await service.resendPersonal(req.user, req.params.id, req.params.inviteId, req.body || {})) });
  }));

  router.delete('/:id/invites/personal/:inviteId', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.revokePersonal(req.user, req.params.id, req.params.inviteId)) });
  }));

  /* «الرابط المفتوح» on/off. Off revokes the open link; personal invites stay. */
  router.patch('/:id/invites/settings', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.setOpenLinks(req.user, req.params.id, req.body?.open_links)) });
  }));

  router.delete('/:id/invites', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.revokeInvites(req.user, req.params.id)) });
  }));

  router.patch('/:id/me', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.setSharing(req.user, req.params.id, req.body?.sharing)) });
  }));

  router.post('/:id/note', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.setNote(req.user, req.params.id, req.body?.text)) });
  }));

  /* SOS: raise/refresh with my last real fix (optional), cancel with «أنا بخير». */
  router.post('/:id/sos', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.raiseSos(req.user, req.params.id, req.body?.fix ?? null)) });
  }));

  router.delete('/:id/sos', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.cancelSos(req.user, req.params.id)) });
  }));

  /* Rally point: owner only. PUT drops or moves it, DELETE clears it. */
  router.put('/:id/rally', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.json({ ok: true, ...(await service.setRally(req.user, req.params.id, req.body || {})) });
  }));

  router.delete('/:id/rally', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.setRally(req.user, req.params.id, null)) });
  }));

  /* Voice clip upload: body is the recording itself; its length (ms) rides in a header. */
  router.post('/:id/clips', auth, asyncHandler(async (req, res, next) => {
    if (!clipLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    next();
  }), rawAudio, asyncHandler(async (req, res) => {
    const clip = await service.addClip(req.user, req.params.id, {
      buf: Buffer.isBuffer(req.body) ? req.body : null,
      durationMs: req.headers['x-clip-duration-ms'],
    });
    res.status(201).json({ ok: true, clip });
  }));

  router.get('/:id/clips/:clipId', auth, asyncHandler(async (req, res) => {
    if (!clipFetchLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const { meta, buf } = await service.getClip(req.user, req.params.id, req.params.clipId);
    res.set('Content-Type', meta.mime);
    res.set('X-Content-Type-Options', 'nosniff');
    res.set('Content-Disposition', 'inline');
    res.set('Expires', new Date(meta.expires_at).toUTCString());
    res.send(buf);
  }));

  /* «قناة الطلعة» Push to Talk: this device's ephemeral channel token for this outing.
   * Body { token: <hex>, environment: 'sandbox'|'production' }. DELETE on leave / «اكتم القناة»
   * (no token in the body = every token of mine for this outing). */
  router.post('/:id/ptt/token', auth, asyncHandler(async (req, res) => {
    if (!apns?.enabled) return res.status(503).json({ ok: false, error: 'apns_disabled' });
    if (!writeLimit(req.user.id) || !pttTokenLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const m = await service.requireMember(req.user, req.params.id, { fresh: true });
    if (m.outing_status === 'ended') return res.status(409).json({ ok: false, error: 'outing_ended' });
    const r = await apns.registerPtt(req.user, req.params.id, req.body || {});
    if (!r.ok) return res.status(400).json(r);
    res.status(201).json({ ok: true });
  }));

  router.delete('/:id/ptt/token', auth, asyncHandler(async (req, res) => {
    if (!apns?.registerPtt) return res.json({ ok: true, removed: 0 });
    await service.requireMember(req.user, req.params.id);
    res.json({ ok: true, ...(await apns.unregisterPtt(req.user, req.params.id, req.body?.token)) });
  }));

  /* «ترددات»: the walkie-talkie's channels. GET lists the five public ones and the private ones
   * I am invited to (who is listening on each, who is talking). POST / PATCH / DELETE are the
   * trip leader's: open a «تردد خاص» { name, members }, rename it / add / remove members, close
   * it. A removed member is taken off the air at once; see lib/outings/ptt-channels.js. */
  if (pttChannels) {
    const channelLimit = createRateLimiter({ limit: limits.pttChannelWritesPer10Min ?? 60, windowMs: 10 * 60_000 });
    const writeOk = (req, res) => {
      if (writeLimit(req.user.id) && channelLimit(req.user.id)) return true;
      res.status(429).json({ ok: false, error: 'rate_limited' });
      return false;
    };
    router.get('/:id/ptt/channels', auth, asyncHandler(async (req, res) => {
      res.json({ ok: true, ...(await pttChannels.api.listPttChannels(req.user, req.params.id)) });
    }));
    router.post('/:id/ptt/channels', auth, asyncHandler(async (req, res) => {
      if (!writeOk(req, res)) return;
      res.status(201).json({ ok: true, ...(await pttChannels.api.createPttChannel(req.user, req.params.id, req.body || {})) });
    }));
    router.patch('/:id/ptt/channels/:channelId', auth, asyncHandler(async (req, res) => {
      if (!writeOk(req, res)) return;
      res.json({ ok: true, ...(await pttChannels.api.updatePttChannel(req.user, req.params.id, req.params.channelId, req.body || {})) });
    }));
    router.delete('/:id/ptt/channels/:channelId', auth, asyncHandler(async (req, res) => {
      if (!writeOk(req, res)) return;
      res.json({ ok: true, ...(await pttChannels.api.closePttChannel(req.user, req.params.id, req.params.channelId)) });
    }));
  }

  /* Opt-in trip summary: totals only, never points. */
  router.put('/:id/summary', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.json({ ok: true, ...(await service.shareSummary(req.user, req.params.id, req.body?.summary)) });
  }));

  router.delete('/:id/summary', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.withdrawSummary(req.user, req.params.id)) });
  }));

  /* ---- «مؤقت الرجوع»: my return timer ---- */
  router.get('/:id/return-timer', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.getReturnTimer(req.user, req.params.id)) });
  }));

  router.post('/:id/return-timer', auth, asyncHandler(async (req, res) => {
    if (!timerLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.status(201).json({ ok: true, ...(await service.armReturnTimer(req.user, req.params.id, req.body || {})) });
  }));

  router.post('/:id/return-timer/arrived', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.arrivedReturnTimer(req.user, req.params.id)) });
  }));

  router.delete('/:id/return-timer', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.cancelReturnTimer(req.user, req.params.id)) });
  }));

  /* ---- «بطلع من التغطية»: no silence alert about me until my next fix (or `minutes`, ≤ 12 h) ---- */
  router.post('/:id/going-offline', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.json({ ok: true, ...(await service.goingOffline(req.user, req.params.id, req.body || {})) });
  }));

  /* ---- «غرّزت» ---- */
  router.post('/:id/stuck', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.raiseStuck(req.user, req.params.id, req.body || {})) });
  }));

  router.delete('/:id/stuck', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.clearStuck(req.user, req.params.id)) });
  }));

  router.post('/:id/stuck/:userId/reply', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.json({ ok: true, ...(await service.replyStuck(req.user, req.params.id, req.params.userId, req.body || {})) });
  }));

  /* ---- shared waypoints ---- */
  router.get('/:id/waypoints', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.listWaypoints(req.user, req.params.id)) });
  }));

  router.post('/:id/waypoints', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id) || !waypointLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.status(201).json({ ok: true, ...(await service.addWaypoint(req.user, req.params.id, req.body || {})) });
  }));

  router.delete('/:id/waypoints/:wid', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.removeWaypoint(req.user, req.params.id, req.params.wid)) });
  }));

  /* ---- convoy (leader / co-leader) ---- */
  router.patch('/:id/convoy', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.json({ ok: true, ...(await service.setConvoy(req.user, req.params.id, req.body || {})) });
  }));

  /* ---- trip plan (+ destination) and checklist ---- */
  router.get('/:id/plan', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.getPlan(req.user, req.params.id)) });
  }));

  router.put('/:id/plan', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.json({ ok: true, ...(await service.putPlan(req.user, req.params.id, req.body || {})) });
  }));

  router.get('/:id/checklist', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.listChecklist(req.user, req.params.id)) });
  }));

  router.post('/:id/checklist', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.status(201).json({ ok: true, ...(await service.addChecklistItem(req.user, req.params.id, req.body || {})) });
  }));

  router.patch('/:id/checklist/:itemId', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.json({ ok: true, ...(await service.patchChecklistItem(req.user, req.params.id, req.params.itemId, req.body || {})) });
  }));

  router.delete('/:id/checklist/:itemId', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.removeChecklistItem(req.user, req.params.id, req.params.itemId)) });
  }));

  /* ---- «قناة الطلعة»: shared YouTube channel (state only — every phone plays its own official player) ---- */
  router.get('/:id/media', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.getMedia(req.user, req.params.id)) });
  }));

  router.post('/:id/media', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.json({ ok: true, ...(await service.mediaAction(req.user, req.params.id, req.body || {})) });
  }));

  router.post('/:id/media/takeover', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.json({ ok: true, ...(await service.takeoverMedia(req.user, req.params.id)) });
  }));

  /* ---- «إذاعة الطلعة»: shared trip audio (state only — every phone plays the source itself) ---- */
  router.get('/group-audio/catalog', (_req, res) => {
    res.set('Cache-Control', 'public, max-age=3600');
    res.json({ ok: true, stations: groupAudioCatalog() });
  });

  router.get('/:id/group-audio', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.getGroupAudio(req.user, req.params.id)) });
  }));

  router.post('/:id/group-audio', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    res.json({ ok: true, ...(await service.groupAudioCommand(req.user, req.params.id, req.body || {})) });
  }));

  /* «المحادثات» — HTTP side of the trip chat (the live socket carries the same
   * frames: chat_message / chat_read / chat_typing). `:with` is 'group' or the
   * other member's user id. Cursor pagination by server seq: ?before=<seq> or
   * ?after=<seq>, &limit≤100. Membership is checked on every call — see chat.js. */
  router.get('/:id/chat', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.chatConversations(req.user, req.params.id)) });
  }));

  router.get('/:id/chat/:with', auth, asyncHandler(async (req, res) => {
    const { before, after, limit } = req.query;
    res.json({ ok: true, ...(await service.chatMessages(req.user, req.params.id, req.params.with, { before, after, limit })) });
  }));

  router.post('/:id/chat/:with', auth, asyncHandler(async (req, res) => {
    if (!writeLimit(req.user.id)) return res.status(429).json({ ok: false, error: 'rate_limited' });
    const r = await service.chatSend(req.user, req.params.id, { ...(req.body || {}), with: req.params.with });
    res.status(r.duplicate ? 200 : 201).json({ ok: true, ...r });
  }));

  router.post('/:id/chat/:with/read', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.chatRead(req.user, req.params.id, req.params.with, req.body?.seq)) });
  }));

  router.delete('/:id/chat/messages/:messageId', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.chatDelete(req.user, req.params.id, req.params.messageId)) });
  }));

  router.post('/:id/leave', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.leave(req.user, req.params.id)) });
  }));

  router.post('/:id/members/:userId/co-leader', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.setCoLeader(req.user, req.params.id, req.params.userId, req.body?.co_leader)) });
  }));

  router.post('/:id/lock', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.setJoinLock(req.user, req.params.id, req.body?.locked)) });
  }));

  router.delete('/:id/members/:userId', auth, asyncHandler(async (req, res) => {
    res.json({ ok: true, ...(await service.removeMember(req.user, req.params.id, req.params.userId)) });
  }));

  router.use((e, _req, res, next) => {
    if (e instanceof OutingError) return res.status(e.status).json({ ok: false, error: e.code });
    if (e?.type === 'entity.too.large') return res.status(413).json({ ok: false, error: 'too_large' });
    console.warn('[outings]', e.code || e.message);
    return next(Object.assign(new Error('internal_error'), { status: 500 }));
  });

  return router;
}

module.exports = createOutingsRouter;
