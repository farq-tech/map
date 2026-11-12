"""Steger (PyPI ridge-detection; evaluation only) on every 6th corridor tile, LIGHT lines only (port runs ~9 s/tile). Coverage is evaluated only for track samples
(and control samples) whose tile is in the subset."""
import os, sys, json, numpy as np
from detect_more import steger_tile
from detect_ridge import px_to_m
from common import *
ts = T.needed_tiles(T.load_track()); sub = ts[::6]; pts = []
for n, t in enumerate(sub):
    _, o, _, _ = steger_tile(t)
    if len(o[0]): pts.append(px_to_m(t[0], t[1], o[0][:, 0], o[0][:, 1]))
    if n % 10 == 0: print(n, "/", len(sub), flush=True)
np.savez(os.path.join(AUX, "steger_subset.npz"), steger_light=np.vstack(pts), tiles=np.array(sub))
