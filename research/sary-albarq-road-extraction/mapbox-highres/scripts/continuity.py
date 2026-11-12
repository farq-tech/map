"""Continuity of coverage along the GPS track (dirt, 30 m): fraction of covered samples lying in runs >= 100 m and the longest run; plus skeleton endpoints/junctions per km (spur proxy) when available. Control = lateral offset 60-75 m."""
import json, os, sys, numpy as np
from scipy.spatial import cKDTree
from common import *
OUT = os.path.join(os.path.dirname(__file__), "..", "out")
Z = np.load(os.path.join(AUX, "samples.npz")); d, tang, cls = Z["d"], Z["tang"], Z["cls"]; nrm = np.c_[-tang[:, 1], tang[:, 0]]
dirt = np.isin(cls, ["dirt_default", "dirt_osm_track"]); blk = np.arange(len(d)) // 50
def runs(cov):
    out = []; n = 0
    for v in cov:
        if v: n += 1
        elif n: out.append(n); n = 0
    if n: out.append(n)
    return np.array(out) * 10.0
def summ(cov):
    r = runs(cov); tot = r.sum() if len(r) else 0
    return dict(covered_m=float(tot), frac_in_runs_ge_100m=float(r[r >= 100].sum() / tot) if tot else None, longest_run_m=float(r.max()) if len(r) else 0)
PAV = None
res = {}; rng = np.random.default_rng(4)
for src in sys.argv[1:]:
    R = np.load(os.path.join(AUX, f"{src}.npz"))
    for k in R.files:
        pts = R[k]
        if len(pts) == 0: continue
        from detect_ridge import M  # noqa
        ob = rng.uniform(60, 75, blk.max() + 1) * rng.choice([-1, 1], blk.max() + 1)
        t = cKDTree(pts); c_real = t.query(d)[0] <= 30; c_ctl = t.query(d + nrm * ob[blk][:, None])[0] <= 30
        res[k] = dict(real=summ(c_real & dirt), control_one_draw=summ(c_ctl & dirt))
        print(k, res[k], flush=True)
json.dump(res, open(os.path.join(OUT, "continuity.json"), "w"), indent=1)
