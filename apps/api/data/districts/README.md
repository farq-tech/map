# District boundaries (أحياء)

One GeoJSON FeatureCollection per city: `riyadh`, `jeddah`, `dammam`, `makkah`, `madinah`, `khobar`.

| Field | Meaning |
|-------|---------|
| `district_id` | `<city>-<slug of name_en>` (e.g. `riyadh-al-olaya`). Readable, and never numeric — the router JSON-parses search params, so a numeric id would arrive as a lossy Number. Used in the URL (`?neighborhood=`), in `district_id` on every city opportunity, and in the copilot's scope. A same-slug/different-Arabic clash is numbered (`-2`) in source-code order. |
| `name_ar` / `name_en` | Official district names, both present on every feature. |
| `city` | The city key the read model uses. |
| `source_codes` | Every MOMRAH `SysCode` that makes up this حي. The source splits some districts into several polygons (Riyadh's العليا is three); same-name parts within a city are one district here, as a MultiPolygon, because that is the حي a person means. |

**Source:** MOMRAH administrative district polygons ("Districts 6 city" shapefile, WGS84), exported from the Farq GIS archive on 2026-08-20. Geometry was simplified with a 0.00005° (~5 m) tolerance and rounded to 5 decimals; Z values dropped. 16 source rows without a name, without a city, or with a duplicate code were left out rather than guessed. Nothing else was edited — no boundary was drawn or moved by hand.

**What is not here:** the source's 2024 firm/building counts. They are not Farq observations, so the map never shows them.

Regenerate: `ogr2ogr -f GeoJSON -dim XY -simplify 0.00005 -lco COORDINATE_PRECISION=5 -lco RFC7946=YES -select "SysCode,EnCity,ArCity,EnName,ArName" out.geojson "Districts 6 city.shp"`, then split by `EnCity` into these files with the field mapping above.
