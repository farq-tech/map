# Nearby link (phone to phone) — «عبر الأجهزة القريبة»

When mobile data drops in the desert, cars of the same outing keep seeing each
other over MultipeerConnectivity (Bluetooth + peer-to-peer Wi-Fi). Code:
`Sources/Mesh/` (`MeshCrypto.swift`, `MeshStore.swift`, `NearbyMesh.swift`),
wired in `OutingSession` and shown by `LiveOutingPresenter`. Tests:
`Tests/NearbyMeshTests.swift`.

## When it runs

* Only while the sharing gate is open (`SendGate.allowsPosition`: consent on this
  device, iOS permission, «شارك موقعي» pressed, server sharing on, outing active,
  app in the foreground). Stopping sharing turns it off at once and first sends a
  `stop` event, so nearby phones drop your position.
* And only when it is needed (`MeshActivation`): this phone's server link has been
  down for 8 s, or a sharing friend is «انقطع» on the server. It keeps running for
  90 s after things are fine again.
* Nothing received over the nearby link is ever sent to the server.

## Security

* **Key.** The root key is `mesh_key` from the outing payload when the server sends
  one. Until then it is an interim key: HKDF-SHA256 over the outing id, a v4 UUID that
  only the server and the outing's members ever see. The encryption key, the
  discovery key and the per-member keys are separate HKDF sub-keys of that root.
* **Frames.** The content is AES-GCM. The AAD binds the version, the outing tag, the
  sender, the message id and the send time. Each frame also carries an HMAC-SHA256
  under the sender's member key (root → `member|<user id>`). A frame is accepted only
  if the sender is on the cached member list and every check passes.
* **Limits.** Frames over 16 KB are refused. Each nearby phone may send a burst of 6
  frames, then about one a second. A payload may hold at most 32 positions and 32
  events, with text of at most 80 characters. A phone that sends 5 bad frames is
  disconnected.
* **Replay.** A message id is never accepted twice. Frames outside a ±10 min window
  are refused. A sender's clock may step back by 30 s at most. The replay guard only
  records a frame after it authenticates, so a forged frame cannot block the real one.
* **Discovery.** The Bonjour tag is an HMAC of a 15-minute window and rotates. The
  peer name is a random string. Neither carries a name or the outing id.
  MultipeerConnectivity's own encryption is set to `.required` as well.
* **Members only.** Positions and events are accepted only about members on the
  cached list. A hop-0 fix must be the sender's own position. My own position never
  comes back to me.

### Limit of the interim key (what the server should add)

Anyone who has ever known the outing id can derive the interim key. That includes a
member who was removed and the server itself. The member list still stops removed
members from appearing as themselves. But a past member who keeps the key could pose
as a current member, because the member tags all derive from the same shared root.

**Server change to request:** in the outing payload for members only (`GET /:id`,
the live snapshot), add `mesh_key`: 32 random bytes, base64url, stored per outing.
Rotate it when a member leaves or is removed, and expose `mesh_key_prev` for a
grace period so that phones which have been offline still overlap. The app already
decodes `mesh_key` and prefers it (`MeshKeys.Source.server`). For real
member-to-member authentication, the server should also issue each member an
Ed25519 key pair and publish the public keys in the member list, so that frames are
signed rather than tagged with a shared-root HMAC.

## What travels and how it shows

* **My latest fix** (hop 0). It carries lat, lng, accuracy, heading, speed, the
  original time `at`, and `age` measured on the sending phone.
* **Relays.** These are other members' latest fixes. Each relay adds one hop, and a
  fix travels at most 3 hops. `at` is kept unchanged, and `age` grows with every hop.
  Freshness comes from `age`, so another phone's clock cannot make an old fix look
  live. Fixes older than 30 minutes are dropped.
* **Events** (`note`, `sos`, `sosClear`, `stuck`, `stuckClear`, `stop`). They are
  deduplicated by id, relayed up to 3 hops, and re-sent for 30 minutes so a car that
  comes into range later still receives them.
* **Overlay** (`MeshStore.overlay`). The newest data wins over the server's picture.
  A nearby position goes through the normal `Policy.freshness` rules, so an old
  relayed fix shows as «آخر موقع» with its real age, plus the
  «عبر الأجهزة القريبة» mark.
* **Status capsule.** It shows «متصل مباشرة بـ ٢ سيارات». This counts only members
  whose own phone was heard in the last 30 s.
* **When data returns.** Normal server flow resumes. A newer server fix replaces the
  nearby one and the mark disappears. A note heard nearby and then from the server
  shows as one alert. A server «أنا بخير» clears a copy of the SOS heard nearby.
  Notes and SOS sent while offline went nearby only and are not queued for the
  server, so they are never sent twice.

* **«قناة الطلعة» voice** (`MeshVoice.swift`). When the server cannot be reached
  and a member's phone is connected directly, the walkie-talkie sends its live
  AAC-ELD frames over the same session. A voice frame starts with `0xA1` (JSON
  frames start with `{`) and is compact binary: outing tag, sender clock, sender
  id, then an AES-GCM box. The key is derived from the **sender's** member key
  (`ptt-voice`), and the whole header is the additional data. Audio goes
  unreliably and start/stop go reliably, to direct neighbours only. Voice is
  never relayed, because a hop adds too much delay. Frames older than 5 s are
  dropped. A separate limiter allows 50 frames/s with a burst of 80. Floor
  control has no server here: you may talk if nobody nearby was heard in the
  last 1.5 s, and if two people press at once, the lower user id keeps the
  floor. Nothing is recorded.

## Proof

| What | How | Status |
|---|---|---|
| Keys, seal/open, tamper, non-members, other outings, size, rate | unit tests | proven |
| Replay, old and future frames, forged frame does not poison the guard | unit tests | proven |
| Hop rules, ≤3 hops, original time kept, age grows | unit tests | proven |
| Dedup of events and fixes, `stop` tombstone | unit tests | proven |
| Staleness: old relay never live, clock skew immune, server newer wins | unit tests | proven |
| Gate: off without consent, off at once on stop | unit tests | proven |
| Discovery + encrypted exchange between two app instances | two iPhone 17 Pro Max simulators (`-demo -SaryMeshTest -SaryOffline`, B with `-SaryDemoMe`) | proven on simulators (`docs/app-shots/mesh-*.jpg`) |
| SOS / note delivered live between instances | — | not shown on simulators (unit tests only) |
| «قناة الطلعة» voice between two app instances, no server | same two simulators, `-SaryPTTTone` test tone, `-SaryPTTAutoTalk` | proven on simulators: 163 frames decoded on B at 440 Hz, 0 gaps |
| Bluetooth-only and AWDL range, battery, background behaviour, 3-car relay | — | **needs real devices in the desert** |

On the simulators the connection uses the Mac's network (Bonjour over loopback or
infrastructure), not Bluetooth. Range, radio behaviour and the Local Network
permission prompt can only be proven on real phones.
