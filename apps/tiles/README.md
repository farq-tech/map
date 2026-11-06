# Farq map tiles

Our own streets, places and buildings, drawn over the satellite imagery in the apps instead of Mapbox's roads (which lag months behind in the Kingdom).

| Layer | Source | Fresh |
|---|---|---|
| `roads` | OpenStreetMap Saudi extract (openstreetmap.fr, rebuilt daily). Arabic name first, class, desert tracks, unpaved, one-way, bridge/tunnel. Feature id = OSM way id. | every rebuild (weekly by default) |
| `places` | Farq Atlas golden directory (`targets.parquet`) | every rebuild that is given the file |
| `buildings` | Farq Atlas footprints (`buildings.parquet` from `normalize_buildings.py`), height in metres | same |

Rules encoded in `build_tiles.py`:
- **Places** leaves out four kinds of row:
  - permanently closed (the Atlas `status_policy` spellings, plus `lifecycle_state = closed`);
  - imprecise points (`location_precision` ≠ `point`);
  - rows that came from Google (`gm:` keys);
  - rows with no name.

  Temporarily closed places are kept with `temp_closed = true`. **No contact field** (phone, WhatsApp, e-mail) is ever written into a tile.
- **Busy tiles:** below the top zoom, places are capped per tile (z13: 120, z14: 600), brands first, then places with opening hours. Every place appears at the top zoom (15).
- **Building heights:** `Elevation` is read as metres when its median is ≥ 8, else as storeys × 3.2 m (the same test as `build_building_population.decide_elevation_mode` in Farq Atlas). Unknown heights stay unknown.
- **Missing columns:** an older Atlas release without some enrichment columns still builds; the missing values are empty.

Measured on the real Saudi extract (2026-11-05): 0.8 M roads → 500,684 tiles, 192 MB. It built in 67 s on 4 cores, and the largest tile is 174 KB gzipped.

## Run

```bash
pip install -r requirements.txt
python3 build_tiles.py --osm saudi_arabia.osm.pbf \
  [--places targets.parquet] [--buildings buildings.parquet] --out farq.pmtiles
python3 -m unittest test_build_tiles     # needs requirements-test.txt
```

`serve.py` serves the archive:
- `GET /farq.json`: TileJSON.
- `GET /tiles/{z}/{x}/{y}.mvt`: one tile; 204 when the tile is empty.
- `GET /healthz`

It rebuilds every `REBUILD_HOURS` (default 168) with `build.sh`, which downloads a fresh extract. A rebuild writes a new file and swaps it in only when complete; a failed rebuild keeps the previous archive live.

## Deploy (Railway)

1. New service from this repo, `railway.json` in `apps/tiles`, a volume mounted at `/data`, ≥ 8 GB RAM.
2. Variables:
   - `PUBLIC_URL`: the service's public https URL.
   - The Atlas inputs, either by path or by URL:
     - by path: `PLACES_PATH` / `BUILDINGS_PATH`, files on the volume;
     - by URL: `PLACES_URL` / `BUILDINGS_URL`, plus `ATLAS_TOKEN` if the URL needs a bearer token.
3. First boot builds before `/healthz` turns 200 (about a minute for roads).
4. iOS: set `FARQ_TILES_URL = https:/$()/<host>/farq.json` in `Config/Secrets.xcconfig` (xcconfig reads `//` as a comment). Until the app reads that TileJSON successfully it keeps Mapbox's roads, so an empty setting or a down server changes nothing.

Routing uses the same streets: Farq's Valhalla (`VALHALLA_ORIGIN` on the API) is the app's default router («تلقائي»), with Mapbox as the fallback. Rebuild its graph from the same extract to keep the two in step.
