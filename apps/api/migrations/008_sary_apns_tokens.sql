-- Native iOS push (APNs) device tokens, next to the web push subscriptions.
--
-- Additive only: one new table. Like sary.push_subscriptions, a token belongs
-- to a device identity (sary.users), not to an outing — who receives a push is
-- decided at send time from active membership. The token is the opaque hex
-- string iOS hands the app; `environment` says which APNs host accepts it
-- (Xcode/TestFlight-dev builds → sandbox, App Store/TestFlight → production).
-- Nothing here is a server secret (the .p8 key lives in the API's environment
-- only). RLS on, no policies.

CREATE TABLE IF NOT EXISTS sary.apns_tokens (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  token         text NOT NULL UNIQUE CHECK (token ~ '^[0-9a-f]{64,200}$'),
  environment   text NOT NULL CHECK (environment IN ('sandbox', 'production')),
  bundle_id     text NOT NULL CHECK (char_length(bundle_id) BETWEEN 3 AND 155),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  last_used_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS apns_tokens_user_idx ON sary.apns_tokens (user_id, updated_at DESC);

ALTER TABLE sary.apns_tokens ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON sary.apns_tokens FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON sary.apns_tokens FROM authenticated;
  END IF;
END $$;
