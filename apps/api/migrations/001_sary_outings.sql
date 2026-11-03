-- طلعات مشتركة — shared outings and live member positions.
--
-- Additive only: a new schema, new tables, nothing existing is altered or
-- dropped. Safe to run more than once (every statement is IF NOT EXISTS).
--
-- Privacy shape, enforced by the schema rather than hoped for:
--   · member_positions holds ONE row per member — the latest fix — and no
--     history. Leaving, being removed, pausing sharing or the outing ending
--     deletes it (service layer + ON DELETE CASCADE).
--   · invite tokens and identity tokens are stored as SHA-256 digests; the
--     plaintext exists only in the link / on the device.
--   · RLS is enabled with no policies, so Supabase's anon/authenticated roles
--     (PostgREST, Realtime) can read nothing. Only the API's server-side role
--     touches these tables, and it checks membership on every request.

CREATE SCHEMA IF NOT EXISTS sary;

CREATE TABLE IF NOT EXISTS sary.users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name  text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 40),
  -- Optional small JPEG/PNG/WebP data URL the person chose to share with
  -- members of their outings. Null by default.
  avatar        text CHECK (avatar IS NULL OR char_length(avatar) <= 24000),
  token_hash    bytea NOT NULL UNIQUE,
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sary.outings (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 60),
  owner_id    uuid NOT NULL REFERENCES sary.users(id),
  status      text NOT NULL DEFAULT 'created'
              CHECK (status IN ('created', 'active', 'paused', 'ended')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  started_at  timestamptz,
  ended_at    timestamptz,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS outings_open_idx ON sary.outings (updated_at) WHERE status <> 'ended';

CREATE TABLE IF NOT EXISTS sary.outing_members (
  outing_id  uuid NOT NULL REFERENCES sary.outings(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  role       text NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')),
  status     text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'left', 'removed')),
  sharing    boolean NOT NULL DEFAULT true,
  joined_at  timestamptz NOT NULL DEFAULT now(),
  left_at    timestamptz,
  PRIMARY KEY (outing_id, user_id)
);
CREATE INDEX IF NOT EXISTS outing_members_user_idx ON sary.outing_members (user_id, joined_at DESC);

CREATE TABLE IF NOT EXISTS sary.outing_invites (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outing_id   uuid NOT NULL REFERENCES sary.outings(id) ON DELETE CASCADE,
  token_hash  bytea NOT NULL UNIQUE,
  created_by  uuid NOT NULL REFERENCES sary.users(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL,
  revoked_at  timestamptz,
  uses        integer NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS outing_invites_outing_idx ON sary.outing_invites (outing_id);

CREATE TABLE IF NOT EXISTS sary.member_positions (
  outing_id    uuid NOT NULL,
  user_id      uuid NOT NULL,
  lat          double precision NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lng          double precision NOT NULL CHECK (lng BETWEEN -180 AND 180),
  accuracy     real CHECK (accuracy IS NULL OR accuracy >= 0),
  heading      real CHECK (heading IS NULL OR (heading >= 0 AND heading < 360)),
  speed        real CHECK (speed IS NULL OR speed >= 0),
  recorded_at  timestamptz NOT NULL,
  received_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (outing_id, user_id),
  FOREIGN KEY (outing_id, user_id)
    REFERENCES sary.outing_members (outing_id, user_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS member_positions_received_idx ON sary.member_positions (received_at);

ALTER TABLE sary.users            ENABLE ROW LEVEL SECURITY;
ALTER TABLE sary.outings          ENABLE ROW LEVEL SECURITY;
ALTER TABLE sary.outing_members   ENABLE ROW LEVEL SECURITY;
ALTER TABLE sary.outing_invites   ENABLE ROW LEVEL SECURITY;
ALTER TABLE sary.member_positions ENABLE ROW LEVEL SECURITY;

-- On Supabase, keep the client-facing roles out of the schema entirely.
-- Elsewhere (plain Postgres in CI) these roles do not exist; skip quietly.
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA sary FROM %I', r);
      EXECUTE format('REVOKE ALL ON SCHEMA sary FROM %I', r);
    END IF;
  END LOOP;
END $$;
