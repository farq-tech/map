-- «بلّغ عن الرسالة» و«احظر» — App Store Guideline 1.2 (user-generated content):
-- a way to report objectionable messages and to block abusive members.
--
-- Additive only: two new tables and their indexes. Nothing existing is
-- altered or rewritten; older API builds never read them.
--
-- chat_reports — one row per report, kept for review (see docs/sary-moderation.md
--   for the SQL to read them). message_id is the reported chat message;
--   ON DELETE SET NULL keeps the report (with its snapshot) after the message
--   is purged by the 30-day chat retention. body_snapshot / sender_id are what
--   the message said and who sent it at report time, so a reviewer sees it even
--   after the sender deletes it. One report per (reporter, message).
--
-- user_blocks — «احظر فلان»: the blocker no longer sees the blocked person's
--   chat messages or voice notes, and the blocked person cannot send the
--   blocker direct messages. SOS is never filtered (safety beats blocking).
--   Both sides cascade with the account («احذف حسابي»).
--
-- RLS on, no policies; anon/authenticated revoked (server-only access).

CREATE TABLE IF NOT EXISTS sary.chat_reports (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id    uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  message_id     uuid REFERENCES sary.chat_messages(id) ON DELETE SET NULL,
  outing_id      uuid REFERENCES sary.outings(id) ON DELETE SET NULL,
  sender_id      uuid REFERENCES sary.users(id) ON DELETE SET NULL,
  reason         text NOT NULL CHECK (reason IN ('abuse', 'harassment', 'spam', 'sexual', 'violence', 'other')),
  note           text CHECK (note IS NULL OR char_length(note) <= 500),
  body_snapshot  text CHECK (body_snapshot IS NULL OR char_length(body_snapshot) <= 1000),
  status         text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'reviewed', 'actioned', 'dismissed')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  reviewed_at    timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS chat_reports_once_idx ON sary.chat_reports (reporter_id, message_id) WHERE message_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS chat_reports_open_idx ON sary.chat_reports (created_at DESC) WHERE status = 'open';

CREATE TABLE IF NOT EXISTS sary.user_blocks (
  blocker_id  uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  blocked_id  uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id),
  CONSTRAINT user_blocks_not_self CHECK (blocker_id <> blocked_id)
);
CREATE INDEX IF NOT EXISTS user_blocks_blocked_idx ON sary.user_blocks (blocked_id);

ALTER TABLE sary.chat_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE sary.user_blocks  ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON sary.chat_reports, sary.user_blocks FROM %I', r);
    END IF;
  END LOOP;
END $$;
