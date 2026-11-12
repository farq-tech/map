#!/usr/bin/env python3
"""Draw a stratified random review sample (seed fixed) and render raw|overlay panels on Mapbox z17@2x."""
import sys, json, random, math, numpy as np, shapely
from shapely.geometry import shape
from shapely import STRtree
from pyproj import Transformer
from PIL import Image, ImageDraw, ImageFont
sys.path.insert(0, '/Users/m4pro/code/map-wt/desertmaps-study/docs/desertmaps-study/scripts')
import tilelib as T
D = sys.argv[1]; OSM = sys.argv[2]
random.seed(20261112)
tr = Transformer.from_crs(4326, 32638, always_xy=True)
proj = lambda g: shapely.transform(g, lambda a: np.column_stack(tr.transform(a[:, 0], a[:, 1])))
dm = json.load(open(f'{D}/geojson/desertmaps_lines_osmcmp.geojson'))['features']
osm = json.load(open(OSM))['features']
osm_g = [proj(shape(f['geometry'])) for f in osm]; tree = STRtree(osm_g)
def pick(cands, n, ban=()):
    by = {}
    for f in cands: by.setdefault(f['properties']['region'], []).append(f)
    regs = sorted(by); out = []; quota = {r: 0 for r in regs}
    pool = {r: random.sample(by[r], len(by[r])) for r in regs}
    # proportional to sqrt(km) with min 1
    w = {r: math.sqrt(sum(f['properties']['length_km'] for f in by[r])) for r in regs}; tw = sum(w.values())
    for r in regs: quota[r] = max(1, round(n * w[r] / tw))
    for r in regs: out += pool[r][:quota[r]]
    return out
dr = [f for f in dm if f['properties']['line_kind_folder'] == 'desert_road_line']
A = pick([f for f in dr if f['properties']['osm_status'] == 'duplicate'], 36)
B = pick([f for f in dr if f['properties']['osm_status'] in ('new', 'partial')], 44)
C = pick([f for f in dm if f['properties']['line_kind_folder'] == 'boundary_line'], 20)
samples = []
for stratum, grp in (('A_desert_dup_osm', A), ('B_desert_new_or_partial', B), ('C_boundary', C)):
    for f in grp:
        g = proj(shape(f['geometry'])); L = g.length
        for _ in range(200):
            s = random.uniform(0.1, 0.9) * L if L > 1000 else L / 2
            pt = shapely.line_interpolate_point(g, s)
            if stratum.startswith('B'):
                if tree.query_nearest(pt, return_distance=True, max_distance=40)[1].size: continue
            break
        lon, lat = tr.transform(pt.x, pt.y, direction='INVERSE')
        samples.append({'stratum': stratum, 'fid': f['properties']['fid'], 'lon': lon, 'lat': lat, 'region': f['properties']['region'],
                        'name': f['properties']['name'], 'folder': f['properties']['folder'], 'osm_status': f['properties']['osm_status'],
                        'length_km': f['properties']['length_km']})
random.shuffle(samples)
for i, s in enumerate(samples): s['sid'] = f'S{i:03d}'
print(len(samples), 'samples')
by_fid = {f['properties']['fid']: f for f in dm}
HALF = 512  # px at @2x (~0.5 m/px) => 1024 px window ~ 550 m
font = ImageFont.load_default()
import os; os.makedirs(f'{D}/review/panels', exist_ok=True)
tiles = set()
for s in samples:
    x, y = T.lonlat_to_tilef(s['lon'], s['lat']); s['_xy'] = (x, y)
    for tx in range(int(x - 1.0), int(x + 1.0) + 1):
        for ty in range(int(y - 1.0), int(y + 1.0) + 1): tiles.add((tx, ty))
print('tiles', len(tiles)); T.fetch_many(sorted(tiles))
def line_px(geom, x0, y0, g_ll):
    return [((a - x0) * 512, (b - y0) * 512) for a, b in (T.lonlat_to_tilef(lo, la) for lo, la in g_ll)]
for s in samples:
    x, y = s['_xy']; tx0, ty0 = int(x - 1.0), int(y - 1.0)
    im, ok = T.mosaic(tx0, ty0, int(x + 1.0), int(y + 1.0))
    cx, cy = (x - tx0) * 512, (y - ty0) * 512
    box = (int(cx - HALF), int(cy - HALF), int(cx + HALF), int(cy + HALF))
    crop = im.crop(box)
    s['missing_imagery_frac'] = round(1 - np.asarray(ok.crop(box)).mean() / 255, 3)
    ov = crop.copy(); d = ImageDraw.Draw(ov)
    # DesertMaps lines in the window
    lo0, la0 = T.tilef_to_lonlat(tx0 + box[0] / 512, ty0 + box[1] / 512); lo1, la1 = T.tilef_to_lonlat(tx0 + box[2] / 512, ty0 + box[3] / 512)
    def draw_ll(coords, col, w):
        pts = [((T.lonlat_to_tilef(lo, la)[0] - tx0) * 512 - box[0], (T.lonlat_to_tilef(lo, la)[1] - ty0) * 512 - box[1]) for lo, la in coords]
        d.line(pts, fill=col, width=w)
    for f in dm:  # cheap bbox filter
        p = f['properties']
        c = f['geometry']['coordinates']
        xs = [q[0] for q in c]; ys = [q[1] for q in c]
        if max(xs) < lo0 or min(xs) > lo1 or max(ys) < la1 or min(ys) > la0: continue
        draw_ll(c, (255, 40, 40) if f['properties']['fid'] == s['fid'] else (255, 160, 0), 2)
    for gi in tree.query(shapely.box(*(np.array(tr.transform(lo0, la1)) .tolist() + np.array(tr.transform(lo1, la0)).tolist()))):
        c = [tr.transform(a, b, direction='INVERSE') for a, b in osm_g[gi].coords]
        draw_ll(c, (0, 220, 255), 1)
    mp = T.mpp(s['lat'])
    for im_, tag in ((crop, 'raw'), (ov, 'overlay')):
        dd = ImageDraw.Draw(im_); bar = int(100 / mp)
        dd.rectangle((10, 1024 - 22, 10 + bar, 1024 - 18), fill=(255, 255, 255)); dd.text((14, 1024 - 40), '100 m', fill=(255, 255, 255), font=font)
    pair = Image.new('RGB', (1800, 900), (20, 20, 20))
    pair.paste(crop.resize((896, 896)), (2, 2)); pair.paste(ov.resize((896, 896)), (902, 2))
    ImageDraw.Draw(pair).text((8, 8), f"{s['sid']} {s['stratum'][:1]} {s['region']} | {s['name'][:30]} | {s['folder']} | osm:{s['osm_status']}", fill=(255, 255, 0), font=font)
    pair.save(f"{D}/review/panels/{s['sid']}.jpg", quality=85); crop.save(f"{D}/review/panels/{s['sid']}_raw1024.jpg", quality=90)
    s['m_per_px_1024'] = round(mp, 3)
    del s['_xy']
json.dump(samples, open(f'{D}/review/samples.json', 'w'), ensure_ascii=False, indent=1)
# contact sheets: 3 per sheet stacked, scaled
import glob
ids = [s['sid'] for s in samples]
for k in range(0, len(ids), 3):
    ims = [Image.open(f'{D}/review/panels/{i}.jpg').resize((1500, 750)) for i in ids[k:k + 3]]
    sh = Image.new('RGB', (1500, 750 * len(ims)))
    for j, im_ in enumerate(ims): sh.paste(im_, (0, 750 * j))
    sh.save(f'{D}/review/sheet_{k // 3:02d}.jpg', quality=82)
print('done')
