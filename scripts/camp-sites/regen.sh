#!/bin/zsh
# Regenerate «أماكن مقترحة للكشتة» + «مخطط دروب البر» data for the pilot regions.
#   scripts/camp-sites/regen.sh <work_dir> [region ...]
# Needs ~1 GB free in <work_dir> (OSM extract 260 MB, rasters ~15 MB per region). Stops below 12 GB free.
set -euo pipefail
HERE=${0:A:h}
WORK=${1:?work dir}; shift
REGIONS=(${@:-thumamah dahna nafud})
APP=$HERE/../../apps/ios/SaryAlbarq/Resources/CampSites
mkdir -p $WORK/venv $WORK/cache $WORK/out $WORK/dl/osm
free_gb() { df -g ~ | awk 'NR==2 {print $4}' }
(( $(free_gb) >= 12 )) || { echo "less than 12 GB free: stop"; exit 1 }
[[ -x $WORK/venv/bin/python ]] || { python3.12 -m venv $WORK/venv && $WORK/venv/bin/pip install -q -r $HERE/requirements.txt }
PY="$WORK/venv/bin/python -I"
PBF=$WORK/dl/osm/gcc-states-latest.osm.pbf
if [[ ! -f $PBF ]]; then
  curl -sL -o $PBF https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf
  [[ "$(md5 -q $PBF)" == "$(curl -sL https://download.geofabrik.de/asia/gcc-states-latest.osm.pbf.md5 | cut -d' ' -f1)" ]] || { echo "OSM md5 mismatch"; exit 1 }
fi
$=PY $HERE/fetch_osm.py $PBF $WORK/cache
for r in $REGIONS; do
  (( $(free_gb) >= 12 )) || { echo "less than 12 GB free: stop"; exit 1 }
  $=PY $HERE/fetch_rasters.py $r $WORK/cache
  $=PY $HERE/build.py $r $WORK/cache $WORK/out
  $=PY $HERE/routes.py $r $WORK/cache $WORK/out
  cp $WORK/cache/$r/sources.json $HERE/sources/$r.json
done
cp $WORK/out/camp-sites-*.geojson $WORK/out/routes-*.bin $APP/
$=PY -m pytest $HERE/tests -q
echo "done: $APP"
