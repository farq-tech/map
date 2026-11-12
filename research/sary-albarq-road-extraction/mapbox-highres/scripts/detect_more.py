"""Extra training-free baselines on the same corridor tiles: Meijering (skimage) and Steger (PyPI ridge-detection, MIT per PyPI but a port of the
GPL ImageJ plugin -> EVALUATION ONLY, never shipped). Same pipeline/mask/metrics as Sato. Parameters fixed before looking at the track."""
import os, sys
sys.path.append("/private/tmp/mbx-highres-aux/pylib")       # ridge-detection installed outside the repo/user env
import numpy as np
from multiprocessing import Pool
from skimage.filters import meijering
from skimage.morphology import skeletonize, remove_small_objects
from skimage.measure import label
from scipy.ndimage import convolve
from detect_ridge import tile_window, px_to_m, M
from common import *
QS = (0.95, 0.97)
def clean(m):
    m = remove_small_objects(m, 30); sk = skeletonize(m); lab = label(sk, connectivity=2); cnt = np.bincount(lab.ravel())
    keep = cnt >= int(60 / 0.54); keep[0] = False; return keep[lab]
def topo(sk):
    nb = convolve(sk.astype(np.uint8), np.ones((3, 3), np.uint8), mode="constant") - 1
    return int(((nb == 1) & sk).sum()), int(((nb >= 3) & sk).sum())      # endpoints, junction px
def steger_tile(t):
    from ridge_detection.lineDetector import LineDetector
    B = tile_window(*t)
    if B is None: return t, np.zeros((0, 2)), 0, 0
    out = []
    for dark in ("LIGHT", "DARK"):
        p = {"path_to_file": "x", "mandatory_parameters": {"Sigma": 2.0, "Lower_Threshold": 1.5, "Upper_Threshold": 3.0, "Maximum_Line_Length": 0, "Minimum_Line_Length": 0, "Darkline": dark, "Overlap_resolution": "NONE"},
             "optional_parameters": {"Line_width": 6, "High_contrast": 200, "Low_contrast": 60},
             "further_options": {"Correct_position": True, "Estimate_width": False, "doExtendLine": True, "Show_junction_points": False, "Show_IDs": False, "Display_results": False, "Preview": False, "Make_Binary": False, "save_on_disk": False}}
        res = LineDetector(params=p).detectLines(B.astype(np.float64)); pts = []
        for c in (res or []):
            r, col = np.asarray(c.row), np.asarray(c.col)
            if len(r) * 1.0 * 0.54 < 60: continue                                   # >= ~60 m
            keep = (r >= M) & (r < 512 + M) & (col >= M) & (col < 512 + M)
            pts.append(np.c_[r[keep] - M, col[keep] - M])
        out.append(np.vstack(pts) if pts else np.zeros((0, 2)))
    return t, out, 0, 0
if __name__ == "__main__":
    ts = T.needed_tiles(T.load_track()); res = {}; stats = {}
    rng = np.random.default_rng(2); samp = [ts[i] for i in rng.choice(len(ts), 20, replace=False)]
    for pol in (("bright", "dark") if not os.path.exists(os.path.join(AUX, "meijering.npz")) else ()):
        black = pol == "dark"; v = np.concatenate([meijering(tile_window(*t), sigmas=(1, 2, 3), black_ridges=black)[M:-M, M:-M].ravel()[::50] for t in samp])
        for q in QS:
            th = float(np.quantile(v, q)); pts = []; ep = jn = 0
            for t in ts:
                B = tile_window(*t)
                if B is None: continue
                sk = clean(meijering(B, sigmas=(1, 2, 3), black_ridges=black)[M:-M, M:-M] > th); e, j = topo(sk); ep += e; jn += j
                ii, jj = np.nonzero(sk)
                if len(ii): pts.append(px_to_m(t[0], t[1], ii, jj))
            k = f"meijering_{pol}_{q}"; res[k] = np.concatenate(pts); stats[k] = (ep, jn); print(k, len(res[k]) * .54 / 1000, "km", flush=True)
    if res:
        np.savez(os.path.join(AUX, "meijering.npz"), **res)
        import json; json.dump(stats, open(os.path.join(AUX, "meijering_topo.json"), "w"))
    with Pool(int(os.environ.get("NPROC", 8))) as pool:
        outs = []
        for n, o in enumerate(pool.imap(steger_tile, ts, chunksize=2)):
            outs.append(o)
            if n % 20 == 0: print('steger tiles', n, '/', len(ts), flush=True)
    st = {}
    for pi, pol in enumerate(("light", "dark")):
        pts = [px_to_m(t[0], t[1], o[pi][:, 0], o[pi][:, 1]) for t, o, _, _ in outs if len(o[pi])]
        st[f"steger_{pol}"] = np.vstack(pts) if pts else np.zeros((0, 2)); print("steger", pol, len(st[f"steger_{pol}"]) * 1.0 * .54 / 1000, "km-ish", flush=True)
    np.savez(os.path.join(AUX, "steger.npz"), **st)
