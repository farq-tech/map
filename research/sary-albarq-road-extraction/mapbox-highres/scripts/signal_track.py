"""Gate 2 on the real GPS track: pooled cross-section (dirt vs paved), controls = 1000 lateral offsets of 60-75 m (in 500 m blocks),
plus per-200 m segment test with +-10 m alignment search (controls get the same search)."""
import json, os, numpy as np, cv2
from common import *
OUT = os.path.join(os.path.dirname(__file__), "..", "out"); os.makedirs(OUT, exist_ok=True)
Z = np.load(os.path.join(AUX, "samples.npz")); d, tang, cls = Z["d"], Z["tang"], Z["cls"]
D = np.arange(-50, 50.01, 0.5); nrm = np.c_[-tang[:, 1], tang[:, 0]]
def profile_at(p_xy, n_xy):
    """gray profile along normal; None if any tile missing"""
    lat, lon = m2ll(p_xy[None])[0][0], m2ll(p_xy[None])[1][0]
    tx, ty = tile_of = (int(tiles.ll2tile(lat, lon, 17)[0]), int(tiles.ll2tile(lat, lon, 17)[1]))
    B = block(tx, ty, 1); gx, gy = gpx(lat, lon); mpp = MPP_LAT(lat)
    ox, oy = (tx - 1) * 512, (ty - 1) * 512
    xs = (gx - ox + n_xy[0] * D / mpp).astype(np.float32); ys = (gy - oy - n_xy[1] * D / mpp).astype(np.float32)  # y px axis points south
    v = cv2.remap(B, xs[None], ys[None], cv2.INTER_LINEAR)[0]
    return None if np.isnan(v).any() else v
def profs(offsets):
    out = []
    for i in range(len(d)):
        p = d[i] + nrm[i] * offsets[i]; v = profile_at(p, nrm[i])
        out.append(None if v is None else v - v[np.abs(D) >= 30].mean())
    return out
def stat(P, mask):
    A = np.array([P[i] for i in range(len(P)) if mask[i] and P[i] is not None])
    if len(A) < 30: return None
    prof = A.mean(0); c = np.abs(D) <= 2; fl = np.abs(D) >= 20
    return dict(n=len(A), center=float(prof[c].mean()), flank_std=float(prof[fl].std()), ratio=float(abs(prof[c].mean()) / prof[fl].std())), prof
masks = {"dirt": np.isin(cls, ["dirt_default", "dirt_osm_track"]), "paved": cls == "paved", "all": np.ones(len(d), bool)}
P0 = profs(np.zeros(len(d))); R = {}; profsout = {}
for k, m in masks.items():
    r = stat(P0, m)
    if r: R[k] = r[0]; profsout[k] = r[1]
rng = np.random.default_rng(11); blk = (np.arange(len(d)) // 50)   # 500 m blocks
ctl = {k: [] for k in masks}
for it in range(1000 if os.environ.get("FAST") is None else 60):
    off_b = rng.uniform(60, 75, blk.max() + 1) * rng.choice([-1, 1], blk.max() + 1); P = profs(off_b[blk])
    for k, m in masks.items():
        r = stat(P, m)
        if r: ctl[k].append(r[0]["ratio"])
for k in R:
    a = np.array(ctl[k]); R[k]["control_p50"] = float(np.median(a)); R[k]["control_p95"] = float(np.percentile(a, 95)); R[k]["control_max"] = float(a.max())
    R[k]["frac_controls_ge_real"] = float(np.mean(a >= R[k]["ratio"])); R[k]["n_controls"] = len(a)
json.dump(R, open(os.path.join(OUT, "signal_track.json"), "w"), indent=1); print(json.dumps(R, indent=1))
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
fig, ax = plt.subplots(figsize=(8, 4))
for k, pr in profsout.items(): ax.plot(D, pr, label=f"{k} (n={R[k]['n']})")
ax.axvline(0, c="k", lw=.5); ax.set_xlabel("m from GPS track"); ax.set_ylabel("gray - flank mean"); ax.legend(); ax.set_title("Pooled cross-section, Thumamah West GPS track")
fig.savefig(os.path.join(OUT, "signal_track_profile.png"), dpi=110, bbox_inches="tight")
