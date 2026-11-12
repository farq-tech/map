"""Narrow (track-width) component: mean(|d|<=2 m) - mean(8<=|d|<=15 m) of the pooled dirt profile, vs 200 lateral-offset controls."""
import json, os, re, numpy as np
src = open(os.path.join(os.path.dirname(__file__), "signal_track.py")).read().split("masks = {")[0]
exec(src)
dirt = np.isin(cls, ["dirt_default", "dirt_osm_track"])
def narrow(P):
    A = np.array([P[i] for i in range(len(P)) if dirt[i] and P[i] is not None]); pr = A.mean(0)
    return float(pr[np.abs(D) <= 2].mean() - pr[(np.abs(D) >= 8) & (np.abs(D) <= 15)].mean()), float(pr[np.abs(D) >= 20].std())
n0, fs = narrow(profs(np.zeros(len(d)))); rng = np.random.default_rng(21); blk = np.arange(len(d)) // 50; c = []
for _ in range(200):
    ob = rng.uniform(60, 75, blk.max() + 1) * rng.choice([-1, 1], blk.max() + 1); c.append(abs(narrow(profs(ob[blk]))[0]))
R = dict(narrow_excess_gray=n0, flank_std=fs, ratio=abs(n0) / fs, control_abs_p50=float(np.median(c)), control_abs_p95=float(np.percentile(c, 95)), frac_controls_ge=float(np.mean(np.array(c) >= abs(n0))))
json.dump(R, open(os.path.join(OUT, "narrow_peak.json"), "w"), indent=1); print(R)
