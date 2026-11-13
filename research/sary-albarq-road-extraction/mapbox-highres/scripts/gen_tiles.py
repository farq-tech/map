"""Fetch Mapbox z17@2x tiles for the Thumamah training track + the generalization test traces (cache outside git)."""
import json, numpy as np, thumamah as T, tiles
from concurrent.futures import ThreadPoolExecutor
GEN = "/private/tmp/mbx-gen-aux"
sets = {"thumamah": T.needed_tiles(T.load_track())}
for k, v in json.load(open(f"{GEN}/test_traces.json")).items(): sets[k] = T.needed_tiles(np.array(v["pts"]))
allt = sorted(set().union(*sets.values()))
print({k: len(v) for k, v in sets.items()}, "total unique", len(allt), flush=True)
with ThreadPoolExecutor(6) as ex: list(ex.map(lambda t: tiles.fetch(17, *t), allt))
print("fetched new", tiles.N_FETCHED, flush=True)
