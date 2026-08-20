'use strict';

const express = require('express');
const { asyncHandler } = require('../lib/async-handler');
const { ACTION_TYPES, handleCopilot } = require('../lib/copilot');

function createCopilotRouter() {
  const router = express.Router();

  router.get('/', (_req, res) => {
    res.json({
      ok: true,
      service: 'farq-map-copilot',
      source: 'city_read_model',
      actions: ACTION_TYPES,
      model_phrasing: Boolean(process.env.GEMINI_API_KEY || process.env.GOOGLE_GENAI_API_KEY),
    });
  });

  router.post(
    '/',
    asyncHandler(async (req, res) => {
      const body = req.body && typeof req.body === 'object' ? req.body : {};
      const message = String(body.message || '').slice(0, 400);
      const context = body.context && typeof body.context === 'object' ? body.context : {};
      const result = await handleCopilot({
        message,
        sessionId: body.session_id || body.sessionId,
        language: body.language,
        context: {
          bbox: context.bbox,
          zoom: context.zoom,
          selectedPlaceId: context.selected_place_id ?? context.selectedPlaceId,
          userLat: context.user_lat ?? context.userLat,
          userLng: context.user_lng ?? context.userLng,
          city: context.city,
        },
      });
      res.json(result);
    }),
  );

  return router;
}

module.exports = createCopilotRouter;
