#!/bin/sh
# One rebuild: fresh OpenStreetMap extract + the latest Farq Atlas files → $TILES_DATA_DIR/farq.pmtiles.
# Every input is downloaded beside the old one and only replaces it when complete, and a failed step leaves the
# live archive as it was.
#
#   OSM_PBF_URL     default: the Saudi Arabia extract of openstreetmap.fr (rebuilt daily)
#   PLACES_PATH / PLACES_URL         Farq Atlas targets.parquet (optional; a path on a mounted volume, or a URL)
#   BUILDINGS_PATH / BUILDINGS_URL   Farq Atlas buildings.parquet (optional)
#   ATLAS_TOKEN     sent as «Authorization: Bearer …» to PLACES_URL / BUILDINGS_URL when set
set -eu

DATA="${TILES_DATA_DIR:-/data}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OSM_PBF_URL="${OSM_PBF_URL:-https://download.openstreetmap.fr/extracts/asia/saudi_arabia.osm.pbf}"
mkdir -p "$DATA/inputs"

fetch() { # url dest [min-bytes]
  tmp="$2.download"
  if [ -n "${ATLAS_TOKEN:-}" ] && [ "$1" != "$OSM_PBF_URL" ]; then
    curl -fsSL --retry 3 -H "Authorization: Bearer $ATLAS_TOKEN" -o "$tmp" "$1"
  else
    curl -fsSL --retry 3 -o "$tmp" "$1"
  fi
  size=$(wc -c < "$tmp")
  if [ "$size" -lt "${3:-1}" ]; then echo "tiles: $1 is only $size bytes; keeping the previous copy" >&2; rm -f "$tmp"; return 1; fi
  mv "$tmp" "$2"
}

echo "tiles: downloading $OSM_PBF_URL"
fetch "$OSM_PBF_URL" "$DATA/inputs/osm.pbf" 10000000

set -- --osm "$DATA/inputs/osm.pbf" --out "$DATA/farq.pmtiles"

if [ -n "${PLACES_URL:-}" ]; then fetch "$PLACES_URL" "$DATA/inputs/places.parquet" 1000 || true; PLACES_PATH="$DATA/inputs/places.parquet"; fi
if [ -n "${PLACES_PATH:-}" ] && [ -f "$PLACES_PATH" ]; then set -- "$@" --places "$PLACES_PATH"; fi
if [ -n "${BUILDINGS_URL:-}" ]; then fetch "$BUILDINGS_URL" "$DATA/inputs/buildings.parquet" 1000 || true; BUILDINGS_PATH="$DATA/inputs/buildings.parquet"; fi
if [ -n "${BUILDINGS_PATH:-}" ] && [ -f "$BUILDINGS_PATH" ]; then set -- "$@" --buildings "$BUILDINGS_PATH"; fi

exec python3 "$HERE/build_tiles.py" "$@"
