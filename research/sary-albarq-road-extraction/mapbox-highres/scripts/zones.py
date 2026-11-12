"""Per-zone terrain description + metrics in km. Zones by northing (km from 25.2N): south y<-3, middle -3..8, north >8."""
import json, os, numpy as np, cv2
from scipy.spatial import cKDTree
from common import *
OUT = os.path.join(os.path.dirname(__file__), "..", "out")
Z = np.load(os.path.join(AUX, "samples.npz")); d, tang, cls = Z["d"], Z["tang"], Z["cls"]; nrm = np.c_[-tang[:, 1], tang[:, 0]]
dirt = np.isin(cls, ["dirt_default", "dirt_osm_track"]); yk = d[:, 1] / 1000
zones = {"north (y>8)": yk > 8, "middle (-3..8)": (yk >= -3) & (yk <= 8), "south (y<-3)": yk < -3}
R = np.load(os.path.join(AUX, "ridge.npz"))["bright_0.95"]; tr = cKDTree(R); cov30 = tr.query(d)[0] <= 30
sam = np.load(os.path.join(AUX, "sam.npz")); inwin = np.zeros(len(d), bool)
for i in sam["idx"]: inwin[max(0, i - 25):i + 26] = True
rng = np.random.default_rng(8); blk = np.arange(len(d)) // 50; ctl = []
for _ in range(300):
    ob = rng.uniform(60, 75, blk.max() + 1) * rng.choice([-1, 1], blk.max() + 1); ctl.append(tr.query(d + nrm * ob[blk][:, None])[0] <= 30)
ctl = np.array(ctl)
# colour / texture around the track (+-30..50 m flanks) per zone from tile centre crops
def stats_for(idxs):
    hs = []
    for i in idxs[::5]:
        lat, lon = m2ll(d[i:i+1]); tx, ty = int(tiles.ll2tile(lat[0], lon[0], 17)[0]), int(tiles.ll2tile(lat[0], lon[0], 17)[1])
        p = os.path.join(tiles.TILE_DIR, f"17_{tx}_{ty}@2x.jpg")
        if not os.path.exists(p): continue
        im = cv2.imread(p); hsv = cv2.cvtColor(im, cv2.COLOR_BGR2HSV).astype(float); g = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY).astype(float)
        hs.append([hsv[..., 0].mean() * 2, hsv[..., 1].mean() / 2.55, hsv[..., 2].mean() / 2.55, g.std(), cv2.Laplacian(g, cv2.CV_64F).var()])
    a = np.array(hs).mean(0); return dict(hue_deg=a[0], sat_pct=a[1], val_pct=a[2], gray_std=a[3], lap_var=a[4])
out = {}
for k, m in zones.items():
    dm = m & dirt; n = int(dm.sum())
    out[k] = dict(track_km=float(m.sum() * .01), dirt_km=n * .01, osm_track_share=float((cls[m] == "dirt_osm_track").mean()),
                  sato_covered_km=float((cov30 & dm).sum() * .01), sato_cov_frac=float((cov30 & dm).sum() / n), control_cov_frac_p50=float(np.median([(c & dm).sum() / n for c in ctl])),
                  sam_dirt_km_in_windows=float((inwin & dm).sum() * .01), sam_covered_km=None, tile_color=stats_for(np.nonzero(m)[0]))
    # SAM coverage per zone
    st = np.load(os.path.join(AUX, "sam.npz"))["edges"]
    def dens(a, b, s=5): n_ = max(2, int(np.hypot(*(b - a)) / s) + 1); t = np.linspace(0, 1, n_)[:, None]; return a + (b - a) * t
    pts = np.vstack([dens(e[:2], e[2:]) for e in st]); 
    pv = []
    for l in osm_lines():
        if l[0] in ("paved", "ambig"):
            c = np.r_[0, np.cumsum(np.hypot(*np.diff(l[1], axis=0).T))]; q = np.arange(0, c[-1], 10); pv.append(np.c_[np.interp(q, c, l[1][:, 0]), np.interp(q, c, l[1][:, 1])])
    pts = pts[cKDTree(np.vstack(pv)).query(pts)[0] > 75]; cs = cKDTree(pts).query(d)[0] <= 30
    out[k]["sam_covered_km"] = float((cs & inwin & dm).sum() * .01)
json.dump(out, open(os.path.join(OUT, "zones.json"), "w"), indent=1, default=float)
for k, v in out.items(): print(k, {a: (round(b, 3) if isinstance(b, float) else b) for a, b in v.items() if a != "tile_color"}, {a: round(b, 1) for a, b in v["tile_color"].items()})
# crops: 3 per zone, 256x256 m (475 px), at evenly spaced track samples
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
fig, axs = plt.subplots(3, 3, figsize=(12, 12))
for r, (k, m) in enumerate(zones.items()):
    ids = np.nonzero(m & dirt)[0]; picks = ids[np.linspace(len(ids) * .15, len(ids) * .85, 3).astype(int)]
    for c, i in enumerate(picks):
        lat, lon = m2ll(d[i:i+1]); gx, gy = gpx(lat[0], lon[0]); x0, y0 = int(gx - 256), int(gy - 256); im = np.zeros((512, 512, 3), np.uint8)
        for tx in range(x0 // 512, (x0 + 511) // 512 + 1):
            for ty in range(y0 // 512, (y0 + 511) // 512 + 1):
                p = os.path.join(tiles.TILE_DIR, f"17_{tx}_{ty}@2x.jpg")
                if os.path.exists(p):
                    t_ = cv2.imread(p); a0, b0 = max(tx * 512, x0), max(ty * 512, y0); a1, b1 = min(tx * 512 + 512, x0 + 512), min(ty * 512 + 512, y0 + 512)
                    im[b0 - y0:b1 - y0, a0 - x0:a1 - x0] = t_[b0 - ty * 512:b1 - ty * 512, a0 - tx * 512:a1 - tx * 512]
        axs[r, c].imshow(im[:, :, ::-1]); axs[r, c].axis("off"); axs[r, c].set_title(f"{k} @ y={yk[i]:.1f} km  (277 m, no track overlay)", fontsize=8)
fig.tight_layout(); fig.savefig(os.path.join(OUT, "zones_imagery.jpg"), dpi=80, bbox_inches="tight")
