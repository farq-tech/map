# «دليل البر» (desert gazetteer)

A bundled, offline list of real desert places for the home chips «نفود»، «روضة»، «فيضة»،
«مخيمات». The app reads `apps/ios/SaryAlbarq/Resources/DesertGazetteer/desert-gazetteer.json`
(`Sources/Explore/DesertGazetteer`). **Every entry comes from a source record.** Nothing here
invents a place, a name or a coordinate. The only derived values are a simplified outline, its
bounding box and a representative point inside it.

The iOS `PlaceNamer` reuses this same file for offline labels on saved and recent map points,
excluding the synthetic camp-site suggestions. It does not ship a second place list or assign a
distant town/feature to a point when the geocoder and nearby named features provide no match.
The app's About screen includes the OSM and GeoNames attributions listed below.

## Sources and licences

| Source | What | Licence | Attribution (in «حول» and under the list) |
|---|---|---|---|
| OpenStreetMap (Overpass API, or the Geofabrik `gcc-states` extract) | named `natural=sand/desert/dune`; places, natural features, meadows, protected areas and camp/picnic sites named روضة/رياض، فيضة/فياض، نفود/عرق/عروق/رملة/دهناء/طعس/نقا، الربع الخالي، الثمامة | ODbL 1.0 | © OpenStreetMap contributors (ODbL 1.0) |
| GeoNames `SA.zip` + `alternatenames/SA.zip` | feature codes DUNE, ERG, SAND, DPR, PNDI, SBKH, PLN, AREA, WAD, HLLS, LCTY, RGN… whose names are rawdah / faydah / nafud / erg (a bare DUNE/ERG/SAND is a nafud); Arabic names from the `ar` alternate names | CC BY 4.0 | GeoNames (geonames.org), CC BY 4.0 |
| `scripts/camp-sites` output (`Resources/CampSites/camp-sites-*.geojson`) | «أماكن مقترحة للكشتة»: 180 candidate camp spots in Thumamah, Dahna and the Nafud | see `scripts/camp-sites/README.md` (ESA WorldCover CC BY 4.0, Copernicus DEM, Sentinel-2, OSM ODbL) | `CampSitesAttributionNotice` |

Provenance of the last build (URLs, dates, hashes, counts): `sources.json`.

## Rules (`gazetteer.py`)

- **Kind** comes from the name's first word, normalised (no tashkeel, one alef, ة→ه, no «ال»):
  روضة/روضات/رياض → `rawda`; فيضة/فياض → `fayda`; نفود/عرق/عروق/رملة/دهناء/طعس/نقا, «الربع الخالي» → `nafud`.
  The Latin names do the same (Rawdat/Faydat/Nafud/Irq/Uruq/Ramlat…). A named OSM `natural=sand` and a GeoNames
  DUNE/ERG/SAND without such a prefix are `nafud`.
- **Not desert places**: anything with `amenity` (e.g. «روضة أطفال»), `shop`, `building`, `highway`…, settlements
  (`place=town/village/suburb…`, GeoNames PPL*), town parks, farms and admin boundaries.
- **Outlines** (OSM ways and multipolygons): Douglas–Peucker at ~1 % of the diagonal (≥ 0.002°), 4 decimals,
  ≤ 400 points per entry. Holes are dropped. The point is the centroid, or the inside point farthest from the edge.
- **Merge**: same kind + a shared normalised name (Arabic or Latin) + close (25 km for a nafud, 6 km for a
  rawdah or faydah, or inside / near the other's outline). Camp spots are never merged.
- **Stable ids**: the best source's id is kept (`osm:relation/…` > `osm:way/…` > `osm:node/…` > `geonames:…`,
  an outline first; `camp:<site id>`). Every merged source stays in `sources`. Other services (the
  rain/green search, #126) can take these ids as the place identity.

## Entry

```json
{"id": "osm:relation/123", "kind": "nafud", "name_ar": "الدهناء", "name_en": "Ad Dahna", "alt": ["…"],
 "point": [lng, lat], "bbox": [w, s, e, n], "polygon": [[[lng, lat], …]],
 "sources": [{"id": "osm:relation/123", "licence": "ODbL-1.0"}, {"id": "geonames:…", "licence": "CC-BY-4.0"}]}
```

## Regenerate

```sh
python3 -m venv .venv && .venv/bin/pip install -r scripts/desert-gazetteer/requirements.txt
.venv/bin/python scripts/desert-gazetteer/fetch.py WORK          # Overpass (queries/*.overpassql) + GeoNames
# If Overpass is at capacity (common), use the Geofabrik extract for OSM instead:
SKIP_OSM=1 .venv/bin/python scripts/desert-gazetteer/fetch.py WORK
curl -LO https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf
.venv/bin/python scripts/desert-gazetteer/extract_pbf.py gcc-states-latest.osm.pbf WORK
.venv/bin/python scripts/desert-gazetteer/build.py WORK
.venv/bin/python -m pytest scripts/desert-gazetteer/tests -q
```

Then `xcodegen generate` is not needed: the file sits in `Resources/`, which is already a resource folder.

## Last build

2026-11-07: OSM from the Geofabrik `gcc-states` extract (osm_base 2026-11-06T21:21:21Z), because the
public Overpass servers answered 502/504 all afternoon. GeoNames fetched the same day. Counts, hashes: `sources.json`.
