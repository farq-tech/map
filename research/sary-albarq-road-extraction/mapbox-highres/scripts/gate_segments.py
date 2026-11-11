"""Per-100 m segment test: does the centerline (|d|<=2 m) differ from flanks (20..50 m)? z-score vs 1000 translated controls of the same segments.
Reports fraction of OSM segments that individually beat the control p95, vs the control's own false-positive rate by construction (5%)."""
import sys, os, json, numpy as np
sys.argv = sys.argv[:1]
HERE = os.path.dirname(__file__); sys.path.insert(0, HERE)
src = open(os.path.join(HERE, "gate2.py")).read().split("R = {}")[0]  # reuse loaders/helpers
exec(src)
def seg_score(pts):
    P = profiles([(0, pts)])
    if len(P) < 12: return None
    prof = P.mean(0); c = np.abs(D) <= 2; fl = (np.abs(D) >= 20)
    return float((prof[c].mean() - prof[fl].mean()) / (P[:, fl].mean(1).std() / np.sqrt(len(P)) + 1e-6))
segs = []
for _, pts in lines:
    L = np.r_[0, np.cumsum(np.hypot(*np.diff(pts, axis=0).T))] * mpp
    for s0 in np.arange(0, L[-1] - 100, 100):
        m = (L >= s0) & (L <= s0 + 100)
        if m.sum() >= 2: segs.append(pts[m])
rng = np.random.default_rng(3); sc = []; ctrl = []
for s in segs:
    v = seg_score(s)
    if v is None: continue
    sc.append(v)
    for _ in range(20):
        ang = rng.uniform(0, 2*np.pi); r = rng.uniform(150, 600)/mpp
        w = seg_score(s + [r*np.cos(ang), r*np.sin(ang)])
        if w is not None: ctrl.append(w)
sc = np.array(sc); ctrl = np.array(ctrl); thr = np.percentile(np.abs(ctrl), 95)
R = dict(n_segments=len(sc), thr_abs_z_p95_control=float(thr), frac_real_above=float(np.mean(np.abs(sc) > thr)),
         frac_control_above=float(np.mean(np.abs(ctrl) > thr)), median_abs_z_real=float(np.median(np.abs(sc))), median_abs_z_control=float(np.median(np.abs(ctrl))))
json.dump(R, open(os.path.join(OUT, "segments.json"), "w"), indent=1); print(json.dumps(R, indent=1))
