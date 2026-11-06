"""Extract what the camp-site model needs from the Geofabrik GCC extract (OpenStreetMap, ODbL).

Usage: python -I fetch_osm.py <gcc-states-latest.osm.pbf> <cache_dir>
Writes <cache_dir>/<region>/osm.json with lists of WKT geometries per layer:
  tracks       highway=track, or unpaved unclassified/service/path usable by 4x4 (access)
  roads        paved public roads (noise, light, «قريب من الخط»)
  settlements  place=city/town/village/hamlet/isolated_dwelling/farm, landuse=residential/farmyard
  protected    boundary=protected_area, boundary=national_park, leisure=nature_reserve (note / permit)
  military     landuse=military, military=* (hard exclusion)
  wet          natural=wetland/water, landuse=salt_pond, wetland=* (sabkha / water: hard exclusion)
  famous       named rawdah / faydah / nafud / erg features («مكان معروف للكشتات»)
"""
import json
import os
import re
import sys

import osmium
from shapely import wkb
from shapely.geometry import box

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from regions import REGIONS  # noqa: E402

MARGIN = 0.15
PAVED_HW = {"motorway", "trunk", "primary", "secondary", "tertiary", "motorway_link", "trunk_link",
            "primary_link", "secondary_link", "residential", "living_street"}
UNPAVED = {"unpaved", "dirt", "sand", "gravel", "ground", "earth", "compacted", "fine_gravel", "grass"}
FAMOUS = re.compile(r"(روض|فيض|نفود|نفوذ|عرق |عروق|الثمامة|الدهناء|طعس|خبرا|Rawd|Raudh|Rawdat|Faydat|Nafud|Thumamah|Dahna)", re.I)
SETTLE = {"city", "town", "village", "hamlet", "isolated_dwelling", "farm", "suburb", "neighbourhood"}


class H(osmium.SimpleHandler):
    def __init__(self, boxes):
        super().__init__()
        self.f = osmium.geom.WKBFactory()
        self.boxes = boxes
        self.out = {r: {k: [] for k in ("tracks", "roads", "settlements", "protected", "military", "wet", "famous")} for r in boxes}

    def put(self, layer, g, props=None):
        for r, b in self.boxes.items():
            if g.intersects(b):
                self.out[r][layer].append({"wkt": g.wkt if g.geom_type == "Point" else g.simplify(0.00005).wkt, **(props or {})})

    def node(self, n):
        t = n.tags
        if "place" not in t and "name" not in t:
            return
        try:
            g = wkb.loads(self.f.create_point(n), hex=True)
        except Exception:
            return
        if t.get("place") in SETTLE:
            self.put("settlements", g, {"kind": t.get("place")})
        name = t.get("name:ar") or t.get("name") or ""
        if name and FAMOUS.search(name + " " + t.get("name:en", "")) and t.get("place") not in {"city", "town", "suburb", "neighbourhood"} \
                and "amenity" not in t and "shop" not in t and "highway" not in t:
            self.put("famous", g, {"name": name, "natural": t.get("natural", ""), "place": t.get("place", "")})

    def way(self, w):
        t = w.tags
        hw = t.get("highway")
        if not hw:
            return
        try:
            g = wkb.loads(self.f.create_linestring(w), hex=True)
        except Exception:
            return
        surface = t.get("surface", "")
        if hw == "track" or (hw in {"unclassified", "service", "path"} and surface in UNPAVED):
            self.put("tracks", g, {"grade": t.get("tracktype", "")})
        elif hw in PAVED_HW and surface not in UNPAVED:
            self.put("roads", g, {"hw": hw})

    def area(self, a):
        t = a.tags
        layer = None
        if t.get("landuse") == "military" or "military" in t:
            layer = "military"
        elif t.get("boundary") in {"protected_area", "national_park"} or t.get("leisure") == "nature_reserve":
            layer = "protected"
        elif t.get("natural") in {"wetland", "water"} or t.get("landuse") == "salt_pond" or "wetland" in t:
            layer = "wet"
        elif t.get("landuse") in {"residential", "farmyard", "industrial", "commercial"} or t.get("place") in SETTLE:
            layer = "settlements"
        name = t.get("name:ar") or t.get("name") or ""
        famous = bool(name and FAMOUS.search(name + " " + t.get("name:en", "")) and layer in {None, "protected"})
        if not layer and not famous:
            return
        try:
            g = wkb.loads(self.f.create_multipolygon(a), hex=True)
        except Exception:
            return
        if layer:
            self.put(layer, g, {"name": name, "kind": t.get("landuse") or t.get("natural") or t.get("boundary") or t.get("leisure") or ""})
        if famous:
            self.put("famous", g.representative_point(), {"name": name, "natural": t.get("natural", ""), "place": t.get("place", ""),
                                                          "area_km2": round(g.area * 111 * 111 * 0.9, 2)})


def main(pbf, cache):
    boxes = {r: box(v["bbox"][1] - MARGIN, v["bbox"][0] - MARGIN, v["bbox"][3] + MARGIN, v["bbox"][2] + MARGIN) for r, v in REGIONS.items()}
    h = H(boxes)
    h.apply_file(pbf, locations=True)
    for r, d in h.out.items():
        os.makedirs(os.path.join(cache, r), exist_ok=True)
        with open(os.path.join(cache, r, "osm.json"), "w") as f:
            json.dump(d, f, ensure_ascii=False)
        print(r, {k: len(v) for k, v in d.items()})


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
