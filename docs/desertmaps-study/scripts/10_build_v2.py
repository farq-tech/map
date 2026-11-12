#!/usr/bin/env python3
"""Dataset v2 = v1 + owner-verified cards (read-only inputs). Writes ONLY <data_dir>/dataset_v2_human.
 - correct cards -> positives, re-centred with a Sato ridge snap (the owner's 'correct' means 'a track is there', not 'centreline accurate')
 - wrong cards (not_track / fence_pipeline) -> explicit hard negatives
 - split rules identical to v1: block hash 6x6 tiles; cards in val/test blocks are NOT trained on (-> human_heldout eval set);
   cards in train-blocks adjacent to val/test blocks (buffer) are dropped; Thumamah bbox excluded.
usage: 10_build_v2.py <data_dir> <deck.json> <verdicts.jsonl> <osm_geojson>   (research .venv python)"""
import sys, os, json, math, hashlib, shutil, collections, numpy as np, shapely
from shapely.geometry import shape, box, LineString
from shapely import STRtree
from PIL import Image, ImageDraw
from scipy.ndimage import distance_transform_edt, map_coordinates, median_filter
from skimage.filters import sato
sys.path.insert(0, '/Users/m4pro/code/map-wt/desertmaps-study/docs/desertmaps-study/scripts'); import tilelib as T
D, DECK, VERD, OSM = sys.argv[1:5]
V1 = f'{D}/dataset_v1'; V2 = f'{D}/dataset_v2_human'
BLOCK = 6
def bsplit(b):
    h = int(hashlib.md5(f'{b[0]}_{b[1]}_v1'.encode()).hexdigest(), 16) % 10
    return 'test' if h < 2 else ('val' if h == 2 else 'train')
