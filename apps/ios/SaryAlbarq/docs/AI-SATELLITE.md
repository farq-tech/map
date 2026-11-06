# «صور عالية الوضوح» — on-device satellite enhancement (internal)

> **Internal document.** The user-facing name is neutral by owner decision: «صور عالية الوضوح».
> No string in the app says "AI" or «ذكاء». The one disclosure is the toggle subtitle
> «قد تتضمن الصورة تفاصيل تقديرية عند التقريب» plus the «مُحسّنة» badge.
> The **licensing risk** below was raised with the owner before he decided to ship this
> (owner: «اعتمد هذه»). The remote kill switch exists so it can be turned off at once.

## 1. What it does

When the map is zoomed past the depth where Mapbox Satellite has real detail, the app
enhances the tiles on screen with **Real-ESRGAN x4plus** (BSD-3-Clause, 16.7 M parameters)
running in Core ML on the device. The original imagery always shows first. The enhanced
tile crossfades in over it when ready.

| | Desert | Cities (12 boxes in `HiResZoom.cities`) |
|---|---|---|
| Real detail ends at tile | z17 | z19 |
| Layer allowed from map zoom | 16 | 18 |
| Enhanced tiles | z17 and deeper | z19 and deeper |
| Parent of an enhanced tile (one level up, never a blurry level, at most 2 up) | z17←z16 (×2), z18←z17 (×2), z19←z17 (×4), z20←z18 | z19←z18 (×2), z20←z19 (×2), z21←z19 (×4), z22←z20 |

The owner chose (build 12) to start **one level before** the imagery goes soft, with "a
clearly noticeable enhancement". So at desert z17 and city z19 the enhanced tile replaces
a tile that still had real detail. The enhanced layer also gets a mild grade
(`raster-contrast` 0.1, `raster-saturation` 0.1, `raster-brightness-min` 0.02). The
original imagery underneath is untouched, and holding the badge shows it.

Pipeline (`Sources/Map/AIEnhance/`):

1. `HiResImagery` adds a Mapbox `CustomRasterSource` (`@_spi(Experimental)`, tileSize 512,
   z17–22) and a `RasterLayer` in slot `bottom`, i.e. above the satellite imagery and
   below roads, labels and our own layers. `raster-fade-duration` 250 ms gives the crossfade.
2. Tile callbacks: `required` queues the tile. `optional` is answered from RAM only.
   `notNeeded` drops queued work and clears the tile.
3. The parent tile is fetched from `api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}@2x.jpg90`
   through an **ephemeral** URLSession (no URL cache, no disk). Max 4 in flight.
4. One serial `.utility` queue runs inference, newest visible tile first. The step is: crop
   256 px (×2) or 128 px (×4, doubled to 256) → model 256→1024 → Lanczos to 512.
5. `HiResTileCache` is RAM-only LRU: 40 MB of enhanced tiles (≈40 tiles) and 8 MB of raw
   JPEG parents. Both are purged on memory warning. **Nothing is persisted.**

Files:

| File | Role |
|---|---|
| `HiResGate.swift` | Pure rules: `HiResPolicy` (gating), `HiResZoom` (zoom/region/tile plan), `HiResVisibleSet` (badge). Unit-tested. |
| `HiResImagery.swift` | Map controller: source/layer, tile callbacks, fetch, inference loop, badge view, hold-to-compare |
| `HiResEnhancer.swift` | Core ML wrapper and image conversion |
| `HiResTileCache.swift` | RAM LRU |
| `HiResSettings.swift` | User toggle (default ON) and remote flag (last known value kept) |
| `HiResViews.swift` | Layers-sheet toggle and the BSD-3 notice in «حول» |
| `HiResHosts.swift` | `LiveOutingController.hiResRequest(...)`: the live map's gating input |
| `Model/SatelliteEnhancer.mlpackage` | The model. Xcode compiles it to `SatelliteEnhancer.mlmodelc` in the app. |
| `Model/Real-ESRGAN-LICENSE.txt` | BSD-3-Clause text, shown in «حول سَرى البارق ← مصادر ← نص الرخصة» |

Hooks in existing files, one line each: `OutingMapboxView.hiRes` and its `update`,
`LiveOutingScreen` (passes `controller.hiResRequest`), `TrackMapView.hiRes` and its `update`,
`TrackDetailView` (`.trackDetail`), the layers sheet (`HiResLayerSection()`), and
`AboutView` (`HiResLicenseNotice()`).

## 2. Where it is on / off

