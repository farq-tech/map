-- «ترددات» — walkie-talkie channels inside one trip («قناة الطلعة»).
--
-- Additive only: two new tables. Nothing existing is altered.
--
-- Every trip has five PUBLIC channels «تردد ١…٥» that need no rows at all: any
-- active member may listen and talk on them, and a phone that does not know
-- about channels (builds 9–12) stays on «تردد ١». Rows here are the PRIVATE
-- channels «تردد خاص» the trip leader («أمير الرحلة») opens for the members he
-- picks. Only those members may join, listen, talk or be woken for one — the
-- server checks it on join, on the floor request and on every relayed frame
-- (lib/outings/ptt.js, lib/outings/ptt-channels.js). `kind` keeps room for a
-- named public channel later; today only 'private' rows are written.
--
-- No audio is stored anywhere: the walkie-talkie stays a relay. Ending the
-- trip deletes its private channels (service.endOutingRows); leaving it or being
-- removed deletes that person's invitations (service.leaveRows / removeMember);
-- deleting the account cascades. RLS on, no policies (server-side access only).

CREATE TABLE IF NOT EXISTS sary.ptt_channels (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outing_id   uuid NOT NULL REFERENCES sary.outings(id) ON DELETE CASCADE,
  kind        text NOT NULL DEFAULT 'private' CHECK (kind IN ('public', 'private')),
  name        text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 40),
  created_by  uuid REFERENCES sary.users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ptt_channels_outing_idx ON sary.ptt_channels (outing_id, created_at);

CREATE TABLE IF NOT EXISTS sary.ptt_channel_members (
  channel_id  uuid NOT NULL REFERENCES sary.ptt_channels(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  added_by    uuid REFERENCES sary.users(id) ON DELETE SET NULL,
  added_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (channel_id, user_id)
);
CREATE INDEX IF NOT EXISTS ptt_channel_members_user_idx ON sary.ptt_channel_members (user_id);

ALTER TABLE sary.ptt_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE sary.ptt_channel_members ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON sary.ptt_channels FROM anon;
    REVOKE ALL ON sary.ptt_channel_members FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON sary.ptt_channels FROM authenticated;
    REVOKE ALL ON sary.ptt_channel_members FROM authenticated;
  END IF;
END $$;
