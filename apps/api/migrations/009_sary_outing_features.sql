-- Outing features: return timer («مؤقت الرجوع»), shared waypoints («نقاط مشتركة»),
-- convoy settings («وضع القافلة»), trip plan + checklist («تخطيط الطلعة»).
-- («غرّزت» lives in memory only, like SOS — nothing for it here.)
--
-- Additive only: new tables and new nullable / defaulted columns. Nothing
-- existing is altered, dropped or rewritten; older API builds keep working.
--
-- Privacy shape, enforced by the schema rather than hoped for:
--   · a return timer belongs to ONE person. Its watch link is a capability
--     token stored as a SHA-256 digest only (sary.watch_tokens). `last_known` is a snapshot taken
--     at the moment the timer went overdue (never earlier), only of members
--     who had sharing on; the API never returns it before overdue.
--   · timers, their watcher subscriptions and waypoints go with the person's
--     identity (ON DELETE CASCADE) and with the outing.
--   · RLS on with no policies, like the rest of the schema.

CREATE TABLE IF NOT EXISTS sary.return_timers (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outing_id         uuid NOT NULL REFERENCES sary.outings(id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  due_at            timestamptz NOT NULL,
  contact_name      text NOT NULL CHECK (char_length(contact_name) BETWEEN 1 AND 40),
  state             text NOT NULL DEFAULT 'armed' CHECK (state IN ('armed', 'overdue', 'arrived', 'cancelled')),
  last_known        jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  overdue_at        timestamptz,
  closed_at         timestamptz,
  CHECK (last_known IS NULL OR state <> 'armed')
);
/* One live (armed or overdue) timer per person per outing; arming again replaces it. */
CREATE UNIQUE INDEX IF NOT EXISTS return_timers_live_idx
  ON sary.return_timers (outing_id, user_id) WHERE state IN ('armed', 'overdue');
CREATE INDEX IF NOT EXISTS return_timers_due_idx ON sary.return_timers (due_at) WHERE state = 'armed';
CREATE INDEX IF NOT EXISTS return_timers_user_idx ON sary.return_timers (user_id);

/* Watch-link capability tokens, SHA-256 digests only. A timer that is extended
 * («مدّد», same contact) keeps its earlier links working, so it may have a few. */
CREATE TABLE IF NOT EXISTS sary.watch_tokens (
  token_hash  bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
  timer_id    uuid NOT NULL REFERENCES sary.return_timers(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS watch_tokens_timer_idx ON sary.watch_tokens (timer_id, created_at DESC);

/* A watcher's browser push subscription — belongs to one timer, not to any identity. */
CREATE TABLE IF NOT EXISTS sary.watch_subscriptions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  timer_id    uuid NOT NULL REFERENCES sary.return_timers(id) ON DELETE CASCADE,
  endpoint    text NOT NULL CHECK (char_length(endpoint) BETWEEN 12 AND 1024),
  p256dh      text NOT NULL CHECK (char_length(p256dh) BETWEEN 16 AND 200),
  auth        text NOT NULL CHECK (char_length(auth) BETWEEN 8 AND 100),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (timer_id, endpoint)
);

CREATE TABLE IF NOT EXISTS sary.outing_waypoints (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outing_id   uuid NOT NULL REFERENCES sary.outings(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind IN ('camp', 'water', 'danger', 'passable', 'stuck_spot', 'other')),
  title       text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 40),
  note        text CHECK (note IS NULL OR char_length(note) <= 140),
  lat         double precision NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lng         double precision NOT NULL CHECK (lng BETWEEN -180 AND 180),
  /* A JPEG data URL of at most 150 KB of image bytes (~205 000 base64 chars). */
  photo       text CHECK (photo IS NULL OR (char_length(photo) <= 205000 AND photo LIKE 'data:image/jpeg;base64,%')),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS outing_waypoints_outing_idx ON sary.outing_waypoints (outing_id, created_at);
CREATE INDEX IF NOT EXISTS outing_waypoints_user_idx ON sary.outing_waypoints (user_id);

/* «وضع القافلة»: who leads, who closes, how far apart is too far. */
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS convoy_lead_user_id uuid REFERENCES sary.users(id) ON DELETE SET NULL;
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS convoy_tail_user_id uuid REFERENCES sary.users(id) ON DELETE SET NULL;
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS convoy_max_gap_m integer NOT NULL DEFAULT 1000;
ALTER TABLE sary.outings DROP CONSTRAINT IF EXISTS outings_convoy_gap;
ALTER TABLE sary.outings ADD CONSTRAINT outings_convoy_gap CHECK (convoy_max_gap_m BETWEEN 200 AND 5000);

/* Offline car-to-car mesh: a members-only secret per outing (32 random bytes, base64url).
 * Returned only to active members; rotated when anyone leaves, is removed or deletes
 * their account. Never logged. Generated on first read when null. */
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS mesh_key text;
ALTER TABLE sary.outings DROP CONSTRAINT IF EXISTS outings_mesh_key_shape;
ALTER TABLE sary.outings ADD CONSTRAINT outings_mesh_key_shape CHECK (mesh_key IS NULL OR mesh_key ~ '^[A-Za-z0-9_-]{43}$');

/* «تخطيط الطلعة»: a planned route (GeoJSON LineString) and notes, set by a leader. */
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS plan_route jsonb;
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS plan_notes text;
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS plan_updated_at timestamptz;
/* «الوجهة»: a place, not a person — { name ≤40, lat, lng } or null. */
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS plan_destination jsonb;
ALTER TABLE sary.outings DROP CONSTRAINT IF EXISTS outings_plan_notes_len;
ALTER TABLE sary.outings ADD CONSTRAINT outings_plan_notes_len CHECK (plan_notes IS NULL OR char_length(plan_notes) <= 1000);

CREATE TABLE IF NOT EXISTS sary.outing_checklist (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outing_id         uuid NOT NULL REFERENCES sary.outings(id) ON DELETE CASCADE,
  title             text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 40),
  assignee_user_id  uuid REFERENCES sary.users(id) ON DELETE SET NULL,
  done              boolean NOT NULL DEFAULT false,
  /* Reassigned to the outing's owner when the creator deletes their account. */
  created_by        uuid REFERENCES sary.users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS outing_checklist_outing_idx ON sary.outing_checklist (outing_id, created_at);

ALTER TABLE sary.return_timers       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sary.watch_tokens        ENABLE ROW LEVEL SECURITY;
ALTER TABLE sary.watch_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE sary.outing_waypoints    ENABLE ROW LEVEL SECURITY;
ALTER TABLE sary.outing_checklist    ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON sary.return_timers, sary.watch_tokens, sary.watch_subscriptions, sary.outing_waypoints, sary.outing_checklist FROM %I', r);
    END IF;
  END LOOP;
END $$;