On: exploration (where saved places and the place brief live), the point card over the live
map, and full-screen track detail (opened from the trip summary or the track library).

**Always off, showing the original imagery:** turn-by-turn navigation; follow mode
(«اسلك هذا المسار»), «طريق العودة» and «موقعي» camera follow; SOS (mine or incoming);
speed over 15 km/h (last fresh GPS fix); non-satellite layers; the normal trip map; the
trip-summary thumbnail.

**Paused** (drawn tiles stay, no new inference): Low Power Mode, thermal state `.serious` or
`.critical`.

Off also when the user toggle is off, the server flag is off, or the model is missing.
All of this is decided in `HiResPolicy.decide`, and the reasons are listed in
`HiResDecision.Reason`.

## 3. UI

- Layers sheet («الطبقات» → «الصورة»): **«صور عالية الوضوح»**, default ON, subtitle
  «قد تتضمن الصورة تفاصيل تقديرية عند التقريب». Accessibility id `explore-hires`.
- Map badge **«مُحسّنة»** (top centre, under the top chrome) shows while any enhanced tile is
  on screen. Holding it shows the original («الأصلية») until released. Accessibility id
  `hires.badge`.
- «حول سَرى البارق» → «مصادر»: the Real-ESRGAN copyright line and the full BSD-3-Clause text.

## 4. Kill switch

`GET /api/outdoor/app-config` (server PR, additive):

```json
{ "version": 1, "hiResImagery": { "enabled": true } }
```

- **To turn it off for everyone:** set `HIRES_IMAGERY_ENABLED=0` on the Railway API
  service and redeploy or restart. Clients pick it up at launch and on every return to
  the foreground (at most every 15 min; the response has `max-age=60`). The layer is
  removed immediately, mid-session.
- If the endpoint is unreachable or the answer is malformed, the client keeps the last known
  value. The initial value is ON. It is stored in `UserDefaults` key `sary.hires.remote.v1`.
- Turning it back on: unset the variable or set it to `1`.

## 5. Mapbox terms risk (read before every release)

Mapbox Product Terms, version of **20 October 2026**:

| Clause | Restriction (short quote) | How this feature touches it |
|---|---|---|
| **1.5(i)** | shall not "modify, create derived works from…" the Service Offerings | The enhanced tile is a modified derivative of Mapbox imagery. |
| **1.5(ii)** | shall not "use the Service Offerings to train, operate or improve machine-learning or artificial intelligence" | Running a super-resolution model on the tiles is "operating" ML on them. |
| **2.8.1** | caching limited to 30 days on the same device; no distribution "by proxying" | We cache in RAM only (minutes) on the same device and never proxy, so this is lower risk. |
| **2.8.2** | shall not "use Mapbox's satellite and/or aerial imagery to… enhance any imagery" | Direct conflict. |
| **2.9.1** | use the Mobile SDKs "as Customer's exclusive means of accessing the Service Offerings" | Parent tiles are fetched with URLSession to feed `CustomRasterSource`, outside the SDK's own renderer. |

**Assessment (engineering, not legal advice):** without a written amendment from Mapbox this
use conflicts with 1.5(i), 1.5(ii), 2.8.2 and 2.9.1. Possible consequences include
suspension of the Mapbox account, which would take down every map in the app.
Mitigations in place: on-device only, RAM only, no training, safety gating, the user
toggle, and the remote kill switch. Recommended action: **send the permission request**
(draft: `docs/AI-SATELLITE-permission-email.md`, Arabic + English, *not sent*). If Mapbox
says no, set `HIRES_IMAGERY_ENABLED=0` and remove the feature in the next build.

Another known risk, product safety: the model **invents plausible detail**. The prototype
showed tufts of grass, cracks and a "wall edge" on the Huraymila shuaib, and leaves painted
on desert shrubs. Ground-truth PSNR is 4–10 dB worse than plain bicubic. This is why the
feature is never on while navigating, following or moving, and why the toggle discloses
«تفاصيل تقديرية».

## 6. Model and app size

- Source: `RealESRGAN_x4plus.pth` (GitHub release v0.1.0, sha256
  `4fa0d389…82f1`). Converted with `scripts/ai-sat/convert.py`: mlprogram, fp16,
  iOS 17, image in (256×256 RGB) and image out (1024×1024).
- An input that enumerates 128 and 256 crashed BNNS on the CPU path (macOS 27), so the
  model uses a **fixed 256** input.
