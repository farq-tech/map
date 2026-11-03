-- Opt-in field-test diagnostics: aggregates only (counts, durations,
-- latencies). No user id, no coordinates, no names. The outing is a one-way
-- HMAC group key (outing_ref) so the row cannot be joined back to a person.
-- Kept 180 days by the outings sweep.
CREATE TABLE IF NOT EXISTS sary.field_diagnostics (
  id bigserial PRIMARY KEY,
  outing_ref text NOT NULL CHECK (outing_ref ~ '^[0-9a-f]{24}$'),
  platform text NOT NULL,
  browser text NOT NULL,
  report jsonb NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS field_diagnostics_ref_idx ON sary.field_diagnostics (outing_ref, received_at);
ALTER TABLE sary.field_diagnostics ENABLE ROW LEVEL SECURITY;
