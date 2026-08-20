'use strict';

/**
 * POST /api/analytics — batched product events.
 *
 * Thin on purpose: every rule (event allowlist, the privacy filter on `meta`,
 * session id validation, rate limit, fail-soft) lives in lib/analytics.js
 * where it can be tested without a database or a socket.
 */

const express = require('express');
const { asyncHandler } = require('../lib/async-handler');
const { comparisonQuery } = require('../lib/comparison-pool');
const {
  ALLOWED_EVENT_TYPES,
  MAX_EVENTS_PER_REQUEST,
  ingestEvents,
  writeEnabled,
} = require('../lib/analytics');

function createAnalyticsRouter({ query = comparisonQuery } = {}) {
  const router = express.Router();

  /* Lets the client (and a human with curl) see what this endpoint accepts. */
  router.get('/', (_req, res) => {
    res.json({
      ok: true,
      service: 'farq-map-analytics',
      write_enabled: writeEnabled(),
      max_events: MAX_EVENTS_PER_REQUEST,
      events: ALLOWED_EVENT_TYPES,
    });
  });

  router.post(
    '/',
    asyncHandler(async (req, res) => {
      const result = await ingestEvents({ body: req.body, query });
      if (result.status === 400) {
        return res.status(400).json({ ok: false, error: result.error });
      }
      /* 204 for everything else — a disabled flag, a rate limit or a failed
         write must never surface to the app or leak a DB error. */
      return res.status(204).end();
    }),
  );

  return router;
}

module.exports = createAnalyticsRouter;
