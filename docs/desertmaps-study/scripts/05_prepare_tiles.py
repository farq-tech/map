#!/usr/bin/env python3
"""Prepare SAM-Road-style 256x256 (z17 tile, ~1.08 m/px) image / road-mask / ignore-mask patches with a spatial block split.
Outputs a NEW versioned folder <data_dir>/dataset_v1 (nothing existing is touched). Run: python 05_prepare_tiles.py <data_dir> <osm_geojson>"""
import sys, json, math, random, hashlib, os, collections, numpy as np, shapely
from shapely.geometry import shape, box
from shapely import STRtree
from PIL import Image, ImageDraw
from scipy.ndimage import distance_transform_edt
sys.path.insert(0, '/Users/m4pro/code/map-wt/desertmaps-study/docs/desertmaps-study/scripts')
import tilelib as T
D, OSM = sys.argv[1], sys.argv[2]
random.seed(20261112); np.random.seed(20261112)
BLOCK = 6; BUFFER_BLOCKS = 1
CAPS = {'الشرقية': 520, 'الرياض': 330, 'حائل': 330, 'المدينة المنورة': 260, 'تبوك': 100, 'مكة المكرمة': 70, 'الحدود الشمالية': 90}
feats = json.load(open(f'{D}/geojson/desertmaps_cleaned_v1.geojson'))['features']
osm = [shape(f['geometry']) for f in json.load(open(OSM))['features']]
osm_tree = STRtree(osm)
def tile_of(lon, lat):
    x, y = T.lonlat_to_tilef(lon, lat); return int(x), int(y)
# --- candidate tiles from verified pieces (sample every 80 m)
from pyproj import Geod
geod = Geod(ellps='WGS84')
cand = collections.defaultdict(lambda: collections.Counter())
for f in feats:
    if f['properties']['tier'] != 'verified_osm': continue
    g = shape(f['geometry']); r = f['properties']['region']
    L = f['properties']['piece_length_km'] * 1000
    for s in np.arange(0, L, 80.0):
        pt = g.interpolate(s / L, normalized=True) if L > 0 else g.coords[0]
        cand[tile_of(pt.x, pt.y)][r] += 1
print('candidate positive tiles', len(cand))
tile_region = {t: c.most_common(1)[0][0] for t, c in cand.items()}
# --- Thumamah hold-out (reference-track bbox +10 km)
import xml.etree.ElementTree as ET
kml = '/Users/m4pro/farq-map/research/sary-albarq-road-extraction/data/authorized-thumamah-west.kml'
xs, ys = [], []
for e in ET.parse(kml).getroot().iter():
    if e.tag.endswith('coordinates') and e.text:
        for t in e.text.split():
            p = t.split(',')
            if len(p) >= 2:
                try: xs.append(float(p[0])); ys.append(float(p[1]))
                except ValueError: pass
th = (min(xs) - 0.1, min(ys) - 0.1, max(xs) + 0.1, max(ys) + 0.1); print('thumamah bbox+0.1deg', th)
def in_thumamah(lon, lat): return th[0] <= lon <= th[2] and th[1] <= lat <= th[3]
def block_split(b):
    h = int(hashlib.md5(f'{b[0]}_{b[1]}_v1'.encode()).hexdigest(), 16) % 10
    return 'test' if h < 2 else ('val' if h == 2 else 'train')
