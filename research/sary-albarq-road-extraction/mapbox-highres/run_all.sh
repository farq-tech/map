#!/bin/sh
# One command to reproduce (needs Secrets.xcconfig, the external read-only KML, and /private/tmp/mbx-highres-aux/osm_hw.json = Overpass highways bbox 25.0,46.35,25.4,46.75).
# Tiles are cached outside git in /private/tmp/mbx-highres-tiles. Total ~540 tiles. Long jobs (SAM-Road ~5 min, controls ~10 min).
set -e; cd "$(dirname "$0")/scripts"
python3 gate0.py; python3 gate0_spectrum.py >/dev/null            # Gate 0
python3 thumamah.py                                                # fetch 420 corridor tiles
python3 classify.py; python3 signal_track.py; python3 narrow_peak.py   # Gate 2 on the real track
python3 detect_ridge.py; python3 eval_cov.py ridge                # Sato
python3 detect_more.py; python3 eval_cov.py meijering             # Meijering (+Steger, slow)
python3 sam_road_baseline.py; python3 eval_sam_and_figs.py        # SAM-Road + figure
python3 continuity.py ridge meijering; python3 zones.py
python3 gate2.py; python3 gate_segments.py                        # OSM-proxy first pass
./run_exp2.sh; python3 exp2_summary.py; python3 exp2_independent.py   # experiment 2 (spatial-holdout fine-tune)