def block(t): return (t[0] // BLOCK, t[1] // BLOCK)
_m1 = json.load(open(f'{V1}/manifest.json'))
EV = {block((m['x'], m['y'])) for m in _m1 if m['split'] in ('val', 'test')}   # blocks that ACTUALLY hold v1 eval tiles
def buffered(b): return any((b[0] + dx, b[1] + dy) in EV for dx in (-1, 0, 1) for dy in (-1, 0, 1))
th = (46.326076, 24.938103, 46.779337, 25.440356)
deck = {c['pid']: c for c in json.load(open(DECK))['cards']}
V = [json.loads(l) for l in open(VERD)]
V = [v for v in V if not v.get('control')]
print('non-control verdicts', len(V))
osm = [shape(f['geometry']) for f in json.load(open(OSM))['features']]; otree = STRtree(osm)
feats = json.load(open(f'{D}/geojson/desertmaps_cleaned_v1.geojson'))['features']
lg = [(shape(f['geometry']), f['properties']['tier']) for f in feats]; ltree = STRtree([g for g, _ in lg])
def px_of(coords, t, S=256): return [((T.lonlat_to_tilef(lo, la)[0] - t[0]) * S, (T.lonlat_to_tilef(lo, la)[1] - t[1]) * S) for lo, la in coords]
# ---------- ridge snap on the card imagery (z17@2x mosaic), metres-aware
def snap(line):
    mid = np.mean(line, axis=0); x, y = T.lonlat_to_tilef(*mid); tx0, ty0 = int(x) - 1, int(y) - 1
    im, _ = T.mosaic(tx0, ty0, int(x) + 1, int(y) + 1); g = np.asarray(im.convert('L'), float) / 255
    resp = np.maximum(sato(g, sigmas=(2., 3., 4.), black_ridges=False), sato(g, sigmas=(2., 3., 4.), black_ridges=True)); resp /= np.percentile(resp, 99.5) + 1e-9
    pts = np.array([((T.lonlat_to_tilef(lo, la)[0] - tx0) * 512, (T.lonlat_to_tilef(lo, la)[1] - ty0) * 512) for lo, la in line])
    seg = np.hypot(*np.diff(pts, axis=0).T); cum = np.r_[0, np.cumsum(seg)]; n = max(3, int(cum[-1] / 8) + 1); tt = np.linspace(0, cum[-1], n)
    dense = np.stack([np.interp(tt, cum, pts[:, 0]), np.interp(tt, cum, pts[:, 1])], 1)
    tang = np.gradient(dense, axis=0); tang /= np.linalg.norm(tang, axis=1, keepdims=True) + 1e-9; nrm = np.stack([-tang[:, 1], tang[:, 0]], 1)
    mpp = T.mpp(mid[1])
    ms = lambda sh: float(map_coordinates(resp, [(dense + nrm * sh)[:, 1], (dense + nrm * sh)[:, 0]], order=1, mode='nearest').mean())
    cands = np.arange(-30 / mpp, 30 / mpp + 0.5, 3.0); sc = np.array([ms(s) - 0.0008 * abs(s) for s in cands]); rig = float(cands[int(np.argmax(sc))])
    base = dense + nrm * rig; offs = np.arange(-8, 9, 1.0); fine = np.zeros(n)
    for i in range(n):
        xs = base[i, 0] + nrm[i, 0] * offs; ys = base[i, 1] + nrm[i, 1] * offs
        fine[i] = offs[int(np.argmax(map_coordinates(resp, [ys, xs], order=1, mode='nearest') - 0.01 * np.abs(offs)))]
    fine = median_filter(fine, size=7, mode='nearest'); sn = base + nrm * fine[:, None]
    ll = [T.tilef_to_lonlat(tx0 + a / 512, ty0 + b / 512) for a, b in sn]
    tot = np.abs(rig + fine) * mpp
    return [list(p) for p in ll], dict(rigid_m=round(rig * mpp, 1), mean_abs_shift_m=round(float(tot.mean()), 1), max_abs_shift_m=round(float(tot.max()), 1), resp_before=round(ms(0.0), 3), resp_after=round(float(map_coordinates(resp, [sn[:, 1], sn[:, 0]], order=1, mode='nearest').mean()), 3))
# ---------- tile renderer (same recipe as v1)
def render(t, extra_pos=(), extra_neg=(), extra_ign_ring=()):
    p = T.fetch(*t)
    if not p: return None
    im = Image.open(p).convert('RGB').resize((256, 256), Image.BOX)
    lo0, la0 = T.tilef_to_lonlat(t[0] - .6, t[1] - .6); lo1, la1 = T.tilef_to_lonlat(t[0] + 1.6, t[1] + 1.6); bb = box(lo0, la1, lo1, la0)
    def draw(items, width=4):
        img = Image.new('L', (256, 256), 0); d = ImageDraw.Draw(img)
        for ln in items:
            for l in (ln.geoms if ln.geom_type == 'MultiLineString' else [ln]): d.line(px_of(list(l.coords), t), fill=255, width=width)
        return np.asarray(img) > 0
    pos_v = [lg[i][0] for i in ltree.query(bb) if lg[i][1] == 'verified_osm']; unv = [lg[i][0] for i in ltree.query(bb) if lg[i][1] != 'verified_osm']
    R = draw(pos_v); U = draw(unv); O = draw([osm[i] for i in otree.query(bb)], 3)
    HP = draw([LineString(c) for c in extra_pos]); NG = draw([LineString(c) for c in extra_neg], 5)
    ign = np.zeros((256, 256), bool)
    if U.any(): ign |= distance_transform_edt(~U) <= 25
    if O.any(): ign |= distance_transform_edt(~O) <= 12
    if HP.any(): ign |= (distance_transform_edt(~HP) <= 10)          # tolerance ring: owner verdicts tolerate tens of metres
    road = R | HP
    ign &= ~(distance_transform_edt(~road) <= 3) if road.any() else ign
    if NG.any(): ign &= ~(distance_transform_edt(~NG) <= 3)           # explicit negatives are trained on
    wt = np.ones((256, 256), np.float16)
    if HP.any(): wt[distance_transform_edt(~HP) <= 5] = 2.0
    return im, road, ign, NG, wt, int(HP.any()), int(NG.any())
# ---------- cards -> per-tile instructions
cards_out = []; tile_pos = collections.defaultdict(list); tile_neg = collections.defaultdict(list); status = collections.Counter(); hold = []
for v in V:
    c = deck.get(v['pid'])
    if not c or v['verdict'] not in ('correct', 'wrong'): continue
    if v['verdict'] == 'wrong' and v['reason'] not in ('not_track', 'fence_pipeline', 'wadi', 'paved', 'pivot'): continue
    line = c['line']
    if v['verdict'] == 'correct': line2, info = snap(line)
    else: line2, info = line, {}
    tiles = sorted({tuple(map(int, T.lonlat_to_tilef(lo, la))) for lo, la in line2})
    mid = c['mid']; where = 'thumamah' if th[0] <= mid[0] <= th[2] and th[1] <= mid[1] <= th[3] else None
    tsplits = {bsplit(block(t)) for t in tiles}
    if where: use = 'excluded_thumamah'
    elif 'test' in tsplits or 'val' in tsplits: use = 'human_heldout'
    elif any(buffered(block(t)) for t in tiles): use = 'dropped_buffer'
    else: use = 'train'
    status[(v['verdict'], use)] += 1
    rec = dict(pid=v['pid'], source=v['source'], verdict=v['verdict'], reason=v['reason'], use=use, snap=info, tiles=[f'{a}_{b}' for a, b in tiles], region=c.get('region'))
    cards_out.append(rec)
    for t in tiles:
        (tile_pos if v['verdict'] == 'correct' else tile_neg)[(t, use)].append(line2)
print(dict(status))
# ---------- build folders
if os.path.exists(V2): shutil.rmtree(V2)
for sp in ('train', 'val', 'test'):
    for k in ('img', 'road', 'ignore'): os.makedirs(f'{V2}/{sp}/{k}', exist_ok=True); 
    for f in os.listdir(f'{V1}/{sp}/img'):
        for k in ('img', 'road', 'ignore'): shutil.copy2(f'{V1}/{sp}/{k}/{f}', f'{V2}/{sp}/{k}/{f}')
for k in ('img', 'road', 'neg', 'ignore'): os.makedirs(f'{V2}/human_heldout/{k}', exist_ok=True)
os.makedirs(f'{V2}/train/neg', exist_ok=True); os.makedirs(f'{V2}/train/weight', exist_ok=True)
man = json.load(open(f'{V1}/manifest.json')); mm = {m['tile']: m for m in man}
added = []
keys = sorted(set((t, u) for (t, u) in list(tile_pos) + list(tile_neg)))
for (t, use) in keys:
    if use not in ('train', 'human_heldout'): continue
    r = render(t, tile_pos.get((t, use), []), tile_neg.get((t, use), []))
    if r is None: continue
    im, road, ign, NG, wt, hp, ng = r; name = f'{t[0]}_{t[1]}'
    if use == 'train':
        sp = 'train'
        im.save(f'{V2}/train/img/{name}.png'); Image.fromarray((road * 255).astype(np.uint8)).save(f'{V2}/train/road/{name}.png'); Image.fromarray((ign * 255).astype(np.uint8)).save(f'{V2}/train/ignore/{name}.png')
        Image.fromarray((NG * 255).astype(np.uint8)).save(f'{V2}/train/neg/{name}.png'); np.save(f'{V2}/train/weight/{name}.npy', wt)
        if name not in mm: mm[name] = dict(tile=name, z=17, x=t[0], y=t[1], region='human_card', split='train', has_dm_positive=bool(road.any()), pos_px=int(road.sum()), ignore_px=int(ign.sum()), lum=float(np.asarray(im).mean()), sat=0.3, tex=3.0)
        mm[name]['human_pos'] = hp; mm[name]['human_neg'] = ng
        added.append(name)
    else:
        for k, arr in (('img', None), ('road', road), ('neg', NG), ('ignore', ign)):
            (im.save(f'{V2}/human_heldout/img/{name}.png') if k == 'img' else Image.fromarray((arr * 255).astype(np.uint8)).save(f'{V2}/human_heldout/{k}/{name}.png'))
json.dump(list(mm.values()), open(f'{V2}/manifest.json', 'w'), ensure_ascii=False, indent=1)
json.dump(cards_out, open(f'{V2}/cards.json', 'w'), ensure_ascii=False, indent=1)
sh = [c['snap']['mean_abs_shift_m'] for c in cards_out if c['verdict'] == 'correct' and c['snap']]
print('snap mean |shift| m: median', float(np.median(sh)), 'p90', float(np.percentile(sh, 90)), 'n', len(sh))
print('train tiles touched by cards', len(set(added)), 'human_heldout tiles', len(os.listdir(f'{V2}/human_heldout/img')))