def block(t): return (t[0] // BLOCK, t[1] // BLOCK)
# --- negatives: tiles in each region's DM hull with no OSM/DM line nearby
dm_union_tiles = set(cand)
neg_by_region = collections.defaultdict(list)
for r in CAPS:
    ts = [t for t, rr in tile_region.items() if rr == r]
    if not ts: continue
    x0, x1 = min(t[0] for t in ts) - 12, max(t[0] for t in ts) + 12; y0, y1 = min(t[1] for t in ts) - 12, max(t[1] for t in ts) + 12
    tries = 0
    while len(neg_by_region[r]) < 80 and tries < 4000:
        tries += 1; t = (random.randint(x0, x1), random.randint(y0, y1))
        if t in dm_union_tiles: continue
        lo0, la0 = T.tilef_to_lonlat(t[0] - 1, t[1] - 1); lo1, la1 = T.tilef_to_lonlat(t[0] + 2, t[1] + 2)
        if osm_tree.query(box(lo0, la1, lo1, la0)).size: continue
        if any(abs(t[0] - c[0]) <= 1 and abs(t[1] - c[1]) <= 1 for c in ts[:3000]): continue
        neg_by_region[r].append(t)
# --- assign splits with buffer
test_val_blocks = set()
allt = [(t, tile_region[t], 1) for t in cand if tile_region[t] in CAPS] + [(t, r, 0) for r, v in neg_by_region.items() for t in v]
for t, r, pos in allt:
    if block_split(block(t)) in ('test', 'val'): test_val_blocks.add(block(t))
def buffered(b): return any((b[0] + dx, b[1] + dy) in test_val_blocks for dx in range(-BUFFER_BLOCKS, BUFFER_BLOCKS + 1) for dy in range(-BUFFER_BLOCKS, BUFFER_BLOCKS + 1))
sel = collections.defaultdict(list)
dropped_buffer = 0; thum = 0
for t, r, pos in allt:
    lon, lat = T.tilef_to_lonlat(t[0] + .5, t[1] + .5)
    if in_thumamah(lon, lat): thum += 1; continue
    sp = block_split(block(t))
    if sp == 'train' and buffered(block(t)): dropped_buffer += 1; continue
    sel[(r, sp, pos)].append(t)
final = []
for r, cap in CAPS.items():
    for sp, frac in (('train', .7), ('val', .1), ('test', .2)):
        posl = sel[(r, sp, 1)]; random.shuffle(posl); k = int(cap * frac)
        negl = sel[(r, sp, 0)]; random.shuffle(negl)
        final += [(t, r, sp, 1) for t in posl[:k]] + [(t, r, sp, 0) for t in negl[:max(1, int(k * 0.15))]]
print('selected', collections.Counter((sp, pos) for _, _, sp, pos in final), 'dropped_by_buffer', dropped_buffer, 'thumamah_excluded', thum)
T.fetch_many([t for t, *_ in final], workers=4)
# --- render
lines_by_tier = []
for f in feats:
    g = shape(f['geometry']); lines_by_tier.append((g, f['properties']['tier']))
ltree = STRtree([g for g, _ in lines_by_tier])
base = f'{D}/dataset_v1'
for sp in ('train', 'val', 'test'):
    for k in ('img', 'road', 'ignore'): os.makedirs(f'{base}/{sp}/{k}', exist_ok=True)
manifest = []
def px(coords, t): return [((T.lonlat_to_tilef(lo, la)[0] - t[0]) * 256, (T.lonlat_to_tilef(lo, la)[1] - t[1]) * 256) for lo, la in coords]
for t, r, sp, pos in final:
    p = T.fetch(*t)
    if not p: continue
    im = Image.open(p).convert('RGB').resize((256, 256), Image.BOX)
    lo0, la0 = T.tilef_to_lonlat(t[0] - 0.6, t[1] - 0.6); lo1, la1 = T.tilef_to_lonlat(t[0] + 1.6, t[1] + 1.6)
    road = Image.new('L', (256, 256), 0); dr = ImageDraw.Draw(road)
    unv = Image.new('L', (256, 256), 0); du = ImageDraw.Draw(unv)
    osml = Image.new('L', (256, 256), 0); do = ImageDraw.Draw(osml)
    box_ = box(lo0, la1, lo1, la0)
    for gi in ltree.query(box_):
        g, tier = lines_by_tier[gi]
        for ln in (g.geoms if g.geom_type == 'MultiLineString' else [g]):
            c = px(list(ln.coords), t)
            (dr if tier == 'verified_osm' else du).line(c, fill=255, width=4 if tier == 'verified_osm' else 4)
    for gi in osm_tree.query(box_):
        for ln in (osm[gi].geoms if osm[gi].geom_type == 'MultiLineString' else [osm[gi]]):
            do.line(px(list(ln.coords), t), fill=255, width=3)
    R = np.asarray(road) > 0; U = np.asarray(unv) > 0; O = np.asarray(osml) > 0
    # ignore = 25 px (~27 m) around unverified DM lines + 12 px around OSM tracks, never on top of positives
    ign = np.zeros((256, 256), bool)
    if U.any(): ign |= distance_transform_edt(~U) <= 25
    if O.any(): ign |= distance_transform_edt(~O) <= 12
    ign &= ~(distance_transform_edt(~R) <= 6) if R.any() else ign
    arr = np.asarray(im).astype(np.float32)
    lum = arr.mean(2); sat = (arr.max(2) - arr.min(2)) / np.maximum(arr.max(2), 1)
    hp = lum - np.asarray(Image.fromarray(lum.astype(np.uint8)).resize((64, 64), Image.BOX).resize((256, 256), Image.BILINEAR)).astype(np.float32)
    feat = dict(lum=float(lum.mean()), sat=float(sat.mean()), tex=float(hp.std()))
    name = f'{t[0]}_{t[1]}'
    im.save(f'{base}/{sp}/img/{name}.png'); Image.fromarray((R * 255).astype(np.uint8)).save(f'{base}/{sp}/road/{name}.png'); Image.fromarray((ign * 255).astype(np.uint8)).save(f'{base}/{sp}/ignore/{name}.png')
    manifest.append(dict(tile=name, z=17, x=t[0], y=t[1], region=r, split=sp, has_dm_positive=bool(R.any()), pos_px=int(R.sum()), ignore_px=int(ign.sum()), **feat,
                         imagery='Mapbox Satellite z17@2x, downsampled x2 (BOX) to 256 px (~1.08 m/px); capture date unknown', labels='desertmaps_cleaned_v1 tier=verified_osm (rights: owner-declared, no contract supplied)'))
json.dump(manifest, open(f'{base}/manifest.json', 'w'), ensure_ascii=False, indent=1)
print('written', len(manifest), collections.Counter(m['split'] for m in manifest))
