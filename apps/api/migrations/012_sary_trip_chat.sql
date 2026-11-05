-- «المحادثات» — trip chat: one group chat per trip («دردشة الطلعة») and 1:1
-- direct chats between two members of the same trip.
--
-- Additive only: two new tables, two new columns with defaults, indexes. No
-- existing column is altered, dropped or rewritten; older API builds never
-- read any of it.
--
-- chat_messages
--   · conv        'group', or '<uuid>:<uuid>' — the two participants of a
--                 direct chat, lower id first, so both sides name it the same.
--   · seq         server order, per outing (shared by every conversation in
--                 the trip). Clients sort and paginate by it, never by clock.
--   · sender_id / recipient_id
--                 ON DELETE CASCADE: «احذف حسابي» deletes every message the
--                 person sent and every direct message sent to them.
--   · client_id   the sender's idempotency key (offline outbox retries).
--   · kind        'text' (≤1000 chars) · 'quick' (a preset) · 'location'
--                 (lat/lng + optional label, opens on the map).
--   · deleted_at / deleted_by_role
--                 soft delete: the content is wiped at once, only the
--                 «حُذفت» / «حذفها أمير الرحلة» marker stays.
--
-- Retention (see lib/outings/chat.js, run by the 10-minute sweep): every
-- message and read marker of an outing is DELETED 30 days after the outing
-- ended (OUTING_CHAT_RETENTION_DAYS). Nothing is ever shown to anyone who is
-- not, or was not, a member of that trip.
--
-- chat_reads — how far each person has read each conversation (✓✓, unread
--   badges). Cascades with the user and the outing.
--
-- outings.chat_seq — the per-outing counter behind seq.
-- users.chat_push  — «رسائل المحادثة» notifications on/off (default on).

CREATE TABLE IF NOT EXISTS sary.chat_messages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  outing_id       uuid NOT NULL REFERENCES sary.outings(id) ON DELETE CASCADE,
  seq             bigint NOT NULL,
  conv            text NOT NULL CHECK (conv = 'group' OR conv ~ '^[0-9a-f-]{36}:[0-9a-f-]{36}$'),
  sender_id       uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  recipient_id    uuid REFERENCES sary.users(id) ON DELETE CASCADE,
  client_id       text NOT NULL CHECK (char_length(client_id) BETWEEN 1 AND 64),
  kind            text NOT NULL CHECK (kind IN ('text', 'quick', 'location')),
  body            text CHECK (body IS NULL OR char_length(body) <= 1000),
  lat             double precision CHECK (lat IS NULL OR lat BETWEEN -90 AND 90),
  lng             double precision CHECK (lng IS NULL OR lng BETWEEN -180 AND 180),
  label           text CHECK (label IS NULL OR char_length(label) <= 60),
  created_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  deleted_by_role text CHECK (deleted_by_role IS NULL OR deleted_by_role IN ('self', 'leader')),
  CONSTRAINT chat_messages_direct_shape CHECK ((conv = 'group') = (recipient_id IS NULL)),
  CONSTRAINT chat_messages_seq_unique UNIQUE (outing_id, seq),
  CONSTRAINT chat_messages_client_unique UNIQUE (sender_id, client_id)
);
CREATE INDEX IF NOT EXISTS chat_messages_conv_idx ON sary.chat_messages (outing_id, conv, seq DESC);
CREATE INDEX IF NOT EXISTS chat_messages_recipient_idx ON sary.chat_messages (recipient_id) WHERE recipient_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS sary.chat_reads (
  outing_id  uuid NOT NULL REFERENCES sary.outings(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES sary.users(id) ON DELETE CASCADE,
  conv       text NOT NULL,
  last_seq   bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (outing_id, user_id, conv)
);

ALTER TABLE sary.outings ADD COLUMN IF NOT EXISTS chat_seq bigint NOT NULL DEFAULT 0;
ALTER TABLE sary.users ADD COLUMN IF NOT EXISTS chat_push boolean NOT NULL DEFAULT true;

ALTER TABLE sary.chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE sary.chat_reads    ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON sary.chat_messages, sary.chat_reads FROM %I', r);
    END IF;
  END LOOP;
END $$;
