'use strict';

const express = require('express');
const { asyncHandler } = require('../lib/async-handler');
const {
  chatConfigured,
  handleChat,
  unconfiguredPayload,
} = require('../lib/chat-handler');

function createChatRouter() {
  const router = express.Router();

  router.get(
    '/',
    (_req, res) => {
      res.json({
        ok: true,
        service: 'farq-map-chat',
        configured: chatConfigured(),
        tools: ['search_source_opportunities', 'get_visible_opportunities'],
      });
    },
  );

  router.post(
    '/',
    asyncHandler(async (req, res) => {
      const body = req.body && typeof req.body === 'object' ? req.body : {};
      const lastUser =
        Array.isArray(body.messages) && body.messages.length
          ? [...body.messages]
              .reverse()
              .find((m) => m && (m.role === 'user' || m.role === 'human'))
          : null;
      const message =
        body.message ||
        body.q ||
        (lastUser && (lastUser.content || lastUser.text || lastUser.message)) ||
        '';

      const result = await handleChat({
        message,
        bbox: body.bbox,
        selected_place: body.selected_place || body.selectedPlace,
        user_lat: body.user_lat ?? body.userLat,
        user_lng: body.user_lng ?? body.userLng,
        language: body.language,
      });

      if (result.status === 503) {
        return res.status(503).json(unconfiguredPayload());
      }
      if (result.status && result.status >= 400) {
        return res.status(result.status).json({
          ok: false,
          error: result.error || 'chat_error',
          message_ar: result.message_ar || result.text,
        });
      }
      return res.status(200).json({
        ok: true,
        text: result.text,
        refused: result.refused || null,
        tool: result.tool
          ? {
              name: result.tool.name,
              queried_bbox: result.tool.queried_bbox,
              count: result.tool.count,
              place: result.tool.place || null,
            }
          : null,
      });
    }),
  );

  return router;
}

module.exports = createChatRouter;
