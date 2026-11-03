-- Web Push subscriptions, so a note or an SOS reaches a phone whose screen is off.
--
-- Additive only: one new table. A subscription belongs to a device identity
-- (sary.users), not to an outing — who receives a push is decided at send time
-- from active membership, so leaving or being removed stops pushes at once.
-- The endpoint is an opaque push-service URL; p256dh/auth are the browser's
-- public encryption keys. Nothing here is a server secret (the VAPID private
-- key lives in the API's environment only). RLS on, no policies.

CREATE TABLE IF NOT EXISTS sary.push_subscriptions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  endpoint      text NOT NULL UNIQUE CHECK (char_length(endpoint) BETWEEN 12 AND 1024),
  p256dh        text NOT NULL CHECK (char_length(p256dh) BETWEEN 16 AND 200),
  auth          text NOT NULL CHECK (char_length(auth) BETWEEN 8 AND 100),
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_used_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS push_subscriptions_user_idx ON sary.push_subscriptions (user_id, last_used_at DESC);

ALTER TABLE sary.push_subscriptions ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON sary.push_subscriptions FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON sary.push_subscriptions FROM authenticated;
  END IF;
END $$;
