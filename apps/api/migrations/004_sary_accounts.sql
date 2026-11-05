-- Account recovery, co-leaders and locking an outing to new joiners.
--
-- Additive only: new nullable / defaulted columns and one partial index.
-- Nothing existing is altered, dropped or rewritten; older API builds keep
-- working against this schema (they simply never read the new columns).
--
-- Recovery: a person can ask for ONE recovery code at a time. The code is
-- `selector · verifier`; only the selector (to find the row) and a SHA-256
-- digest of the verifier are stored, so the database alone cannot recover
-- anyone. Redeeming it mints a new device token, revokes the old one and
-- consumes the code.

ALTER TABLE sary.users ADD COLUMN IF NOT EXISTS recovery_selector   text;
ALTER TABLE sary.users ADD COLUMN IF NOT EXISTS recovery_hash       bytea;
ALTER TABLE sary.users ADD COLUMN IF NOT EXISTS recovery_created_at timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS users_recovery_selector_idx
  ON sary.users (recovery_selector) WHERE recovery_selector IS NOT NULL;

-- «مساعد»: a member the owner trusts to start/pause/resume, manage the invite
-- link and set rally points. Kept as a flag beside `role` (owner|member) so
-- every existing `role = 'owner'` check keeps its exact meaning.
ALTER TABLE sary.outing_members ADD COLUMN IF NOT EXISTS co_leader boolean NOT NULL DEFAULT false;

-- «قفل الانضمام»: once set, invite links stop admitting anyone new.
ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS join_locked boolean NOT NULL DEFAULT false;