- Shipped **in the bundle** (decision: smaller than 40 MB, no CDN, no Background Assets
  server). The repo does not use git-lfs, so the `.mlpackage` is committed. Size and app
  impact: see §7.
- Rebuild: see the header of `scripts/ai-sat/convert.py`. Swap the package and keep
  the name `SatelliteEnhancer`.

## 7. Performance

Measured 2026-11-05. One display tile = crop → model 256→1024 → Lanczos to 512.

| Where | Compute | Per tile (median) | Notes |
|---|---|---|---|
| Mac M4 Pro, Swift bench (`scripts/ai-sat` model) | **ANE** (`cpuAndNeuralEngine`) | **142 ms** (p90 144) | first load 2.5 s (ANE compile, cached by the OS afterwards) |
| Mac M4 Pro | GPU | 314 ms | load 0.3 s |
| Mac M4 Pro | all units | 168 ms | |
| iOS 27.2 simulator, unit test | CPU only (no ANE in the simulator) | 2.0–2.5 s | `HiResImageryTests.testEnhancerProducesA512Tile` |
| iOS 27.2 simulator, in app | CPU only, machine shared with other simulators | 7.5–11.6 s | `tmp/hires-stats.json` (DEBUG) |

- **iPhone estimate.** The A17 Pro / A18 Pro Neural Engine is in the same class as the M4's
  (≈35 vs 38 TOPS), so expect **≈150–250 ms per tile** on iPhone 15 Pro / 16 Pro and later,
  and ≈300–500 ms on A15/A16. A full screen at over-zoom is about 8–12 tiles, so it fills
  in ≈2–3 s on a 15 Pro. While panning, only the new tiles are enhanced. Not yet measured
  on a device. To measure: Instruments → Core ML + Energy Log.
- **Memory.** App footprint 114–119 MB in the simulator with the model loaded and 3–5
  enhanced tiles. The model adds ≈35–45 MB resident. The caches are capped at 40 MB +
  8 MB and purged on memory warning.
- **60 fps.** Nothing runs on the main thread except `setCustomRasterSourceTileData`, at
  most one 512 px image per inference. Inference is serial on a `.utility` queue, and the
  original tile shows until the enhanced one fades in. Not profiled with Instruments yet;
  do that on a device before release.
- **Faster option, not used:** ×4 tiles could run a second fixed-128 model (39 ms on the
  M4 in the prototype) instead of doubling the crop to 256. That would add another 33 MB,
  so it was skipped.

### Model / app size

| | Size |
|---|---|
| `SatelliteEnhancer.mlpackage` (committed) | 33.4 MB (fp16 weights 33.4 MB + 0.65 MB graph) |
| Compiled `SatelliteEnhancer.mlmodelc` in the .app | 33 MB |
| App download size impact (zip of the compiled model; fp16 barely compresses) | **≈ +31 MB** |
| App install size impact | **≈ +33 MB** |

Bundled, not on-demand: it is under the 40 MB threshold we set, and we have no CDN.
Background Assets would need a hosting server. If size becomes a problem, move the
`.mlmodelc` to an Apple-hosted Background Asset pack and keep `HiResEnhancer.bundledURL`
as the single lookup point. A missing model already means `off(.noModel)`.

## 8. Tests and internal screenshots

- Unit tests, `Tests/HiResImageryTests.swift` (18 tests): zoom gating and the tile plan,
  navigation / follow / SOS / > 15 km/h gating, Low Power and thermal pause, LRU cache
  eviction, kill switch (default ON, keeps the last known value, server JSON parsing),
  badge state, no «ذكاء»/AI wording, model and licence bundled, and one real inference
  (512 px out). The full suite passes: 739 tests.
- UI tests, `UITests/HiResImageryUITests.swift`:
  - the badge appears in exploration at shuaib z18.6, then disappears when demo navigation starts;
  - no badge with the toggle off;
  - no badge with the remote flag off.
  Needs the network and `xcrun simctl location <udid> set 25.121,46.101`.
- Before/after shots, **internal only, do not publish** (Mapbox imagery). Run
  `testBeforeAfterShots` with `TEST_RUNNER_SARY_HIRES_SHOTS=<dir>`. Shots taken for the owner
  are in `~/code/map-wt/ai-sat-app-shots/` and cover Huraymila shuaib z18/z19, Nafud z18
  and Riyadh z19.
- DEBUG launch arguments: `-SaryHiRes on|off`, `-SaryHiResRemote on|off`,
  `-SaryHiResCam lat,lng,zoom`. DEBUG builds write `tmp/hires-stats.json` (timings and
  memory, as numbers only) and `tmp/hires-events.log` (decisions).

