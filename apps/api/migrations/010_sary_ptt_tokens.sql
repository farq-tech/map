-- Push to Talk («قناة الطلعة») channel tokens.
--
-- Additive only: one new table. iOS's PushToTalk framework gives the app an
-- EPHEMERAL APNs token for each channel it joins (one channel per outing); the
-- server sends a `pushtotalk` push to it when someone in the outing starts
-- talking, so iOS wakes the app to play the live audio. The token is valid only
-- while the device stays in that channel: the app deletes it when it leaves or
-- mutes the channel, leaving the outing deletes it (service.leaveRows), and
-- deleting the account or the outing cascades. No audio is ever stored — the
-- walkie-talkie is a relay (lib/outings/ptt.js). RLS on, no policies.

CREATE TABLE IF NOT EXISTS sary.ptt_tokens (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  outing_id     uuid NOT NULL REFERENCES sary.outings(id) ON DELETE CASCADE,
  token         text NOT NULL UNIQUE CHECK (token ~ '^[0-9a-f]{64,200}$'),
  environment   text NOT NULL CHECK (environment IN ('sandbox', 'production')),
  bundle_id     text NOT NULL CHECK (char_length(bundle_id) BETWEEN 3 AND 155),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ptt_tokens_outing_idx ON sary.ptt_tokens (outing_id, user_id);

ALTER TABLE sary.ptt_tokens ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON sary.ptt_tokens FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON sary.ptt_tokens FROM authenticated;
  END IF;
END $$;
