#!/usr/bin/env python3
"""Build the CLEANED DesertMaps label set (v1) outside git.
 keeps only folder 'طرق صحراوية' (desert_road_line); drops boundary lines / polygon rings.
 splits each line into pieces: tier 'verified_osm' (within 15 m of an OSM track = geometry also confirmed by an independent
 source, so alignment known) vs 'unverified' (new geometry, only 11-14% judged a visible track in review -> NOT positives).
 python -I 04_build_labels.py <data_dir> <osm_geojson>"""
import sys, json, numpy as np, shapely, collections
from shapely.geometry import shape, LineString
from shapely.ops import substring
from shapely import STRtree
from scipy.ndimage import binary_opening, binary_closing
from pyproj import Transformer
D, OSM = sys.argv[1], sys.argv[2]
fw = Transformer.from_crs(4326, 32638, always_xy=True); bw = Transformer.from_crs(32638, 4326, always_xy=True)
proj = lambda g: shapely.transform(g, lambda a: np.column_stack(fw.transform(a[:, 0], a[:, 1])))
unproj = lambda g: shapely.transform(g, lambda a: np.column_stack(bw.transform(a[:, 0], a[:, 1])))
osm = [proj(shape(f['geometry'])) for f in json.load(open(OSM))['features']]
tree = STRtree(osm)
dm = json.load(open(f'{D}/geojson/desertmaps_lines_osmcmp.geojson'))['features']
out = []; drop = collections.Counter(); km = collections.defaultdict(lambda: collections.defaultdict(float))
STEP = 10.0
for ft in dm:
    p = ft['properties']
    if p['line_kind_folder'] != 'desert_road_line':
        drop[p['line_kind_folder']] += 1; continue
    g = proj(shape(ft['geometry'])); L = g.length
    if L < 5: continue
    n = max(2, int(L // STEP) + 1); s = np.linspace(0, L, n)
    pts = shapely.line_interpolate_point(g, s)
    inp, tix = tree.query_nearest(pts, return_distance=False, all_matches=False)
    d = np.full(n, 1e9)
    near = tree.query_nearest(pts, return_distance=True, all_matches=False)
    d[near[0][0]] = near[1]
    v = d <= 15
    v = binary_closing(v, structure=np.ones(3), border_value=0)
    v = binary_opening(v, structure=np.ones(3)) if v.sum() > 3 else v
    # runs
    i = 0
    while i < n:
        j = i
        while j + 1 < n and v[j + 1] == v[i]: j += 1
        a, b = s[i], s[min(j + 1, n - 1)] if j + 1 < n else L
        if b - a >= 1:
            seg = substring(g, a, b)
            if seg.geom_type == 'LineString' and seg.length >= 1:
                q = dict(p); q['tier'] = 'verified_osm' if v[i] else 'unverified'
                q['piece_length_km'] = round(seg.length / 1000, 4)
                q['label_use'] = 'positive' if v[i] else 'ignore_in_loss'
                q['review_policy'] = ('matches OSM within 15 m (independent geometry confirmation); 73% clear in review (n=37), CI 57-85%'
                                      if v[i] else 'new geometry; only 11% clear / 14% clear+faint in review (n=44); 27% misaligned 20-130 m; do NOT use as positive without per-line review')
                out.append({'type': 'Feature', 'properties': q, 'geometry': json.loads(shapely.to_geojson(unproj(seg)))})
                km[p['region']][q['tier']] += seg.length / 1000
        i = j + 1
json.dump({'type': 'FeatureCollection', 'features': out}, open(f'{D}/geojson/desertmaps_cleaned_v1.geojson', 'w'), ensure_ascii=False)
summ = {r: {k: round(x, 1) for k, x in v.items()} for r, v in km.items()}
tot = collections.Counter()
for v in km.values():
    for k, x in v.items(): tot[k] += x
summ['TOTAL'] = {k: round(x, 1) for k, x in tot.items()}
summ['dropped_features_by_kind'] = dict(drop)
json.dump(summ, open(f'{D}/geojson/cleaned_v1_summary.json', 'w'), ensure_ascii=False, indent=1)
print(json.dumps(summ, ensure_ascii=False, indent=1))
