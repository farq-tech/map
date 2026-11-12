"""Classify each 10 m track sample: dirt / paved / ambiguous by nearest OSM highway within 25 m (else dirt-by-default)."""
import json, os, numpy as np
from common import *
d, tang, s = track_samples(10.0)
L = osm_lines(); cls = np.array(["dirt_default"] * len(d), dtype=object); dmin = {k: np.full(len(d), np.inf) for k in ("paved", "ambig", "dirt")}
for k in dmin:
    ls = [l[1] for l in L if l[0] == k]
    if ls: dmin[k] = dist_to_lines(d, ls)
cls[dmin["dirt"] <= 25] = "dirt_osm_track"; cls[dmin["ambig"] <= 25] = "ambig"; cls[dmin["paved"] <= 25] = "paved"
np.savez(os.path.join(AUX, "samples.npz"), d=d, tang=tang, s=s, cls=cls.astype(str))
import collections; c = collections.Counter(cls); print({k: round(v * 10 / 1000, 1) for k, v in c.items()}, "km")
