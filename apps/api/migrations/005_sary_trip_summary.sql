-- Opt-in trip summary («شارك ملخصي»): one row of TOTALS per person per outing.
--
-- Additive only: a new table, nothing existing is altered or dropped.
--
-- Privacy shape, enforced by the schema rather than hoped for:
--   · the totals are computed on each person's own phone from its own fixes;
--     the server never receives a point, so there are no coordinate columns
--     here at all — only a distance, two durations and when it was shared.
--   · a row exists only because that person tapped «شارك ملخصي»; withdrawing
--     it deletes the row. Leaving the outing or the outing being deleted
--     removes it with the membership (ON DELETE CASCADE).
--   · RLS on with no policies, like the rest of the schema.

CREATE TABLE IF NOT EXISTS sary.trip_summaries (
  outing_id   uuid NOT NULL,
  user_id     uuid NOT NULL,
  distance_m  integer NOT NULL CHECK (distance_m BETWEEN 0 AND 3000000),
  duration_s  integer NOT NULL CHECK (duration_s BETWEEN 0 AND 1209600),
  moving_s    integer NOT NULL CHECK (moving_s >= 0 AND moving_s <= duration_s),
  shared_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (outing_id, user_id),
  FOREIGN KEY (outing_id, user_id)
    REFERENCES sary.outing_members (outing_id, user_id) ON DELETE CASCADE
);

ALTER TABLE sary.trip_summaries ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON sary.trip_summaries FROM %I', r);
    END IF;
  END LOOP;
END $$;
