"""SAM-Road evaluation (only windows actually run) + covered/uncovered track figure (best Sato config & SAM)."""
import json, os, numpy as np
from scipy.spatial import cKDTree
from common import *
OUT = os.path.join(os.path.dirname(__file__), "..", "out")
Z = np.load(os.path.join(AUX, "samples.npz")); d, tang, cls, s = Z["d"], Z["tang"], Z["cls"], Z["s"]; nrm = np.c_[-tang[:, 1], tang[:, 0]]
dirt = np.isin(cls, ["dirt_default", "dirt_osm_track"])
S = np.load(os.path.join(AUX, "sam.npz")); E = S["edges"]; idx = S["idx"]
def dens(a, b, st=5):
    L = np.hypot(*(b - a)); n = max(2, int(L / st) + 1); t = np.linspace(0, 1, n)[:, None]; return a + (b - a) * t
pts = np.vstack([dens(e[:2], e[2:]) for e in E]) if len(E) else np.zeros((0, 2))
# only track samples inside a SAM window (+-250 m along track of window centre)
inwin = np.zeros(len(d), bool)
for i in idx: inwin[max(0, i - 25):i + 26] = True
def _dens(l, st=10):
    c = np.r_[0, np.cumsum(np.hypot(*np.diff(l, axis=0).T))]; q = np.arange(0, c[-1], st)
    return np.c_[np.interp(q, c, l[:, 0]), np.interp(q, c, l[:, 1])]
PAV = cKDTree(np.vstack([_dens(l[1]) for l in osm_lines() if l[0] in ("paved", "ambig")]))
n_all = len(pts); pts = pts[PAV.query(pts)[0] > 75] if len(pts) else pts      # asphalt mask 75 m, as for the ridge filters
tree = cKDTree(pts) if len(pts) else None
res = dict(masked_out_frac=1 - len(pts) / max(n_all, 1), asphalt_mask_m=75, windows=len(idx), edge_len_km_after_mask=float(len(pts) * 5 / 1000), samples_dirt_in_windows=int((dirt & inwin).sum()))
d0 = tree.query(d)[0] if tree else np.full(len(d), np.inf)
for tol in (15, 30): res[f"coverage_{tol}m_dirt"] = float((d0[dirt & inwin] <= tol).mean())
rng = np.random.default_rng(9); blk = np.arange(len(d)) // 50; ctl = {15: [], 30: []}
for _ in range(1000):
    ob = rng.uniform(60, 75, blk.max() + 1) * rng.choice([-1, 1], blk.max() + 1); dc = tree.query(d + nrm * ob[blk][:, None])[0] if tree else np.full(len(d), np.inf)
    for tol in ctl: ctl[tol].append((dc[dirt & inwin] <= tol).mean())
for tol in ctl:
    a = np.array(ctl[tol]); res[f"control_{tol}m_p50"] = float(np.median(a)); res[f"control_{tol}m_p95"] = float(np.percentile(a, 95)); res[f"frac_controls_ge_real_{tol}m"] = float((a >= res[f"coverage_{tol}m_dirt"]).mean())
gt = cKDTree(d[inwin]); res["precision_30m_vs_gps_edges_near_track"] = float((gt.query(pts)[0] <= 30).mean()) if len(pts) else None
pc = []
for _ in range(200):
    ob = rng.uniform(60, 75, blk.max() + 1) * rng.choice([-1, 1], blk.max() + 1); pc.append((cKDTree((d + nrm * ob[blk][:, None])[inwin]).query(pts)[0] <= 30).mean())
res["precision_30m_control_p50"] = float(np.median(pc)); res["precision_30m_control_p95"] = float(np.percentile(pc, 95))
json.dump(res, open(os.path.join(OUT, "cov_sam.json"), "w"), indent=1); print(json.dumps(res, indent=1))
# ---- figure: track coloured by covered@30m (SAM windows only) and by best Sato config (all)
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
R = np.load(os.path.join(AUX, "ridge.npz")); k = "bright_0.95"; tr = cKDTree(R[k]); ds = tr.query(d)[0]
fig, axs = plt.subplots(1, 2, figsize=(14, 7))
for ax, (title, dist, mask) in zip(axs, [("Sato bright 95% (all track)", ds, np.ones(len(d), bool)), ("SAM-Road (windows only)", d0, inwin)]):
    ok = dist <= 30
    pav = cls == "paved"
    ax.scatter(d[~mask, 0] / 1000, d[~mask, 1] / 1000, s=2, c="#cccccc", label="not evaluated")
    ax.scatter(d[mask & ~ok & ~pav, 0] / 1000, d[mask & ~ok & ~pav, 1] / 1000, s=4, c="#d73027", label="dirt NOT covered")
    ax.scatter(d[mask & ok & ~pav, 0] / 1000, d[mask & ok & ~pav, 1] / 1000, s=7, c="#1a9850", label="dirt covered <=30 m")
    ax.scatter(d[pav, 0] / 1000, d[pav, 1] / 1000, s=4, c="#4575b4", label="paved (excluded)")
    ax.set_aspect("equal"); ax.set_title(title); ax.set_xlabel("km E"); ax.set_ylabel("km N")
axs[0].legend(loc="upper right", fontsize=8); fig.savefig(os.path.join(OUT, "track_coverage_map.png"), dpi=110, bbox_inches="tight")
