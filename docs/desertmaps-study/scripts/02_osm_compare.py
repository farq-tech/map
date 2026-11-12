#!/usr/bin/env python3
"""Compare DesertMaps lines with the OSM desert-track layer we hold (buffer + direction match).
Run with the research .venv python: python -I 02_osm_compare.py <data_dir> <osm_geojson>"""
import sys, json, numpy as np, shapely
from shapely.geometry import shape, LineString
from shapely import STRtree
from pyproj import Transformer
D, OSM = sys.argv[1], sys.argv[2]
tr = Transformer.from_crs(4326, 32638, always_xy=True)
def proj(g):
    return shapely.transform(g, lambda a: np.column_stack(tr.transform(a[:, 0], a[:, 1])))
dm = json.load(open(f'{D}/geojson/desertmaps_all_lines.geojson'))
osm = json.load(open(OSM))['features']
osm_g = [proj(shape(f['geometry'])) for f in osm]
osm_cls = [f['properties'].get('class') or f['properties'].get('highway') or '' for f in osm]
print('osm feats', len(osm_g), 'keys', list(osm[0]['properties'].keys()))
tree = STRtree(osm_g)
STEP = 20.0
tot = {'km': 0, 'd15': 0, 'd30': 0, 'd30dir': 0}
rows = []
for ft in dm['features']:
    p = ft['properties']
    g = proj(shape(ft['geometry'])); L = g.length
    if L < 1: continue
    n = max(2, int(L // STEP) + 1)
    s = np.linspace(0, L, n)
    pts = shapely.line_interpolate_point(g, s)
    # tangent
    a = shapely.line_interpolate_point(g, np.clip(s - 5, 0, L)); b = shapely.line_interpolate_point(g, np.clip(s + 5, 0, L))
    ta = np.column_stack([shapely.get_x(b) - shapely.get_x(a), shapely.get_y(b) - shapely.get_y(a)])
    ta /= np.maximum(np.linalg.norm(ta, axis=1, keepdims=True), 1e-9)
    idx, dist = tree.query_nearest(pts, return_distance=True, all_matches=False)
    # query_nearest returns (input_idx, tree_idx)
    inp, tix = idx
    d = np.full(n, 1e9); ti = np.full(n, -1)
    d[inp] = dist; ti[inp] = tix
    dirok = np.zeros(n, bool)
    for i in range(n):
        if d[i] <= 30 and ti[i] >= 0:
            og = osm_g[ti[i]]
            pos = shapely.line_locate_point(og, pts[i])
            o1 = shapely.line_interpolate_point(og, max(pos - 5, 0)); o2 = shapely.line_interpolate_point(og, min(pos + 5, og.length))
            v = np.array([o2.x - o1.x, o2.y - o1.y]); nv = np.linalg.norm(v)
            if nv > 0: dirok[i] = abs(np.dot(v / nv, ta[i])) >= 0.9
    w = L / n / 1000  # km per sample
    k15 = float((d <= 15).sum() * w); k30 = float((d <= 30).sum() * w); k30d = float(((d <= 30) & dirok).sum() * w)
    p.update(osm_dup15_frac=round(k15 / (L / 1000), 3), osm_dup30_frac=round(k30 / (L / 1000), 3),
             osm_dup30dir_frac=round(k30d / (L / 1000), 3), osm_new_km=round(L / 1000 - k30d, 3),
             osm_median_dist_m=round(float(np.median(d)), 1), osm_nearest_class=osm_cls[int(ti[np.argmin(d)])] if (ti >= 0).any() else None)
    if p['osm_dup30dir_frac'] >= 0.8: p['osm_status'] = 'duplicate'
    elif p['osm_dup30dir_frac'] >= 0.2: p['osm_status'] = 'partial'
    else: p['osm_status'] = 'new'
json.dump(dm, open(f'{D}/geojson/desertmaps_lines_osmcmp.geojson', 'w'), ensure_ascii=False)
# summary
import collections
S = collections.defaultdict(lambda: collections.defaultdict(float))
for ft in dm['features']:
    p = ft['properties']
    if 'osm_status' not in p: continue
    for key in ((p['region'], p['line_kind_folder']), ('ALL', p['line_kind_folder'])):
        S[key]['segs'] += 1; S[key]['km'] += p['length_km']
        S[key]['dup30dir_km'] += p['osm_dup30dir_frac'] * p['length_km']; S[key]['dup15_km'] += p['osm_dup15_frac'] * p['length_km']
        S[key]['dup30_km'] += p['osm_dup30_frac'] * p['length_km']; S[key]['new_km'] += p['osm_new_km']
        S[key]['n_' + p['osm_status']] += 1
out = {f'{k[0]}|{k[1]}': {a: round(b, 2) for a, b in v.items()} for k, v in S.items()}
json.dump(out, open(f'{D}/geojson/osm_compare_summary.json', 'w'), ensure_ascii=False, indent=1)
for k, v in out.items(): print(k, v)
