# «إذاعة الطلعة» — shared trip audio

What the whole trip listens to, together, **while navigating**: in the
background, with the screen locked, and through the car speakers
(Bluetooth / CarPlay audio route).

| | «إذاعة الطلعة» | «يوتيوب» (Sources/Media) |
|---|---|---|
| Plays in the background / screen locked | yes (`audio` background mode) | no (YouTube terms) |
| Car speakers, CarPlay now-playing, steering-wheel buttons | yes | no |
| Video | no | yes, foreground only, official player |
| Sync | live stream (natural) or server clock | server clock |

In the app the media sheet shows «إذاعة الطلعة» first, with the note
«يوتيوب يشتغل والتطبيق مفتوح فقط (شرط يوتيوب)؛ للسيارة استخدم إذاعة الطلعة».

## How it works

* **The server never touches audio.** It keeps one small state per trip —
  *what* plays and *where* it is — in memory, written through to
  `sary.group_audio` (migration `014_sary_group_audio.sql`, additive) so a
  restart or a late joiner still finds it. Every phone fetches the source
  itself with `AVPlayer`. Nothing is proxied, recorded or rebroadcast.
* **Wire** (`apps/api/lib/outings/group-audio.js`):
  * `GET  /api/outings/:id/group-audio` → `{ group_audio, can_control, server_now }`
  * `POST /api/outings/:id/group-audio` `{ action, item?, position_s?, value? }`
  * WebSocket `/api/outings/live`: `→ group_audio_cmd { id, cmd }` ·
    `← group_audio_ack { id, ok, state | reason }` · `→ group_audio_sync` ·
    `← group_audio_state { state, server_now }` (to everyone after every change).
  * The `ready` snapshot and `GET /:id` carry `group_audio`, so a member who
    joins late (or reconnects) starts in sync immediately.
  * `GET /api/outings/group-audio/catalog` — the station list (public, cached 1 h).
* **Actions**: `play_item`, `play`, `pause`, `seek`, `next`, `stop`,
  `queue_add` (≤ 20), `allow_all`.
* **Who**: the trip leader (owner) and co-leaders control everything. With
  «الكل يقدر يشغّل» (`allow_all`, leader only) every member may. Anyone may
  suggest (`queue_add`). Muting («اسكت عندي») and leaving are local to the
  phone; the server never knows who listens.
* **Safety**: a radio station is sent by **id** only; its URL always comes from
  the server's catalog, so nobody can make every phone fetch an arbitrary URL.
  Quran files must match `https://cdn.mp3quran.net/audio/<reciter>/rN/NNN.mp3`
  (or `serverN.mp3quran.net`). Audius items are track ids only. Titles are
  cleaned (control and bidi-override characters removed, ≤ 100 characters).

## Sync

* **Live radio**: every phone plays the same live stream, so everyone hears
  the same programme. HLS edge latency differs a little between phones
  (typically 2–10 s, depending on the CDN segment each phone starts on);
  no correction is attempted for live audio — it is "the same station".
