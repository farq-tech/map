#!/bin/sh
# One command: reproduces Gate 0 and Gate 2 (+ per-segment control). Needs apps/ios/SaryAlbarq/Config/Secrets.xcconfig (gitignored) and OSM_TRK json.
# Tiles go to /private/tmp/mbx-highres-tiles (outside git). ~117 tiles.
set -e; cd "$(dirname "$0")"
python3 scripts/gate0.py; python3 scripts/gate0_spectrum.py >/dev/null; python3 scripts/gate2.py; python3 scripts/gate_segments.py
