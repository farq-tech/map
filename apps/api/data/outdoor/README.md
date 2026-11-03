# Outdoor geography (ODbL)

Source: OpenStreetMap via Geofabrik GCC extract.
Licence: Open Database License (ODbL).

These files are **observed OSM features only**. Nothing was invented,
snapped, or completed. Names come from OSM `name` tags.

- `wells.geojson`, `springs.geojson`, `camps.geojson` — amenity / natural points
- `nature-places.geojson` — named places whose OSM name matches a Najdi/Saudi outdoor lexicon
- `tracks-named.geojson` — OSM highway=track (and similar) **with a name**
- `wadis.geojson` — named waterways matching وادي / شعيب (geometry simplified, not relocated)

## Fuel stations (`fuel.geojson`) — data step, not yet run

«أقرب محطة» in a shared outing reads OSM `amenity=fuel` from `fuel.geojson`.
The file is **optional**: until it exists the API serves no fuel features and
the app says so (and still offers wells / springs from the files above). Nothing
is guessed in its absence.

To add it, from a Saudi/GCC OSM extract you already have:

1. Either the same Geofabrik GCC shapefile used above —
   `ogr2ogr -f GeoJSON -where "fclass='fuel'" /tmp/fuel-pt.geojson gis_osm_traffic_free_1.shp`
   (and `gis_osm_traffic_a_free_1.shp` for stations mapped as areas) —
   or an Overpass export:
   `[out:json][timeout:120]; area["ISO3166-1"="SA"][admin_level=2]->.a; nwr["amenity"="fuel"](area.a); out center tags;`
2. `node apps/api/scripts/build-outdoor-fuel.js <that file> --out apps/api/data/outdoor/fuel.geojson`
   (keeps OSM id, `name`/`name:ar`, `brand`, one point; drops anything outside
   Saudi bounds; invents nothing).
3. Commit the file. Licence ODbL; the map already credits
   «© OpenStreetMap contributors».
