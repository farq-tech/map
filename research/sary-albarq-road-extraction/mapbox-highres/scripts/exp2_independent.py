"""Independent check: OSM highway=track lines lying >60 m from the GPS track (never used as training labels) inside each held-out sector: are they found by the fold model?"""
import json, os, numpy as np
from scipy.spatial import cKDTree
from common import *
OUT = os.path.join(os.path.dirname(__file__), "..", "out")
Z = np.load(os.path.join(AUX, "samples.npz")); d = Z["d"]; gps = cKDTree(d); res = {}
def dens(l, st=10):
    c = np.r_[0, np.cumsum(np.hypot(*np.diff(l, axis=0).T))]; q = np.arange(0, c[-1], st); return np.c_[np.interp(q, c, l[:, 0]), np.interp(q, c, l[:, 1])]
osm = np.vstack([dens(l[1]) for l in osm_lines() if l[0] == "dirt"]); dg = gps.query(osm)[0]; far = osm[(dg > 60) & (dg < 130)]      # inside the tile corridor
rng = np.random.default_rng(3)
for f, test in {"north": lambda y: y > 8, "middle": lambda y: (y >= -3) & (y <= 8), "south": lambda y: y < -3}.items():
    sel = far[test(far[:, 1] / 1000)]
    if len(sel) < 20: res[f] = dict(osm_only_km=len(sel) * .01, note="too little independent OSM track in the corridor"); continue
    out = {"osm_only_km": len(sel) * .01}
    for tag in ("ft", "zeroshot"):
        pts = np.load(os.path.join(AUX, f"exp2_pts_{f}_{tag}.npy")); t = cKDTree(pts)
        out[f"covered_30m_{tag}"] = float((t.query(sel)[0] <= 30).mean())
        # control: same OSM-only points shifted 150-300 m sideways (random direction)
        ctl = []
        for _ in range(300):
            a = rng.uniform(0, 2 * np.pi); r = rng.uniform(150, 300); ctl.append((t.query(sel + [r * np.cos(a), r * np.sin(a)])[0] <= 30).mean())
        out[f"control_p50_{tag}"] = float(np.median(ctl)); out[f"control_p95_{tag}"] = float(np.percentile(ctl, 95))
    res[f] = out
json.dump(res, open(os.path.join(OUT, "exp2_independent_osm.json"), "w"), indent=1); print(json.dumps(res, indent=1))
