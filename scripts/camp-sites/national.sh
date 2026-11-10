#!/usr/bin/env bash
# «دروب البر» for the whole Kingdom: build every 1° route tile and the manifest on a Linux cloud machine.
#   scripts/camp-sites/national.sh <work_dir> [jobs] [version]
# Resumable: a tile whose routes-<tile>.bin exists is skipped; rerun after a failure.
# Output: <work_dir>/out/desert/{routes-t*.bin,manifest.json}  → upload (README.md "Routes for the whole Kingdom").
# Inputs are open data only (Copernicus DEM, ESA WorldCover, Sentinel-2, OpenStreetMap). Never Google, Mapbox or Esri.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${1:?work dir}
JOBS=${2:-$(( $(nproc) / 2 ))}
VERSION=${3:-$(date -u +%Y-%m-%d)}
OUT=$WORK/out/desert
mkdir -p "$WORK/cache" "$OUT" "$WORK/dl/osm" "$WORK/logs"
free_gb() { df -BG --output=avail "$WORK" | tail -1 | tr -dc 0-9; }
(( $(free_gb) >= 40 )) || { echo "less than 40 GB free in $WORK: stop"; exit 1; }
if [[ ! -x $WORK/venv/bin/python ]]; then
  python3 -m venv "$WORK/venv" && "$WORK/venv/bin/pip" install -q -r "$HERE/requirements.txt"
fi
PY="$WORK/venv/bin/python -I"

PBF=$WORK/dl/osm/gcc-states-latest.osm.pbf
if [[ ! -f $PBF ]]; then
  curl -sSL -o "$PBF" https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf
  want=$(curl -sSL https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf.md5 | cut -d' ' -f1)
  [[ "$(md5sum "$PBF" | cut -d' ' -f1)" == "$want" ]] || { echo "OSM md5 mismatch"; rm -f "$PBF"; exit 1; }
fi

$PY "$HERE/tiles.py" list > "$WORK/tiles.txt"
echo "$(wc -l < "$WORK/tiles.txt") tiles, $JOBS at a time"
# One pass over the extract for every tile (needs ~8–16 GB RAM for the whole Kingdom; estimate).
if [[ ! -f $WORK/cache/.osm-done ]]; then
  $PY "$HERE/fetch_osm.py" "$PBF" "$WORK/cache" "@$WORK/tiles.txt" > "$WORK/logs/osm.log"
  touch "$WORK/cache/.osm-done"
fi

one() {  # one tile: rasters → route layers → cropped tile; then free its cache
  set -euo pipefail
  t=$1
  [[ -f $OUT/routes-$t.bin ]] && exit 0
  (( $(free_gb) >= 15 )) || { echo "$t: less than 15 GB free, skipped"; exit 1; }
  $PY "$HERE/fetch_rasters.py" "$t" "$WORK/cache"
  $PY "$HERE/build.py" --route-layers "$t" "$WORK/cache"
  $PY "$HERE/tiles.py" build "$t" "$WORK/cache" "$OUT"
  mkdir -p "$WORK/sources" && cp "$WORK/cache/$t/sources.json" "$WORK/sources/$t.json"
  rm -f "$WORK/cache/$t/rasters_"*.npz "$WORK/cache/$t/layers.npz"
}
export -f one free_gb
export HERE WORK OUT PY
status=0
xargs -P "$JOBS" -I{} bash -c 'one {} > "$WORK/logs/{}.log" 2>&1 || echo "FAILED {} (see logs/{}.log)"' < "$WORK/tiles.txt" \
  | tee "$WORK/logs/failed.txt" || status=1
[[ -s $WORK/logs/failed.txt ]] && { echo "some tiles failed; rerun to resume"; status=1; }

md5=$(md5sum "$PBF" | cut -d' ' -f1)
printf '{"osm_extract": "gcc-states-latest.osm.pbf", "osm_md5": "%s", "tiles_failed": %s}\n' \
  "$md5" "$(grep -c FAILED "$WORK/logs/failed.txt" || true)" > "$WORK/built_from.json"
$PY "$HERE/tiles.py" manifest "$OUT" --version "$VERSION" --built-from "$WORK/built_from.json"
$PY -m pytest "$HERE/tests" -q
echo "done: $OUT ($(du -sh "$OUT" | cut -f1))"
exit $status
