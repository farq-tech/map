-- Outing safety: the rally point («نقطة التجمع») — one meeting pin per outing, set by its owner. (SOS and battery are in memory only.)
-- Additive and nullable: existing outings simply have none. It is a place,
-- not a person's position, and it is cleared when the outing ends.
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS rally_lat double precision;
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS rally_lng double precision;
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS rally_label text;
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS rally_set_at timestamptz;
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS rally_set_by uuid REFERENCES sary.users(id) ON DELETE SET NULL;
ALTER TABLE sary.outings DROP CONSTRAINT IF EXISTS outings_rally_shape;
ALTER TABLE sary.outings ADD CONSTRAINT outings_rally_shape CHECK (
  (rally_lat IS NULL AND rally_lng IS NULL)
  OR (rally_lat BETWEEN -90 AND 90 AND rally_lng BETWEEN -180 AND 180)
);
ALTER TABLE sary.outings DROP CONSTRAINT IF EXISTS outings_rally_label_len;
ALTER TABLE sary.outings ADD CONSTRAINT outings_rally_label_len CHECK (rally_label IS NULL OR char_length(rally_label) <= 40);
