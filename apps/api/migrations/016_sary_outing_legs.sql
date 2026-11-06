-- «المشاوير» (outing legs): an outing («الطلعة») is the container; a leg («مشوار»)
-- is one A → B inside it. Zero or many per outing; arriving ends that leg only.
-- See ux/الطلعة-والمشوار.md and lib/outings/legs.js.
--
-- Additive only: one new table. Nothing existing is altered or dropped. Older
-- clients (builds 20–22) keep reading the outing's plan_destination: starting a
-- group leg also writes its destination there, so they see it as "the" destination.
--
-- Privacy shape, enforced by the schema rather than hoped for:
--   · a group leg's destination is a place the leader chose for everyone (the same
--     data plan_destination already holds); a personal leg belongs to ONE person
--     (owner_user_id) and the API only ever returns it to that person.
--   · no positions or tracks here: a leg's distance / duration are totals the
--     owner's phone computed, like trip_summaries.
--   · legs go with the outing (ON DELETE CASCADE); a personal leg goes with its
--     owner's identity; a group leg forgets who started it (SET NULL).
--   · RLS on with no policies, like the rest of the schema.

CREATE TABLE IF NOT EXISTS sary.outing_legs (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outing_id      uuid NOT NULL REFERENCES sary.outings(id) ON DELETE CASCADE,
  seq            integer NOT NULL CHECK (seq >= 1),
  scope          text NOT NULL CHECK (scope IN ('group', 'personal')),
  owner_user_id  uuid REFERENCES sary.users(id) ON DELETE CASCADE,
  started_by     uuid REFERENCES sary.users(id) ON DELETE SET NULL,
  dest_name      text NOT NULL CHECK (char_length(dest_name) BETWEEN 1 AND 40),
  dest_lat       double precision NOT NULL CHECK (dest_lat BETWEEN -90 AND 90),
  dest_lng       double precision NOT NULL CHECK (dest_lng BETWEEN -180 AND 180),
  state          text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'arrived', 'cancelled', 'ended')),
  started_at     timestamptz NOT NULL DEFAULT now(),
  arrived_at     timestamptz,
  closed_at      timestamptz,
  distance_m     integer CHECK (distance_m IS NULL OR distance_m BETWEEN 0 AND 3000000),
  duration_s     integer CHECK (duration_s IS NULL OR duration_s BETWEEN 0 AND 1209600),
  client_id      text CHECK (client_id IS NULL OR client_id ~ '^[A-Za-z0-9_-]{1,64}$'),
  CHECK ((scope = 'group') = (owner_user_id IS NULL)),
  CHECK ((state = 'arrived') = (arrived_at IS NOT NULL)),
  UNIQUE (outing_id, seq)
);

/* One leg on the way per scope: one for the group, one per person. */
CREATE UNIQUE INDEX IF NOT EXISTS outing_legs_group_active_idx
  ON sary.outing_legs (outing_id) WHERE state = 'active' AND scope = 'group';
CREATE UNIQUE INDEX IF NOT EXISTS outing_legs_personal_active_idx
  ON sary.outing_legs (outing_id, owner_user_id) WHERE state = 'active' AND scope = 'personal';
/* A retried «ابدأ المشوار» is the same leg. */
CREATE UNIQUE INDEX IF NOT EXISTS outing_legs_client_idx
  ON sary.outing_legs (outing_id, client_id) WHERE client_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS outing_legs_owner_idx ON sary.outing_legs (owner_user_id) WHERE owner_user_id IS NOT NULL;

ALTER TABLE sary.outing_legs ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON sary.outing_legs FROM %I', r);
    END IF;
  END LOOP;
END $$;