## 9. Known limits

- Tiles are enhanced one by one with no overlap padding, so faint seams can show at tile
  edges. Adding a 16 px context from neighbour tiles would fix this.
- The city boxes are coarse. A town outside them is treated as desert, so it is enhanced
  from z17.
- The simulator has no ANE, so its timings are CPU-only and not representative.

## 10. Desert detail round 2 (feat/desert-ai-detail)

Goal: up-close desert imagery that reads as rich natural sand (ripples, grain, relief) while
never inventing a track, road, building or landform. Three layers, from the bottom:

1. **Satellite + `SandGrade`** (PR #97, unchanged): the real photo, warm-orange grade.
2. **«صور عالية الوضوح» (AI, unchanged gating)**: Real-ESRGAN x4plus, exploration only, «مُحسّنة»
   badge. New in this round, in `HiResEnhancer.mergeDetail`:
   - **Frequency split.** Output = `blur(source) + 0.85 × (ai − blur(ai))` (blur ≈ the parent's
     pixel). Every shape, dune edge, road, shadow and colour comes from the real photo; the
     model only contributes texture finer than one source pixel. It can no longer move a
     landform or shift the `SandGrade` colour.
   - **`LineGuard`.** A gradient-constrained Hough transform scores the strongest straight edge
     in the merged tile and in the plain up-sampled source. If the tile gains a line
     (`score ≥ 0.42` and `+0.14` over the source), the tile is refused and the original
     imagery stays. Counted as `lineRejected` in `tmp/hires-stats.json` (DEBUG).
   - Still RAM-only (no disk cache): Mapbox terms §2.8 / §2.8.2 (§5 above). A disk cache of
     derived imagery would add to that risk.
3. **«تفاصيل الرمال» (`SandDetail` + `SandDetailLayer`, not AI, no badge)**: a procedural "detail
   map", the terrain-rendering technique: band-limited wind ripples (≈3.4 m, crests across a
   regional prevailing-wind field, warped, broken and patchy), sand-sheet undulation (≈8 m and
   21 m) and gravel grain, shaded from the real sun (`SunPosition`, quantised to 20°) and
   drawn as a translucent light / shade overlay (≤ 24 % alpha, mean ≈ 0, warm colours).
   - Zoom: none at z14.2, full from z17. Ripples fade out by z19.5 (one crest across a tile
     would be too close to a line). Every frequency fades out before it is under ~2 px (no moiré).
   - Cities: per-pixel `UrbanAreas` weight, nothing over a city (Riyadh unchanged).
   - Slot `bottom`, over the imagery and the AI tiles, under the hillshade, roads and labels.
   - No network, no AI, deterministic and seamless across tiles. RAM LRU 24 MB.
   - Budget: «المؤثرات البصرية» → «تفاصيل الرمال» (default on). Off in Low Power Mode. No new
     tiles at thermal `.serious`+. On while driving at 70 % strength: it is texture, never a
     shape, and the safety test below covers it.
   - Safety test: `SandDetailTests.testDetailNeverDrawsALine` renders 5 deserts × 6 suns ×
     z14–22 over plain sand, and `LineGuard` must find no line. The worst score is 0.38
     against a 0.42 threshold. A synthetic two-rut track scores 1.06.
4. **DEM relief** (existing): the two hillshade passes lit from the real sun.

Performance (measured 2026-11-06):

| What | Release, M4 Pro CPU | Debug, iOS 27.2 simulator |
|---|---|---|
| `SandDetail.render`, one 512 px tile | 5–8 ms (6 threads) | 31 ms (unit test), 47 ms median in app |
| `mergeDetail` + `LineGuard`, one AI tile | 5 ms | ≈ 0.3–0.4 s (on top of 4–8 s CPU-only inference) |
| App footprint, detail on (no AI) | | 97–123 MB |
| App footprint, AI + detail, exploration z18 | | 129–142 MB |
| Drone orbit at z16 over the Nafud (frame pacing) | | detail off: 51.0 / 56.4 fps; on: 51.5 / 54.7 fps (two runs each; noise ±3) |

Thermal state stayed `nominal` in every run (`thermal` in the DEBUG stats JSON).

Not used: SwinIR / HAT (transformers, too slow on the ANE at 256 px and not trained on aerial
imagery), diffusion SR (hallucinates structures), and a second model (app size). See the PR
for the "next round" list.
