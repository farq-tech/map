"""Shared helpers for the real-track analysis: tile store, OSM surface classes, tangents."""
import json, math, os, sys
import cv2, numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import tiles, thumamah as T
AUX = "/private/tmp/mbx-highres-aux"   # outside git
_cache = {}
def tile_gray(x, y):
    k = (x, y)
    if k not in _cache:
        p = os.path.join(tiles.TILE_DIR, f"17_{x}_{y}@2x.jpg")
        _cache[k] = cv2.cvtColor(cv2.imread(p), cv2.COLOR_BGR2GRAY) if os.path.exists(p) else None
    return _cache[k]
import functools
@functools.lru_cache(maxsize=48)
def block(tx, ty, r=1):
    """(2r+1)x(2r+1) tile mosaic gray around tile (tx,ty); missing tiles -> NaN. Returns float32 and origin tile."""
    n = 2 * r + 1; out = np.full((n * 512, n * 512), np.nan, np.float32)
    for j in range(n):
        for i in range(n):
            g = tile_gray(tx - r + i, ty - r + j)
            if g is not None: out[j*512:(j+1)*512, i*512:(i+1)*512] = g
    return out
def gpx(lat, lon):  # global z17 pixel coords
    fx, fy = tiles.ll2tile(lat, lon, 17); return fx * 512, fy * 512
MPP_LAT = lambda lat: 156543.03392 * math.cos(math.radians(lat)) / 2 ** 17 / 2
PAVED = {"motorway","motorway_link","trunk","trunk_link","primary","primary_link","secondary","secondary_link","tertiary","tertiary_link","residential","living_street"}
AMBIG = {"unclassified","service"}
def osm_lines():
    out = []
    for e in json.load(open(os.path.join(AUX, "osm_hw.json")))["elements"]:
        t = e["tags"]; hw = t.get("highway"); sf = t.get("surface", "")
        if hw in ("proposed", "construction", "footway", "path", "steps", "pedestrian", "cycleway"): continue
        if hw == "track" or sf in ("unpaved", "sand", "ground", "dirt", "gravel", "compacted"): cls = "dirt"
        elif hw in PAVED or sf in ("asphalt", "paved", "concrete"): cls = "paved"
        elif hw in AMBIG: cls = "ambig"
        else: continue
        g = e.get("geometry", [])
        if len(g) >= 2: out.append((cls, T.to_m([p["lat"] for p in g], [p["lon"] for p in g]), e["id"], hw))
    return out
def dist_to_lines(pts, lines):
    """min distance (m) from each pt to any of lines (list of Nx2 arrays); brute force with vectorised segments."""
    best = np.full(len(pts), np.inf)
    for L in lines:
        a, b = L[:-1], L[1:]; ab = b - a; l2 = (ab ** 2).sum(1) + 1e-9
        for k in range(0, len(pts), 2000):
            p = pts[k:k+2000][:, None, :]
            t = np.clip(((p - a) * ab).sum(2) / l2, 0, 1)
            proj = a + t[..., None] * ab
            best[k:k+2000] = np.minimum(best[k:k+2000], np.hypot(*(p - proj).transpose(2, 0, 1)).min(1))
    return best
def track_samples(step=10.0):
    tr = T.load_track(); xy = T.to_m(tr[:, 0], tr[:, 1]); d, s = T.densify(xy, step)
    # smoothed tangent over +-30 m (GPS jitter)
    k = max(1, int(30 / step)); tang = np.zeros_like(d)
    for i in range(len(d)):
        a, b = d[max(0, i - k)], d[min(len(d) - 1, i + k)]; v = b - a; tang[i] = v / (np.hypot(*v) + 1e-9)
    return d, tang, s
def m2ll(xy):
    return xy[:, 1] / 110574 + T.LAT0, xy[:, 0] / (111320 * math.cos(math.radians(T.LAT0))) + 46.55
