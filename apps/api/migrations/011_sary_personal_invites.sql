-- «دعوة شخصية» — personal, single-use invites.
--
-- Additive only: new nullable / defaulted columns and two indexes. Nothing
-- existing is altered, dropped or rewritten, and every existing invite row
-- keeps its meaning (kind defaults to 'group' = today's open link). Older API
-- builds keep working against this schema: they never read the new columns.
--
-- A personal invite is ONE link bound to ONE person the inviter knows:
--   · invitee_name   — the name the inviter gave them («فهد أخوي»); whoever
--                      joins through the link is shown under it in that trip.
--   · invitee_phone_hash / _last4 — the number from the inviter's contacts.
--                      Only a salted SHA-256 digest (hex) (to spot a second invite to
--                      the same number in the same trip) and the last four
--                      digits (to tell two «فهد» apart) are kept. The full
--                      number never reaches the server.
--   · consumed_by / consumed_at — the first person to join through it. After
--                      that the link admits only them (rejoin); anyone else is
--                      told «هذه الدعوة لشخص آخر».
--   · opened_at     — first preview, so the leader sees «فتحها» vs «لم يفتحها».
--   · replaced_by   — set on the old row when the leader re-sends.
--
-- outings.open_links: may the trip's open group link (kind = 'group') still
-- admit people? true for every existing trip, so build 9–11 links keep
-- working; new clients create trips with it off, and the leader can switch it.
--
-- outing_members.invited_name / invite_id / invited_phone_last4: how the
-- member joined. The trip shows COALESCE(invited_name, users.display_name);
-- the person's own name stays as a secondary nickname.

ALTER TABLE sary.outing_invites ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'group';
ALTER TABLE sary.outing_invites DROP CONSTRAINT IF EXISTS outing_invites_kind_check;
ALTER TABLE sary.outing_invites ADD CONSTRAINT outing_invites_kind_check CHECK (kind IN ('group', 'personal'));
ALTER TABLE sary.outing_invites ADD COLUMN IF NOT EXISTS invitee_name text;
ALTER TABLE sary.outing_invites DROP CONSTRAINT IF EXISTS outing_invites_invitee_name_check;
ALTER TABLE sary.outing_invites ADD CONSTRAINT outing_invites_invitee_name_check
  CHECK (invitee_name IS NULL OR char_length(invitee_name) BETWEEN 1 AND 40);
ALTER TABLE sary.outing_invites ADD COLUMN IF NOT EXISTS invitee_phone_hash text;
ALTER TABLE sary.outing_invites DROP CONSTRAINT IF EXISTS outing_invites_phone_hash_check;
ALTER TABLE sary.outing_invites ADD CONSTRAINT outing_invites_phone_hash_check
  CHECK (invitee_phone_hash IS NULL OR invitee_phone_hash ~ '^[0-9a-f]{64}$');
ALTER TABLE sary.outing_invites ADD COLUMN IF NOT EXISTS invitee_phone_last4 text;
ALTER TABLE sary.outing_invites DROP CONSTRAINT IF EXISTS outing_invites_phone_last4_check;
ALTER TABLE sary.outing_invites ADD CONSTRAINT outing_invites_phone_last4_check
  CHECK (invitee_phone_last4 IS NULL OR invitee_phone_last4 ~ '^[0-9]{4}$');
ALTER TABLE sary.outing_invites ADD COLUMN IF NOT EXISTS consumed_by uuid REFERENCES sary.users(id) ON DELETE SET NULL;
ALTER TABLE sary.outing_invites ADD COLUMN IF NOT EXISTS consumed_at timestamptz;
ALTER TABLE sary.outing_invites ADD COLUMN IF NOT EXISTS opened_at timestamptz;
-- «أرسل من جديد» revokes the old link and points it at the new one, so the
-- leader's list shows one line per person.
ALTER TABLE sary.outing_invites ADD COLUMN IF NOT EXISTS replaced_by uuid REFERENCES sary.outing_invites(id) ON DELETE SET NULL;
ALTER TABLE sary.outing_invites DROP CONSTRAINT IF EXISTS outing_invites_personal_shape;
ALTER TABLE sary.outing_invites ADD CONSTRAINT outing_invites_personal_shape
  CHECK (kind = 'group' OR invitee_name IS NOT NULL);
CREATE INDEX IF NOT EXISTS outing_invites_personal_idx
  ON sary.outing_invites (outing_id, created_at DESC) WHERE kind = 'personal';

ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS open_links boolean NOT NULL DEFAULT true;

ALTER TABLE sary.outing_members ADD COLUMN IF NOT EXISTS invited_name text;
ALTER TABLE sary.outing_members DROP CONSTRAINT IF EXISTS outing_members_invited_name_check;
ALTER TABLE sary.outing_members ADD CONSTRAINT outing_members_invited_name_check
  CHECK (invited_name IS NULL OR char_length(invited_name) BETWEEN 1 AND 40);
ALTER TABLE sary.outing_members ADD COLUMN IF NOT EXISTS invited_phone_last4 text;
ALTER TABLE sary.outing_members DROP CONSTRAINT IF EXISTS outing_members_phone_last4_check;
ALTER TABLE sary.outing_members ADD CONSTRAINT outing_members_phone_last4_check
  CHECK (invited_phone_last4 IS NULL OR invited_phone_last4 ~ '^[0-9]{4}$');
ALTER TABLE sary.outing_members ADD COLUMN IF NOT EXISTS invite_id uuid REFERENCES sary.outing_invites(id) ON DELETE SET NULL;
