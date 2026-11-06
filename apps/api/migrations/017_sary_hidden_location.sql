-- «أخفِ موقعي»: a member stays in the trip (voice notes, radio, chat) but their
-- position is not sent. Additive only: two nullable columns, nothing altered or dropped.
--
--   hidden_at       when they hid it (NULL = visible). Cleared by «أظهر موقعي», by an
--                   SOS (which always sends the real position) and when the trip ends.
--   hidden_reason   'self' today (kept for the trip log; never a free text).
ALTER TABLE sary.outing_members ADD COLUMN IF NOT EXISTS hidden_at timestamptz;
ALTER TABLE sary.outing_members ADD COLUMN IF NOT EXISTS hidden_reason text
  CHECK (hidden_reason IS NULL OR hidden_reason IN ('self'));
