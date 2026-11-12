"""Coverage / precision of a detector's skeleton vs the GPS track, with lateral-offset random controls (1000), dirt only."""
import json, os, sys, numpy as np
from scipy.spatial import cKDTree
from common import *
OUT = os.path.join(os.path.dirname(__file__), "..", "out")
Z = np.load(os.path.join(AUX, "samples.npz")); d, tang, cls = Z["d"], Z["tang"], Z["cls"]; nrm = np.c_[-tang[:, 1], tang[:, 0]]
dirt = np.isin(cls, ["dirt_default", "dirt_osm_track"])
src = sys.argv[1] if len(sys.argv) > 1 else "ridge"; R = np.load(os.path.join(AUX, f"{src}.npz"))
osm_dirt = [l[1] for l in osm_lines() if l[0] == "dirt"]
osm_pts = np.concatenate([np.c_[np.interp(np.arange(0, np.hypot(*np.diff(l, axis=0).T).sum(), 5), np.r_[0, np.cumsum(np.hypot(*np.diff(l, axis=0).T))], l[:, 0]),
                                 np.interp(np.arange(0, np.hypot(*np.diff(l, axis=0).T).sum(), 5), np.r_[0, np.cumsum(np.hypot(*np.diff(l, axis=0).T))], l[:, 1])] for l in osm_dirt])
def dens(l, st=10):
    c = np.r_[0, np.cumsum(np.hypot(*np.diff(l, axis=0).T))]; q = np.arange(0, c[-1], st)
    return np.c_[np.interp(q, c, l[:, 0]), np.interp(q, c, l[:, 1])]
pv = [dens(l[1]) for l in osm_lines() if l[0] in ("paved", "ambig")]
PAVTREE = cKDTree(np.vstack(pv)); MASK_M = float(os.environ.get("ASPHALT_MASK_M", 75))
rng = np.random.default_rng(5); blk = np.arange(len(d)) // 50
res = {}
for key in R.files:
    pts = R[key]
    if len(pts) == 0: continue
    n_all = len(pts); pts = pts[PAVTREE.query(pts)[0] > MASK_M]   # asphalt mask: drop detections within MASK_M of known paved/ambiguous roads
    tree = cKDTree(pts)
    def cov(offs):
        dd, _ = tree.query(d + nrm * offs[:, None]); return dd
    d0 = cov(np.zeros(len(d))); r = {"skeleton_km": len(pts) * 0.54 / 1000, "masked_out_frac": 1 - len(pts) / n_all, "asphalt_mask_m": MASK_M}
    for tol in (15, 30): r[f"coverage_{tol}m_dirt"] = float((d0[dirt] <= tol).mean()); r[f"coverage_{tol}m_paved"] = float((d0[cls == "paved"] <= tol).mean()) if (cls == "paved").any() else None
    ctl = {15: [], 30: []}
    for _ in range(1000):
        ob = rng.uniform(60, 75, blk.max() + 1) * rng.choice([-1, 1], blk.max() + 1); dc = cov(ob[blk])
        for tol in ctl: ctl[tol].append((dc[dirt] <= tol).mean())
    for tol in ctl:
        a = np.array(ctl[tol]); r[f"control_{tol}m_p50"] = float(np.median(a)); r[f"control_{tol}m_p95"] = float(np.percentile(a, 95)); r[f"frac_controls_ge_real_{tol}m"] = float((a >= r[f"coverage_{tol}m_dirt"]).mean())
    # precision: skeleton points within 30 m of GPS track / GPS+OSM tracks; control = GPS shifted laterally 60-75 m
    gt = cKDTree(d); r["precision_30m_vs_gps"] = float((gt.query(pts)[0] <= 30).mean())
    gt2 = cKDTree(np.vstack([d, osm_pts])); r["precision_30m_vs_gps_plus_osm_tracks"] = float((gt2.query(pts)[0] <= 30).mean())
    pc = []
    for _ in range(100):
        ob = rng.uniform(60, 75, blk.max() + 1) * rng.choice([-1, 1], blk.max() + 1); pc.append((cKDTree(d + nrm * ob[blk][:, None]).query(pts)[0] <= 30).mean())
    r["precision_30m_control_p50"] = float(np.median(pc)); res[key] = r; print(key, {k: (round(v, 3) if isinstance(v, float) else v) for k, v in r.items()}, flush=True)
json.dump(res, open(os.path.join(OUT, f"cov_{src}.json"), "w"), indent=1)
