"""Summarise experiment 2: per-fold numbers incl. GPS-only precision (not diluted by OSM tracks), skeleton km, stitched cross-validated coverage figure."""
import json, os, numpy as np
from scipy.spatial import cKDTree
from common import *
OUT = os.path.join(os.path.dirname(__file__), "..", "out")
Z = np.load(os.path.join(AUX, "samples.npz")); d, cls = Z["d"], Z["cls"]; dirt = np.isin(cls, ["dirt_default", "dirt_osm_track"]); yk = d[:, 1] / 1000
zones = {"north": yk > 8, "middle": (yk >= -3) & (yk <= 8), "south": yk < -3}
gps = cKDTree(d); S = {}; cov_all = {}
for f, zm in zones.items():
    for tag in ("ft", "zeroshot"):
        r = json.load(open(os.path.join(OUT, f"exp2_{f}_{tag}.json"))); pts = np.load(os.path.join(AUX, f"exp2_pts_{f}_{tag}.npy"))
        dg = gps.query(pts)[0] if len(pts) else np.array([])
        skel_km = len(pts) / 1000.0; tp_km = float((dg <= 30).sum() / 1000.0) if len(pts) else 0.0
        cov = r["coverage_30m"]; prec_gps = float((dg <= 30).mean()) if len(pts) else 0.0
        S[f"{f}_{tag}"] = dict(dirt_km=r["dirt_km_in_zone"], covered_km_30m=r["covered_km_30m"], coverage_30m=cov, control_p95=r["control_30m_p95"], frac_controls_ge=r["frac_controls_ge_30m"],
                               precision_osm_plus_gps=r["precision_30m_gps_plus_osm_tracks"], precision_osm_plus_gps_control=r["precision_30m_control_p50"],
                               precision_gps_only=prec_gps, skeleton_km=skel_km, skeleton_km_within30m_gps=tp_km, f1_cov_vs_gps_only_prec=(2 * cov * prec_gps / (cov + prec_gps)) if cov + prec_gps else 0,
                               pass_gates=r["pass_gates"], gate_cov_ge_50=cov >= .5, gate_prec_ge_50=r["precision_30m_gps_plus_osm_tracks"] >= .5, beats_controls=cov > r["control_30m_p95"])
        if tag == "ft": cov_all[f] = (pts, zm)
json.dump(S, open(os.path.join(OUT, "exp2_summary.json"), "w"), indent=1, default=float)
for k, v in S.items(): print(k, {a: (round(b, 3) if isinstance(b, float) else b) for a, b in v.items()})
tot_cov = sum(S[f"{f}_ft"]["covered_km_30m"] for f in zones); tot = sum(S[f"{f}_ft"]["dirt_km"] for f in zones); print("cross-validated total", tot_cov, tot, tot_cov / tot)
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
fig, ax = plt.subplots(figsize=(7, 8)); covered = np.zeros(len(d), bool)
for f, (pts, zm) in cov_all.items():
    if len(pts): covered[zm] = cKDTree(pts).query(d[zm])[0] <= 30
pav = cls == "paved"
ax.scatter(d[~covered & ~pav, 0] / 1000, d[~covered & ~pav, 1] / 1000, s=4, c="#d73027", label="dirt NOT covered")
ax.scatter(d[covered & ~pav, 0] / 1000, d[covered & ~pav, 1] / 1000, s=7, c="#1a9850", label="dirt covered <=30 m")
ax.scatter(d[pav, 0] / 1000, d[pav, 1] / 1000, s=4, c="#4575b4", label="paved (excluded)")
for yb in (-3, 8): ax.axhline(yb, c="k", lw=.6, ls="--")
ax.set_aspect("equal"); ax.legend(fontsize=8); ax.set_title(f"Exp 2: held-out coverage (each sector predicted by a model that never saw it)\ncovered {tot_cov:.1f} / {tot:.1f} km = {tot_cov/tot:.0%}")
fig.savefig(os.path.join(OUT, "exp2_coverage_map.png"), dpi=110, bbox_inches="tight")
