# «أماكن مقترحة للكشتة» and «مخطط دروب البر»

Candidate camp sites and an off-road cost grid for three pilot regions, built from **open data
only**. The app bundles the output (`apps/ios/SaryAlbarq/Resources/CampSites/`), ranks the sites with
tonight's wind on the phone, and routes over the grid offline.

**Not Mapbox, Google or Esri imagery.** The Mapbox terms forbid deriving data from its tiles
(`apps/ios/SaryAlbarq/docs/AI-SATELLITE.md`). Nothing here reads them.

## Sources and licences (checked 2026-11-06)

| Data | Use | Licence | Attribution (in «حول») |
|---|---|---|---|
| ESA WorldCover 10 m 2021 v200 (`s3://esa-worldcover`, AWS Open Data) | built-up, water, wetland, shrubs and trees | CC BY 4.0 | © ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium |
| Copernicus DEM GLO-30 (`s3://copernicus-dem-30m`) | slope, flow accumulation (wadis), sinks, height above channel, shelter, sunset horizon, dune-ridge axis | "COP-DEM-GLO-30-F Full, Free & Open" licence (ESA, CDSE licence PDF v2, 2025-06): reproduction, distribution, adaptation, free of charge, no non-commercial clause; notice required (Art. 6) | produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved |
| Sentinel-2 L2A COGs (`s3://sentinel-cogs`, Earth Search STAC) | spring NDVI (greenery), dry-season colour for sand / gravel / sabkha | Copernicus Sentinel data terms: free, full and open, commercial use allowed | Contains modified Copernicus Sentinel data 2025–2026 |
| OpenStreetMap, Geofabrik `gcc-states` extract | tracks, paved roads, settlements, protected areas, military, wetlands, named places | ODbL 1.0 | © OpenStreetMap contributors |
| Open-Meteo forecast + air quality (live, in the app) | wind, gusts, direction, rain, dust / PM10 tonight | data CC BY 4.0; **the free API is non-commercial only** (same caveat as the existing weather card, `Sources/Weather/WeatherProvider.swift`) | Weather data by Open-Meteo.com |

Night lights (VIIRS / Black Marble) need an Earthdata login, so they are not used. Dark sky is a
proxy instead: sky glow from Walker's law (population × distance^-2.5) over OSM settlements plus a
small table of big cities (`build.py`, `MAJOR`).

Exact files, S3 ETags and Sentinel-2 scene ids per region: `sources/<region>.json`.
OSM extract used: `gcc-states-latest.osm.pbf`, 2026-11-05, md5 `cb03483531368b427c67ec75bf63cb35`,
sha256 `cea7a4c620ffdd5afc89006e0538391b4fc37990f2f4ffb801a103362b564c6c`.

## Method (rules-v1, `model.py`)

The grid is 2 arc-seconds (~56 × 62 m). No learned model: each number traces to a rule, and each
rule has a Najdi reason.

**Hard exclusions** (a cell that fails one is never a candidate): the flood buffer of every
drainage channel with ≥ 0.5 km² upstream (75 m + 60 m per decade of catchment), closed hollows
deeper than 0.5 m (1.5 m on dune sand, where rain soaks in), sabkha (Sentinel-2 rule or
WorldCover / OSM wetland), slope > 8 %, water, built-up, < 1.5 km from a village / farm, < 500 m
from a paved road, < 1.5 km from a military area, > 6 km from any track or road, standing on
vegetation (spring NDVI > 0.25).

**Axes** (0..1): comfort (flatness, drainage, firm ground for the cars nearby, soft sand to sit
on), beauty (sunset horizon open to 245°–295°, a view, dark sky, greenery within 400 m, quiet,
a known place from OSM names: rawdah / faydah / nafud / erg, moderate weight), access (track at
0.1–2 km best), safety (scale after the gate: distance to channels, height above them).

**Shelter**, per wind direction: the elevation angle of the terrain upwind within 350 m seen
from a sitting person (9° = full), plus shrubs / trees upwind. Eight values per site.

**Tonight's ranking** (the app, `CampRanker`, mirrors `model.total_score`): weighted mean of the
axes with the wind's weight rising from 0.25 (calm) to 0.6 (gusts ≥ 50 km/h), the shelter taken
for tonight's actual direction, times a safety factor. Rain tonight keeps only sites ≥ 2 m above
and ≥ 300 m from the nearest channel. Gusts ≥ 35 km/h or dust: a warning and sheltered sites
first; ≥ 50 km/h: «ما ننصح بالكشتة الليلة في المكشوف».

**Learned model?** Not now. The spectral rules separate red dune sand, darker gravel and white
salt crust well enough in these regions, and they stay explainable. A small Sentinel-2
classifier (e.g. Prithvi-EO, Apache-2.0) is worth trying only once there is ground truth
(«خيّمنا هنا وكان زين» feedback, labelled sabkha). No AGPL code is used.

## Routes (`routes.py`)

