-- «قناة الطلعة» voice notes («رسالة صوتية»): a walkie-talkie message that is
-- recorded, sent, then played for everyone on the same channel — and kept for
-- a while so a phone that was out of coverage still gets it when it is back.
--
-- Additive only: one new table and one new column with a default (below).
-- Nothing existing is altered or rewritten. Older API builds never read them.
--
-- Storage is this database (bytea), nothing paid, nothing third party:
--   · one clip ≤ 60 s of AAC (≈24–32 kbps mono) ≈ 240 KB, capped at 640 KB;
--   · gone after 24 h (expires_at, swept every 10 minutes by
--     lib/outings/voice-notes.js), and sooner when the trip ends, when the
--     sender leaves the trip or is removed, or when its private channel closes;
--   · ON DELETE CASCADE with the outing and with the sender's account
--     («احذف حسابي»).
--
-- channel: '1'…'5' (the five public «تردد») or a private channel's uuid
-- (sary.ptt_channels, migration 013). Who may upload or fetch is checked by
-- the server on every request: an active member of the trip, and for a
-- private channel one of its listed members. RLS on, no policies.
--
-- client_id: the sender's idempotency key (an upload retried after a lost
-- answer is not stored twice). recorded_at: when the sender stopped
-- recording (sent late from an outbox it is older than created_at), which is
-- what «still recent enough to play by itself» is measured from.

-- ptt_tokens.voice_notes: this device's app plays voice notes it is woken for
-- (builds before voice notes would show «فلان يتكلم» on the Lock Screen for a
-- transmission that never comes, so only flagged tokens get those pushes).
-- A new column with a default: existing rows read false, older builds never
-- send it.

ALTER TABLE sary.ptt_tokens ADD COLUMN IF NOT EXISTS voice_notes boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS sary.ptt_voice_notes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outing_id    uuid NOT NULL REFERENCES sary.outings(id) ON DELETE CASCADE,
  channel      text NOT NULL CHECK (channel ~ '^[1-5]$' OR channel ~ '^[0-9a-f-]{36}$'),
  sender_id    uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  client_id    text NOT NULL CHECK (char_length(client_id) BETWEEN 1 AND 64),
  mime         text NOT NULL CHECK (mime IN ('audio/mp4', 'audio/webm', 'audio/ogg')),
  duration_ms  integer NOT NULL CHECK (duration_ms BETWEEN 300 AND 60000),
  bytes        integer NOT NULL CHECK (bytes BETWEEN 1 AND 655360),
  audio        bytea NOT NULL,
  recorded_at  timestamptz NOT NULL DEFAULT now(),
  created_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
  CONSTRAINT ptt_voice_notes_client_unique UNIQUE (sender_id, client_id)
);
CREATE INDEX IF NOT EXISTS ptt_voice_notes_channel_idx ON sary.ptt_voice_notes (outing_id, channel, created_at DESC);
CREATE INDEX IF NOT EXISTS ptt_voice_notes_expires_idx ON sary.ptt_voice_notes (expires_at);

ALTER TABLE sary.ptt_voice_notes ENABLE ROW LEVEL SECURITY;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON sary.ptt_voice_notes FROM %I', r);
    END IF;
  END LOOP;
END $$;
