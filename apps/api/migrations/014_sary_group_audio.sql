-- «إذاعة الطلعة» — what the trip listens to together (lib/outings/group-audio.js).
--
-- Additive only: one new table. Nothing existing is altered. Older API builds
-- never read it. The server keeps the state in memory and writes it through
-- here, so a restart or a member joining late still finds what is playing.
--
-- `state` holds only WHAT plays and WHERE: a catalog station id, a mp3quran.net
-- surah URL or an Audius track id, its title, play/pause, position, who
-- started it and the queue. No audio, no location, nothing about listeners.
-- The row goes when the trip ends (and with the trip, ON DELETE CASCADE).

CREATE TABLE IF NOT EXISTS sary.group_audio (
  outing_id  uuid PRIMARY KEY REFERENCES sary.outings(id) ON DELETE CASCADE,
  state      jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE sary.group_audio ENABLE ROW LEVEL SECURITY;
