"""Fetch OSM highways for the Thumamah AOI (Overpass; mirrors) -> AUX/osm_hw.json (outside git)."""
import json, os, time, urllib.request, urllib.parse
from common import AUX
os.makedirs(AUX, exist_ok=True)
q = '[out:json][timeout:120];way["highway"](24.95,46.35,25.45,46.75);out tags geom;'
for k in range(12):
    for host in ("overpass-api.de", "overpass.kumi.systems", "overpass.private.coffee"):
        try:
            r = urllib.request.urlopen(urllib.request.Request(f"https://{host}/api/interpreter", urllib.parse.urlencode({"data": q}).encode(), {"User-Agent": "research"}), timeout=150).read()
            j = json.loads(r); json.dump(j, open(os.path.join(AUX, "osm_hw.json"), "w")); print("ok", host, len(j["elements"])); raise SystemExit
        except SystemExit: raise
        except Exception as e: print("retry", host, type(e).__name__); time.sleep(5)