A ~90 m grid (3″) per region: ground class (firm, sand, dune crest, sabkha, wadi, rock,
forbidden), OSM track / paved bits, a big-wadi bit, the dune-ridge axis (structure tensor of the
DEM) and elevation. Cost per metre: the ground's effort × crossing the grain (up to ×2.6) × grade
(refused above 32 %). Tracks are cheap. With rain, big wadi beds (≥ 5 km²) are refused and small
channels cost 3×. A* gives «الأسهل» (effort), «الأقصر» (distance) and «المتوازن» (√effort).
The app runs the same A* (`DesertRouter.swift`).

## Regenerate

```sh
scripts/camp-sites/regen.sh /path/to/work-dir            # all three regions
scripts/camp-sites/regen.sh /path/to/work-dir nafud      # one
```

Tests: `python -m pytest scripts/camp-sites/tests -q` (rules, wadi-bed exclusion, shelter by wind,
router). Pictures: `render.py` (sites over Sentinel-2 + hillshade), `render_routes.py`.

## Routes for the whole Kingdom (national tiles)

The three pilot grids stay bundled in the app (offline seed). The rest of the Kingdom is served as
1° × 1° tiles of the same SARYRT1 grid (3″, ~90 m) that the app downloads only for the corridor it
routes through.

- **Names**: `routes-t{lat}_{lng}.bin`, the tile's south-west corner in integer degrees
  (`t25_46` = 25–26 N, 46–47 E). `tiles.py list` gives the tiles that touch the Kingdom
  (a coarse outline in `regions.py`, buffered 0.5°; `--boundary ksa.geojson` for an exact one):
  **240 tiles** with the built-in outline.
- **No overlap, haloed computation**: each tile is computed on its bbox grown by 0.05°
  (`TILE_HALO_DEG`: 60 route cells) so slopes, ridge axes, distances to tracks and the 2×2
  coarsening see their neighbours, then cropped to the exact degree square. Every tile sits on one
  global lattice (cell edges at multiples of 1/1200°), as do the pilot grids, so the app stitches
  any set of them by lattice index (`DesertGrid.stitch`). Known limit: flow accumulation only sees
  the halo, so a very large wadi can be under-sized right at a tile edge.
- **manifest.json** (`tiles.py manifest`): format, version, arcsec, tile_deg, halo_deg, attribution
  (Copernicus, ESA WorldCover, Sentinel-2, © OpenStreetMap contributors), built_from (datasets, OSM
  extract md5), and per tile `id`, `bbox`, `bytes`, `sha256` (of the served zlib file), `rows`, `cols`.
  The app refuses a tile whose sha256 differs from the manifest.
- **Tiles only route**: `build.py --route-layers` computes just what `routes.py` reads (no
  camp-site shelter / sunset / dark-sky layers).

### Run it (cloud machine)

```sh
scripts/camp-sites/national.sh /mnt/work 16 2026-11-10    # work dir, parallel tiles, version
```

`national.sh` (bash, Linux) creates a venv from `requirements.txt`, downloads and md5-checks the
Geofabrik `gcc-states` extract, lists the tiles, extracts OSM for all of them in one pass, then per
tile (in parallel, resumable: an existing `routes-<tile>.bin` is skipped) runs `fetch_rasters.py` →
`build.py --route-layers` → `tiles.py build`, deletes that tile's rasters, and finally writes
`manifest.json` and runs the tests. Failed tiles are listed in `logs/failed.txt`; rerun to resume.

Sizing (**estimates**, not measured on a national run):

| | estimate |
|---|---|
| machine | 16–32 vCPU, 64 GB RAM, Linux x86_64, good bandwidth to AWS eu-central-1 (where the COGs live) |
| memory per tile | ~3–4 GB peak (11 880² WorldCover read, priority flood on ~2 000² cells); `jobs` ≈ RAM / 4 GB, ≤ vCPU/2 |
| OSM pass | ~8–16 GB RAM, 20–60 min for all tiles at once |
| time per tile | 10–25 min (network reads of DEM / WorldCover / Sentinel-2 + pure-Python priority flood) |
| total | 240 tiles × ~15 min / 16 jobs ≈ **4–6 h** |
| disk | ≥ 40 GB free (OSM extract 0.3 GB, per-tile cache up to ~1 GB while it runs, deleted after) |
| output | ~2.5–4 MB per tile (pilots: 0.5–1.5 MB for 0.2–0.5 deg²) → **~0.6–1 GB** in total |

### Upload

The tiles server (`apps/tiles/serve.py`) serves `GET /desert/manifest.json` and
`GET /desert/tiles/<id>.bin` from `DESERT_DATA_DIR` (default `$TILES_DATA_DIR/desert`, i.e.
`/data/desert` on the Railway volume). Either

1. copy `out/desert/` onto the service's volume at `/data/desert/` (tiles first, `manifest.json`
   last, so the app never reads a manifest naming a tile that is not there yet); or
2. sync it to an object bucket that serves public HTTPS (tiles first, then `manifest.json`) and set
   `DESERT_PUBLIC_BASE=https://<bucket-host>/desert` on the service: both endpoints then redirect there.

The app derives the base URL from `FarqTilesURL` (`…/farq.json` → `…/desert/`).
