#!/usr/bin/env python3
"""Builds Resources/RestrictedZones/restricted_zones.json from OpenStreetMap (Overpass).

Zones  = aeroway=aerodrome and landuse=military ways/relations in Saudi Arabia (outer rings only).
Open   = parts of an aerodrome the public may drive: classified roads (motorway..tertiary) and
         aeroway=terminal / amenity=parking polygons. Used by the app to NOT flag access roads
         and passenger parking.
Output is simplified (~15 m) and rounded to 5 decimals to stay small. © OpenStreetMap contributors (ODbL).

Usage: python3 -I build_restricted_zones.py OUT.json [cache_dir]
"""
import json, math, os, subprocess, sys, time

MIRRORS = ["https://overpass-api.de/api/interpreter", "https://overpass.private.coffee/api/interpreter"]
UA = "sary-albarq-zone-builder/1.0"

def overpass(q, cache, need_elements=False, attempts=8):
    if cache and os.path.exists(cache):
        return json.load(open(cache))
    for attempt in range(attempts):
        for m in MIRRORS:
            try:
                body = subprocess.run(["curl", "-s", "--max-time", "300", "-A", UA, "--data-urlencode", "data=" + q, m],
                                      capture_output=True, check=True).stdout
                if body[:1] == b"{":
                    data = json.loads(body)
                    # A mirror that is overloaded or stale answers valid JSON with nothing in it.
                    if "remark" in data or (need_elements and not data.get("elements")):
                        raise RuntimeError("empty/remark answer")
                    if cache: open(cache, "wb").write(body)
                    return data
            except Exception as e:
                print("retry", m, e, file=sys.stderr)
        time.sleep(15 * (attempt + 1))
    raise SystemExit("overpass failed")

def rings(el):
    out = []
    if el["type"] == "way" and "geometry" in el:
        out.append([(p["lon"], p["lat"]) for p in el["geometry"]])
    elif el["type"] == "relation":
        for m in el.get("members", []):
            if m.get("role") == "outer" and "geometry" in m:
                out.append([(p["lon"], p["lat"]) for p in m["geometry"]])
    return [r for r in out if len(r) >= 4 and r[0] == r[-1]]

def dp(pts, eps):
    if len(pts) < 3: return pts
    (x1, y1), (x2, y2) = pts[0], pts[-1]
    dx, dy = x2 - x1, y2 - y1
    n = math.hypot(dx, dy) or 1e-12
    best, idx = 0, 0
    for i in range(1, len(pts) - 1):
        d = abs(dy * pts[i][0] - dx * pts[i][1] + x2 * y1 - y2 * x1) / n
        if d > best: best, idx = d, i
    if best > eps:
        return dp(pts[:idx + 1], eps)[:-1] + dp(pts[idx:], eps)
    return [pts[0], pts[-1]]

def simp(pts, eps=0.00014):
    if len(pts) > 3 and pts[0] == pts[-1]:
        # A closed ring has a zero-length chord: split at the vertex farthest from the start first.
        k = max(range(1, len(pts) - 1), key=lambda i: (pts[i][0] - pts[0][0]) ** 2 + (pts[i][1] - pts[0][1]) ** 2)
        s = dp(pts[:k + 1], eps)[:-1] + dp(pts[k:], eps)
    else:
        s = dp(pts, eps)
    return [[round(x, 5), round(y, 5)] for x, y in s]

def bbox(pts):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    return min(ys), min(xs), max(ys), max(xs)

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    out, cache = args[0], (args[1] if len(args) > 1 else None)
    if cache: os.makedirs(cache, exist_ok=True)
    c = lambda n: os.path.join(cache, n) if cache else None
    zq = '[out:json][timeout:280];area["ISO3166-1"="SA"]->.sa;(way(area.sa)["aeroway"="aerodrome"];relation(area.sa)["aeroway"="aerodrome"];way(area.sa)["landuse"="military"];relation(area.sa)["landuse"="military"];);out geom tags;'
    zones_raw = overpass(zq, c("zones.json"))["elements"]
    zones = []
    for el in zones_raw:
        t = el.get("tags", {})
        if t.get("access") in ("yes", "permissive", "customers") and t.get("aeroway") != "aerodrome": continue
        kind = "aerodrome" if t.get("aeroway") == "aerodrome" else "military"
        # Tiny strips (<~120 m) are noise, not facilities.
        for r in rings(el):
            s, w, n, e = bbox(r)
            if max(n - s, e - w) < 0.0011: continue
            zones.append({"id": f"{el['type'][0]}{el['id']}", "kind": kind,
                          "name": t.get("name:ar") or t.get("name") or t.get("name:en") or "",
                          "ring": simp(r)})
    print("zones", len(zones), file=sys.stderr)
    # Open parts: classified roads + terminals/parking, only inside zone bboxes (aerodromes only).
    aero = [z for z in zones if z["kind"] == "aerodrome"]
    boxes = [bbox([tuple(p) for p in z["ring"]]) for z in aero]
    skipped = []
    def chunked(kind_filter, tag):
        out_els = []
        for i in range(0, len(boxes), 15):
            parts = "".join(f"{kind_filter}({b[0]},{b[1]},{b[2]},{b[3]});" for b in boxes[i:i + 15])
            try:
                out_els += overpass(f"[out:json][timeout:120];({parts});out geom tags;", c(f"{tag}-{i}.json"), need_elements=True, attempts=3)["elements"]
            except SystemExit:
                skipped.append(f"{tag}[{i}:{i + 15}]")
                print("SKIPPED", tag, i, file=sys.stderr)
        return out_els
    if "--zones-only" in sys.argv:  # interim file when Overpass is slow: no public-road carve-outs
        boxes = []
    roads = chunked('way["highway"~"^(motorway|trunk|primary|secondary|tertiary)(_link)?$"]', "roads")
    pubs = chunked('way["aeroway"="terminal"];way["amenity"="parking"]["access"!~"private|no|military"];', "public")
    roads = list({e['id']: e for e in roads}.values()); pubs = list({e['id']: e for e in pubs}.values())
    open_lines = [{"line": simp([(p["lon"], p["lat"]) for p in el["geometry"]], 0.00006)} for el in roads if "geometry" in el
                  and el.get("tags", {}).get("access") not in ("private", "no", "military")]
    open_rings = [{"ring": simp(r)} for el in pubs for r in rings(el)]
    json.dump({"version": 1, "attribution": "© OpenStreetMap contributors (ODbL)", "generated": time.strftime("%Y-%m-%d"),
               "skippedOpenData": skipped, "zones": zones, "openLines": open_lines, "openRings": open_rings},
              open(out, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    print("wrote", out, os.path.getsize(out), "bytes; open lines", len(open_lines), "rings", len(open_rings), file=sys.stderr)

main()