* **Files (Quran surah, Audius track)**: the server keeps
  `position_s` valid at `at` (server time). A phone computes
  `expected = position_s + (serverNow − at)` while playing, with
  `serverNow = deviceNow + clockOffset` (offset measured from `server_now` on
  every HTTP reply and from the socket's `pong`). Drift correction
  (`GroupAudioSync.plan`): |drift| ≤ 0.3 s → nothing; 0.3–3 s → a short rate
  nudge (0.95× / 1.05×) until back inside ±0.3 s; > 3 s → seek. Expected
  accuracy between phones on good mobile data: ±300 ms plus the clock-offset
  error (≈ half the round-trip, usually < 150 ms).

## Ducking and interruptions (iOS)

* The music uses `AVAudioSession` `.playback` (no `mixWithOthers`, so it owns
  the lock screen / CarPlay now-playing and the steering-wheel buttons).
* Turn-by-turn voice (`NavVoice`) and push-to-talk (`PTTRoute`) tell
  `GroupAudioDuck` when they speak: the music volume drops to 20 % (nav) or
  is paused (PTT receiving/transmitting — the session switches to
  `.playAndRecord`), then is restored and the session re-asserted afterwards.
  `NavVoice` no longer deactivates the session while «إذاعة الطلعة» plays
  (that would have stopped the music).
* A phone call / Siri / another app's interruption pauses; on `.ended` with
  `shouldResume` (or when our own PTT/nav caused it) the music resumes and a
  file seeks back to the shared position.
* `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`: play/pause/next from the
  lock screen, CarPlay now-playing and steering-wheel buttons. For the
  controller they send the command to the whole trip; for a member they mute
  / unmute locally.

## Sources and licences

Checked 2026‑11‑05. All are free to listen to, and every phone plays the
publisher's own public stream directly from the publisher's servers.

### Live stations (catalog: `apps/api/lib/outings/group-audio-catalog.js`)

| id | Station | Stream host | Where it is published | Notes |
|---|---|---|---|---|
| `sba-quran` | إذاعة القرآن الكريم (مكة المكرمة) | `live.kwikmotion.com/sbrksaquranradiolive/…` | Saudi Broadcasting Authority (هيئة الإذاعة والتلفزيون), «الأولى» platform aloula.sa/ar/live/quranradio; also radio-browser.info | KwikMotion is the CDN SBA uses for its live channels. |
| `sba-nidaa` | إذاعة نداء الإسلام | same CDN | aloula.sa (channel 14) | |
| `sba-riyadh` | إذاعة الرياض | same CDN | aloula.sa/ar/live/riyadhradio | |
| `sba-jeddah` | إذاعة جدة | same CDN | aloula.sa/ar/live/jeddahradio | |
| `sba-saudia` | راديو السعودية | same CDN | aloula.sa/ar/live/saudiaradio | |
| `sba-khuzama` | إذاعة خزامى | same CDN | aloula.sa/ar/live/khuzamaradio | |
| `mp3quran-mix` | إذاعة mp3quran (تلاوات متنوعة) | `qurango.net/radio/mix` | mp3quran.net radio list / API | mp3quran publishes these radio streams openly in its API for apps; we credit «mp3quran.net». Confirm the current terms with mp3quran before scale. |
| `mp3quran-tarateel` | تراتيل قصيرة | `qurango.net/radio/tarateel` | mp3quran.net | as above |
| `mbc-fm` | MBC FM | `radio-mbcfm.mbc.net` | MBC's own stream host; radio-browser.info | MBC publishes the stream for its own players; public, not DRM'd. |
| `panorama-fm` | بانوراما FM | `radio-panoramafm.mbc.net` | MBC | as above |
| `mbc-loud` | MBC Loud FM | `radio-loud-fm.mbc.net` | MBC | as above |
| `alarabiya-fm` | العربية FM | `fm.alarabiya.net` | alarabiya.net/ar/fm | |
| `ufm` | UFM 95.5 | `stream.ufmradio.com:8003` | ufmradio.com | |

**Licence position.** We do not host, copy or rebroadcast any audio; each phone
opens the station's own public stream, exactly as the station's website does.
This is how mainstream directory apps (radio-browser.info, TuneIn-style apps)
work. It is **not** an explicit licence: before promoting the feature widely,
the owner should send each broadcaster a short note (SBA, MBC, Al Arabiya,
UFM) and drop any station that objects — removing a station from the
server's catalog takes effect at once (`GET …/group-audio/catalog`), the app's
bundled copy is only a fallback. Not included on purpose: streams on
third-party relays (zeno.fm, shoutca.st re-uploads), plain-HTTP streams, and
anything without a clear publisher.

### Quran recitations (synced files)

* `https://cdn.mp3quran.net/audio/<reciter>/<moshaf>/NNN.mp3` from
  **mp3quran.net** (API v3, `https://www.mp3quran.net/api/v3/reciters`).
  mp3quran publishes the API openly for apps and websites, free of charge; the
  app shows «المصدر: mp3quran.net». We found no written licence text in the API
  itself — the owner should confirm non-commercial in-app use with mp3quran.
* The app ships a short curated list of reciters with complete 114-surah
  moshafs (السديس، الشريم، المعيقلي، العفاسي، الدوسري، عبدالباسط، المنشاوي،
  سعد الغامدي، بندر بليلة).

### Audius (synced tracks)

* **Audius** (`https://api.audius.co/v1`) — free, open API; artists upload to
  Audius and opt in to streaming through third-party apps. Requirements we
  follow: send `app_name=SaryAlbarq` on every call, stream only tracks the API
  returns as streamable (no downloads, no caching of files), show the artist
  and track name, and link to the track on audius.co. Review the current
  Audius API terms (docs.audius.org → API → terms) before each release.

### Not used, on purpose

* No commercial-music files streamed or stored by us; no YouTube audio
  extraction; nothing behind a login or DRM.

## What needs a real car test

* CarPlay now-playing tile and steering-wheel next/previous/play-pause.
* Bluetooth A2DP car audio while turn-by-turn speaks (ducking level) and while
  push-to-talk receives (pause → resume, route back to A2DP after HFP).
* Screen locked for 30+ min on mobile data in weak coverage (HLS stall →
  automatic reconnect), tunnel / no-signal recovery.
* Two or more phones in different cars on the same Quran surah: perceived
  offset (target ±0.3 s).
