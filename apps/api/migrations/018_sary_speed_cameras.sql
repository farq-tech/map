-- «كاميرات الرصد» (ساهر): the map layer, the on-route voice alert, and our own
-- crowd-sourced base built from user reports. See lib/cameras.js and
-- routes/cameras.js, and the importer in scripts/import-cameras.js.
--
-- Additive only: two new tables, nothing existing is altered or dropped.
--
-- Two tables, kept apart on purpose:
--   · speed_cameras — the published points the app draws and alerts on. Upserted
--     from external sources (OSM / official) by (source, source_id), so a re-import
--     is idempotent and never duplicates. A user-sourced camera has source='user'
--     and no source_id; it is born only when enough separate reports agree.
--   · camera_reports — raw «كاميرا هنا» taps from drivers. This is the only place a
--     reporter's identity touches a location, and it is NEVER returned to the public
--     layer: GET /api/cameras reads speed_cameras alone. user_id is kept solely to
--     stop one person confirming the same spot many times, and it goes with the
--     person (ON DELETE SET NULL) — the report, de-identified, stays.
--
-- RLS on with no policies, like the rest of the schema: only the service role
-- (which bypasses RLS) reaches these, and every public read goes through the API.

CREATE TABLE IF NOT EXISTS sary.speed_cameras (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lat           double precision NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lon           double precision NOT NULL CHECK (lon BETWEEN -180 AND 180),
  -- Direction the camera watches, degrees clockwise from north. Optional: many
  -- sources give none, and a camera with no bearing simply alerts both ways.
  bearing       double precision CHECK (bearing IS NULL OR (bearing >= 0 AND bearing < 360)),
  kind          text NOT NULL DEFAULT 'fixed'
                  CHECK (kind IN ('fixed', 'mobile', 'red_light', 'avg_speed')),
  -- Posted limit in km/h. Optional, and we stay silent about the number unless we
  -- trust it (see lib/cameras.js): a wrong spoken limit is worse than none.
  speed_limit   integer CHECK (speed_limit IS NULL OR speed_limit BETWEEN 10 AND 200),
  source        text NOT NULL DEFAULT 'other'
                  CHECK (source IN ('osm', 'official', 'user', 'other')),
  source_id     text CHECK (source_id IS NULL OR char_length(source_id) BETWEEN 1 AND 128),
  confidence    real NOT NULL DEFAULT 0.5 CHECK (confidence BETWEEN 0 AND 1),
  confirmations integer NOT NULL DEFAULT 0 CHECK (confirmations >= 0),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- The idempotency key for imports: upsert on (source, source_id). Partial, because
-- user cameras carry no source_id and must not collide with one another.
CREATE UNIQUE INDEX IF NOT EXISTS speed_cameras_source_idx
  ON sary.speed_cameras (source, source_id) WHERE source_id IS NOT NULL;
-- bbox reads (GET /api/cameras?bbox=): lon within, then lat within.
CREATE INDEX IF NOT EXISTS speed_cameras_bbox_idx ON sary.speed_cameras (lon, lat);

CREATE TABLE IF NOT EXISTS sary.camera_reports (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Kept only for dedupe; never exposed. Forgotten when the person is deleted.
  user_id    uuid REFERENCES sary.users(id) ON DELETE SET NULL,
  lat        double precision NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lon        double precision NOT NULL CHECK (lon BETWEEN -180 AND 180),
  kind       text NOT NULL DEFAULT 'fixed'
               CHECK (kind IN ('fixed', 'mobile', 'red_light', 'avg_speed')),
  status     text NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'promoted', 'duplicate', 'rejected')),
  -- Set when this report tipped a spot over the threshold into speed_cameras, or
  -- when it landed on one already there. The report goes if that camera goes.
  camera_id  uuid REFERENCES sary.speed_cameras(id) ON DELETE SET NULL,
  -- A retried tap from the same phone is the same report, not a new confirmation.
  client_id  text CHECK (client_id IS NULL OR client_id ~ '^[A-Za-z0-9_-]{1,64}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS camera_reports_bbox_idx ON sary.camera_reports (lon, lat);
CREATE INDEX IF NOT EXISTS camera_reports_pending_idx ON sary.camera_reports (status, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS camera_reports_client_idx
  ON sary.camera_reports (user_id, client_id) WHERE client_id IS NOT NULL AND user_id IS NOT NULL;

ALTER TABLE sary.speed_cameras ENABLE ROW LEVEL SECURITY;
ALTER TABLE sary.camera_reports ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON sary.speed_cameras FROM %I', r);
      EXECUTE format('REVOKE ALL ON sary.camera_reports FROM %I', r);
    END IF;
  END LOOP;
END $$;
