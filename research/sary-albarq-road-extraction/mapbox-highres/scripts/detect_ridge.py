"""Baseline classical detector (no training): multi-scale Sato ridge filter -> fixed-quantile threshold -> skeleton -> length filter.
Parameters fixed BEFORE looking at the track (sigmas 2,3,4 px = 1.1-2.2 m for a 3-4 m track at 0.54 m/px). Output: skeleton pixel positions in local metres, per polarity and quantile."""
import os, sys, math, numpy as np, cv2
from skimage.filters import sato
from skimage.morphology import skeletonize, remove_small_objects
from skimage.measure import label
from common import *
M = 128  # context margin px
def tile_window(tx, ty):
    B = block(tx, ty, 1)[512 - M:1024 + M, 512 - M:1024 + M].copy()
    if np.isnan(B).all(): return None
    B[np.isnan(B)] = np.nanmean(B); return B
def resp(B, black):
    return sato(B, sigmas=(2, 3, 4), black_ridges=black)[M:-M, M:-M]
def px_to_m(tx, ty, ii, jj):
    gx = tx * 512 + jj + .5; gy = ty * 512 + ii + .5
    n = 2 ** 17; lon = gx / 512 / n * 360 - 180; lat = np.degrees(np.arctan(np.sinh(np.pi * (1 - 2 * gy / 512 / n))))
    return T.to_m(lat, lon)
if __name__ == "__main__":
    ts = T.needed_tiles(T.load_track()); rng = np.random.default_rng(1)
    samp = [ts[i] for i in rng.choice(len(ts), 20, replace=False)]
    out = {}
    for pol in ("bright", "dark"):
        black = pol == "dark"; v = np.concatenate([resp(tile_window(*t), black).ravel()[::50] for t in samp])
        thr = {q: float(np.quantile(v, q)) for q in (0.95, 0.97, 0.99)}; print(pol, thr, flush=True)
        for q, th in thr.items():
            pts = []
            for t in ts:
                B = tile_window(*t)
                if B is None: continue
                m = resp(B, black) > th; m = remove_small_objects(m, 30); sk = skeletonize(m)
                lab = label(sk, connectivity=2); cnt = np.bincount(lab.ravel()); keep = cnt >= int(60 / 0.54) ; keep[0] = False
                ii, jj = np.nonzero(keep[lab])
                if len(ii): pts.append(px_to_m(t[0], t[1], ii, jj))
            out[f"{pol}_{q}"] = np.concatenate(pts) if pts else np.zeros((0, 2))
            print(pol, q, len(out[f"{pol}_{q}"]) * 0.54 / 1000, "km skeleton", flush=True)
    np.savez(os.path.join(AUX, "ridge.npz"), **out)
