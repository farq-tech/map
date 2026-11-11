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
- **Invalid building outlines:** a footprint is checked before tiling. Invalid geometry is repaired with `ST_MakeValid`, and only polygonal parts are kept. A repair with no polygon area is omitted, so one bad outline cannot abort the national archive build.
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
- `GET /desert/manifest.json` and `GET /desert/tiles/t{lat}_{lng}.bin`: the national «دروب البر» route
  tiles (built by `scripts/camp-sites/national.sh`), read-only from `DESERT_DATA_DIR` (default
  `/data/desert`), or redirected to `DESERT_PUBLIC_BASE` when set. Manifest cached 5 min, tiles 1 day
  (the app checks each tile's sha256 against the manifest). Independent of the vector archive.

  With `DESERT_BUCKET` set, files missing from `DESERT_DATA_DIR` are read through from the private Railway
  bucket **`sary-desert-grids`** (project `farq-targeting`, production, region ams) under `desert/`, and kept
  on disk; the manifest is re-fetched after 5 minutes. Service variables (references, not copies):
  - `DESERT_BUCKET=${{sary-desert-grids.BUCKET}}`
  - `DESERT_ENDPOINT=${{sary-desert-grids.ENDPOINT}}`, `DESERT_REGION=${{sary-desert-grids.REGION}}`
  - `DESERT_ACCESS_KEY_ID=${{sary-desert-grids.ACCESS_KEY_ID}}`, `DESERT_SECRET_ACCESS_KEY=${{sary-desert-grids.SECRET_ACCESS_KEY}}`

  Upload after `national.sh` (tiles first, `manifest.json` last, so the app never sees a manifest for tiles
  that are not there yet), with the bucket's credentials:

      aws s3 sync out/desert/ s3://$BUCKET/desert/ --endpoint-url $ENDPOINT --exclude manifest.json
      aws s3 cp out/desert/manifest.json s3://$BUCKET/desert/manifest.json --endpoint-url $ENDPOINT

`python3 -m unittest test_serve_desert` tests these endpoints.

It rebuilds every `REBUILD_HOURS` (default 168) with `build.sh`, which downloads a fresh extract. A rebuild writes a new file and swaps it in only when complete; a failed rebuild keeps the previous archive live.

## Deploy (Railway)

1. New service from this repo, `railway.json` in `apps/tiles`, a volume mounted at `/data`, ≥ 8 GB RAM.
2. Variables:
   - `PUBLIC_URL`: the service's public https URL.
   - The Atlas inputs. Simplest, with the service in the `farq-targeting` project: reference the Atlas bucket and nothing is copied (read only):
     - `BUCKET=${{farq-targeting.BUCKET}}`, and the same for `ENDPOINT`, `REGION`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`;
     - `BUILDINGS_OBJECT=${{farq-targeting.FARQ_BUILDINGS_OBJECT}}`;
     - `fetch_atlas.py` then takes the buildings and the newest `targets.parquet` in the bucket (or `PLACES_OBJECT`).
   - Or by path or by URL:
     - by path: `PLACES_PATH` / `BUILDINGS_PATH`, files on the volume;
     - by URL: `PLACES_URL` / `BUILDINGS_URL`, plus `ATLAS_TOKEN` if the URL needs a bearer token.
3. First boot builds before `/healthz` turns 200 (about a minute for roads).
4. iOS: set `FARQ_TILES_URL = https:/$()/<host>/farq.json` in `Config/Secrets.xcconfig` (xcconfig reads `//` as a comment). Until the app reads that TileJSON successfully it keeps Mapbox's roads, so an empty setting or a down server changes nothing.

Routing uses the same streets: Farq's Valhalla (`VALHALLA_ORIGIN` on the API) is the app's default router («تلقائي»), with Mapbox as the fallback. Rebuild its graph from the same extract to keep the two in step.
