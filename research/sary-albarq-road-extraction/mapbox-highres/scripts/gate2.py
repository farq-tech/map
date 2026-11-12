"""Gate 2: pooled cross-section across OSM highway=track lines (PROXY reference: OSM is not GPS truth).
Profile = mean over samples of (gray - mean(gray at |d| in 30..50 m)), d from -50..+50 m step 0.5.
Compared against 1000 random translations of the same line set (control)."""
import sys, os, json, math, cv2, numpy as np
sys.path.insert(0, os.path.dirname(__file__)); import tiles
HERE = os.path.dirname(__file__); OUT = os.path.join(HERE, "..", "out")
LAT, LON, NT = float(os.environ.get("AOI_LAT", 25.50)), float(os.environ.get("AOI_LON", 47.10)), 11
TAG = os.environ.get("AOI_TAG", "")
OSM = os.environ.get("OSM_TRK", os.path.expanduser("~/code/map-wt/desert-scout/trk_thumamah.json"))
img, meta = tiles.mosaic(LAT, LON, 17, NT, NT)
gray = cv2.GaussianBlur(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32), (0, 0), 0.8)
mpp = meta["mpp"]; H, W = gray.shape
def ll2px(lat, lon):
    fx, fy = tiles.ll2tile(lat, lon, 17); return (fx - meta["x0"]) * 512, (fy - meta["y0"]) * 512
lat_s, lon_w, lat_n, lon_e = meta["bbox"]
lines = []
for e in json.load(open(OSM))["elements"]:
    g = e.get("geometry", [])
    pts = np.array([ll2px(p["lat"], p["lon"]) for p in g])
    if len(pts) < 2: continue
    # clip to mosaic interior (margin 60 m)
    m = 60 / mpp
    keep = (pts[:,0] > m) & (pts[:,0] < W-m) & (pts[:,1] > m) & (pts[:,1] < H-m)
    if keep.sum() >= 2: lines.append((e["id"], pts))
print("ways in AOI:", len(lines), "mpp", round(mpp, 3))
D = np.arange(-50, 50.01, 0.5)
def samples(pts, step_m=5.0):
    """Yield (point px, normal unit px) along polyline every step_m."""
    out = []; acc = 0.0
    for a, b in zip(pts[:-1], pts[1:]):
        v = b - a; L = np.hypot(*v)
        if L == 0: continue
        t = v / L; n = np.array([-t[1], t[0]])
        s = (step_m - acc) / mpp if acc else 0.0
        s = max(s, 0.0)
        while s < L:
            out.append((a + t * s, n)); s += step_m / mpp
        acc = ((L - (s - step_m / mpp)) * mpp) % step_m
    return out
def profiles(line_set, dx=0.0, dy=0.0):
    P = []
    for _, pts in line_set:
        for p, n in samples(pts + [dx, dy]):
            xs = p[0] + n[0] * D / mpp; ys = p[1] + n[1] * D / mpp
            if xs.min() < 1 or ys.min() < 1 or xs.max() > W-2 or ys.max() > H-2: continue
            v = cv2.remap(gray, xs.astype(np.float32)[None], ys.astype(np.float32)[None], cv2.INTER_LINEAR)[0]
            P.append(v - v[(np.abs(D) >= 30)].mean())
    return np.array(P)
def stats(P, shift_align=0):
    if shift_align:  # per-sample best |dev| within +-shift_align m (biased by construction; control uses same)
        k = int(shift_align / 0.5); c = len(D)//2; Q = []
        for v in P:
            w = v[c-k:c+k+1]; i = np.argmax(np.abs(w - np.median(v))) - k
            Q.append(np.roll(v, -i))
        P = np.array(Q)
    prof = P.mean(0); c = np.abs(D) <= 2; fl = np.abs(D) >= 20
    center = prof[c].mean(); fl_std = prof[fl].std()
    return prof, float(center), float(fl_std), float(abs(center) / fl_std)
R = {}
P0 = profiles(lines); prof0, c0, f0, r0 = stats(P0)
R["raw"] = dict(n_samples=len(P0), center=c0, flank_std=f0, ratio=r0)
prof1, c1, f1, r1 = stats(P0, shift_align=8)
R["aligned8m"] = dict(center=c1, flank_std=f1, ratio=r1)
rng = np.random.default_rng(7); rr, ra = [], []
for _ in range(1000):
    ang = rng.uniform(0, 2*np.pi); r = rng.uniform(150, 600) / mpp
    P = profiles(lines, r*np.cos(ang), r*np.sin(ang))
    if len(P) < 50: continue
    rr.append(stats(P)[3])
R["random_translations"] = dict(n=len(rr), ratio_p50=float(np.median(rr)), ratio_p95=float(np.percentile(rr, 95)), ratio_max=float(max(rr)),
                                frac_ge_real=float(np.mean(np.array(rr) >= r0)))
R["pass_gate2_raw"] = bool(r0 >= 2.0 and r0 > np.percentile(rr, 95))
json.dump(R, open(os.path.join(OUT, f"gate2{TAG}.json"), "w"), indent=1)
print(json.dumps(R, indent=1)); print("tiles fetched", tiles.N_FETCHED)
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
fig, ax = plt.subplots(figsize=(8, 4)); ax.plot(D, prof0, label="OSM tracks raw (n=%d)" % len(P0)); ax.plot(D, prof1, label="aligned ±8 m (biased)", alpha=.7)
ax.axvline(0, c="k", lw=.5); ax.set_xlabel("m from line"); ax.set_ylabel("gray − flank mean"); ax.legend(); ax.set_title("Gate 2 pooled cross-section (OSM proxy)")
fig.savefig(os.path.join(OUT, f"gate2_profile{TAG}.png"), dpi=110, bbox_inches="tight")
