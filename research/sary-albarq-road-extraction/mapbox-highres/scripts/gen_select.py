"""Select test traces for the generalization test (Qassim + Riyadh-Qassim corridor) from OSM public GPS-trace runs.
Raw scans live OUTSIDE git (/private/tmp/mbx-gen-aux). Output (trace coordinates) also stays outside git; only numbers are committed.
Pre-registered selection: runs from gen aux, split at point gaps >400 m; take a contiguous CROP_KM crop from the start of each chosen run."""
import re, glob, math, json, sys, os
GEN = "/private/tmp/mbx-gen-aux"; CROP_KM = 10.0
def hv(p, q): return math.hypot((q[0]-p[0])*110.6e3, (q[1]-p[1])*100.5e3)
def runs():
    for fn in sorted(glob.glob(f"{GEN}/raw/*.txt")):
        for ti, blk in enumerate(re.findall(r"<trkseg>(.*?)</trkseg>", open(fn).read(), re.S)):
            pts = [(float(a), float(b)) for a, b in re.findall(r'<trkpt lat="([-\d.]+)" lon="([-\d.]+)"', blk)]
            cur = [pts[0]] if pts else []
            for p, q in zip(pts, pts[1:]):
                if hv(p, q) > 400:
                    if len(cur) > 1: yield os.path.basename(fn), ti, cur
                    cur = [q]
                else: cur.append(q)
            if len(cur) > 1: yield os.path.basename(fn), ti, cur
# Rejected before any run: B (osm-confirmed Qassim, 3 km but only 0.5x0.8 km extent = circling in place), loop at 25.756,44.51 (0.4 km extent). 
# (id, region, class, file, trkseg index, start lat, start lon)  -- start matched to 3 decimals
CHOSEN = [("A", "corridor", "osm_confirmed_dirt", "corridor_24.80_46.00.txt", 1, 24.951, 46.003),
          ("C", "qassim",   "unverified_unmapped", None, None, 26.610, 43.508),
          ("D", "qassim",   "unverified_unmapped", None, None, 26.909, 43.000),
          ("E", "corridor", "unverified_unmapped", None, None, 25.158, 45.389),
          ("F", "corridor", "unverified_unmapped", None, None, 25.417, 45.250)]
out = {}
allr = list(runs())
for tid, reg, cls, fn, ti, la, lo in CHOSEN:
    cand = [(f, t, c) for f, t, c in allr if (fn is None or (f == fn and t == ti)) and abs(c[0][0]-la) < 6e-4 and abs(c[0][1]-lo) < 6e-4 and f.startswith(reg)]
    if not cand: print("NOT FOUND", tid); continue
    f, t, c = max(cand, key=lambda x: len(x[2]))        # the longest run starting there
    acc = 0; k = 1
    while k < len(c) and acc < CROP_KM*1000: acc += hv(c[k-1], c[k]); k += 1
    out[tid] = dict(region=reg, cls=cls, src=f, km=round(acc/1000, 2), n=k, pts=c[:k])
json.dump(out, open(f"{GEN}/test_traces.json", "w"))
for k, v in out.items(): print(k, v["region"], v["cls"], v["km"], "km", v["n"], "pts", round(v["n"]/max(v["km"],.1), 1), "pts/km")
