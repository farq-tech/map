#!/usr/bin/env python3
"""[round 2: multi-model] Independent cross-check: baseline vs DesertMaps-fine-tuned model on the authorized Thumamah GPS trace (NOT part of any training/val/test split).
The trace is read from the research checkout for INTERNAL evaluation only; only aggregate numbers are written. python 08_thumamah_check.py <data_dir>"""
import os, sys, json
os.environ['PYTORCH_ENABLE_MPS_FALLBACK'] = '1'
import numpy as np, torch
from PIL import Image
from scipy.ndimage import distance_transform_edt
from skimage.morphology import skeletonize
import xml.etree.ElementTree as ET
from shapely.geometry import shape, box, LineString
from shapely import STRtree
D = sys.argv[1]
sys.path.insert(0, '/Users/m4pro/code/map-wt/desertmaps-study/docs/desertmaps-study/scripts'); import tilelib as T
RO = '/Users/m4pro/farq-map/research/sary-albarq-road-extraction'; REPO = f'{RO}/vendor/sam_road'
CKPT = f'{RO}/data/spacenet_vitb_256_e10.ckpt'; CFG = f'{REPO}/config/toponet_vitb_256_spacenet.yaml'
sys.path.insert(0, REPO); sys.path.insert(0, f'{REPO}/sam')
cwd = os.getcwd(); os.chdir(REPO)
from model import SAMRoad
from utils import load_config
cfg = load_config(CFG); cfg.SAM_CKPT_PATH = f'{REPO}/{cfg.SAM_CKPT_PATH}'
model = SAMRoad(cfg); ck = torch.load(CKPT, map_location='cpu', weights_only=False); model.load_state_dict(ck['state_dict'], strict=True); os.chdir(cwd)
dev = torch.device('mps'); model.to(dev).eval()
pts = []
for e in ET.parse(f'{RO}/data/authorized-thumamah-west.kml').getroot().iter():
    if e.tag.endswith('coordinates') and e.text:
        for t in e.text.split():
            p = t.split(',')
            if len(p) >= 2: pts.append((float(p[0]), float(p[1])))
trace = LineString(pts)
osm = [shape(f['geometry']) for f in json.load(open(f'{RO}/output/saudi_osm_desert_tracks_weak_labels.geojson'))['features']]
tree = STRtree(osm)
tiles = set()
for lo, la in pts:
    x, y = T.lonlat_to_tilef(lo, la); tiles.add((int(x), int(y)))
tiles = sorted(tiles); print('tiles', len(tiles)); T.fetch_many(tiles, 4)
def px(coords, t): return [((T.lonlat_to_tilef(lo, la)[0] - t[0]) * 256, (T.lonlat_to_tilef(lo, la)[1] - t[1]) * 256) for lo, la in coords]
from PIL import ImageDraw
data = []
for t in tiles:
    p = T.fetch(*t)
    if not p: continue
    im = np.asarray(Image.open(p).convert('RGB').resize((256, 256), Image.BOX))
    lo0, la0 = T.tilef_to_lonlat(t[0] - .2, t[1] - .2); lo1, la1 = T.tilef_to_lonlat(t[0] + 1.2, t[1] + 1.2); bb = box(lo0, la1, lo1, la0)
    g = trace.intersection(bb)
    gt = Image.new('L', (256, 256), 0); d = ImageDraw.Draw(gt)
    for ln in ([g] if g.geom_type == 'LineString' else list(getattr(g, 'geoms', []))):
        if ln.geom_type == 'LineString': d.line(px(list(ln.coords), t), fill=255, width=4)
    ig = Image.new('L', (256, 256), 0); d2 = ImageDraw.Draw(ig)
    for gi in tree.query(bb):
        for ln in (osm[gi].geoms if osm[gi].geom_type == 'MultiLineString' else [osm[gi]]): d2.line(px(list(ln.coords), t), fill=255, width=3)
    G = np.asarray(gt) > 0; I = np.asarray(ig) > 0
    ign = (distance_transform_edt(~I) <= 12) if I.any() else np.zeros_like(G)
    if G.any(): ign &= ~(distance_transform_edt(~G) <= 6)
    data.append((im, G, ign, (distance_transform_edt(~I) <= 15) if I.any() else np.zeros_like(G)))
print('usable tiles', len(data))
TOL = 14
tags = sys.argv[2:]
def probs():
    out = []
    for i in range(0, len(data), 16):
        with torch.inference_mode():
            s, _ = model.infer_masks_and_img_features(torch.from_numpy(np.stack([d[0] for d in data[i:i + 16]])).float().to(dev)); out += list(s[..., 1].cpu().numpy())
    return out
def rows_for(pr, thr):
    rows = []
    for p, (_, G, ign, O) in zip(pr, data):
        pred = p > thr; ps = skeletonize(pred) if pred.any() else pred; gs = skeletonize(G) if G.any() else G
        dp = distance_transform_edt(~ps) if ps.any() else np.full(G.shape, 1e3)
        rows.append((int((gs & (dp <= TOL)).sum()), int(gs.sum()), int((gs & O & (dp <= TOL)).sum()), int((gs & O).sum()), int((gs & ~O & (dp <= TOL)).sum()), int((gs & ~O).sum())))
    return np.array(rows)
allrows = {}
for tag in tags:
    path = f'{D}/runs/ft_v1_state.pt' if tag == 'round1' else f'{D}/runs_round2/{tag}_state.pt'
    model.load_state_dict(torch.load(path, map_location='cpu')); model.to(dev).eval(); pr = probs()
    allrows[tag] = {thr: rows_for(pr, thr) for thr in (0.3, 0.5)}
    print(tag, 'done', flush=True)
rng = np.random.default_rng(0); ix = [rng.integers(0, len(data), len(data)) for _ in range(2000)]
def rec(a, num, den): return a[:, num].sum() / max(a[:, den].sum(), 1)
out = {}
for thr in (0.3, 0.5):
    out[f'thr_{thr}'] = {}
    for tag in tags:
        a = allrows[tag][thr]
        d = {}
        for nm, (n_, d_) in dict(all=(0, 1), osm=(2, 3), no_osm=(4, 5)).items():
            bs = [rec(a[i], n_, d_) for i in ix]; d[nm] = dict(R=float(rec(a, n_, d_)), ci95=[float(np.percentile(bs, 2.5)), float(np.percentile(bs, 97.5))], px=int(a[:, d_].sum()))
        out[f'thr_{thr}'][tag] = d
    # paired: each v2 seed vs v1 same seed, and v2 pooled vs v1 pooled
    pairs = {}
    for sd in ('1', '2'):
        if f'v1_s{sd}' in allrows and f'v2_s{sd}' in allrows:
            A, B = allrows[f'v1_s{sd}'][thr], allrows[f'v2_s{sd}'][thr]
            pairs[f'seed{sd}'] = {nm: dict(dR=float(rec(B, n_, d_) - rec(A, n_, d_)), ci95=[float(np.percentile([rec(B[i], n_, d_) - rec(A[i], n_, d_) for i in ix], q)) for q in (2.5, 97.5)]) for nm, (n_, d_) in dict(all=(0, 1), osm=(2, 3), no_osm=(4, 5)).items()}
    if all(f'v{k}_s{sd}' in allrows for k in (1, 2) for sd in ('1', '2')):
        A = (allrows['v1_s1'][thr] + allrows['v1_s2'][thr]); B = (allrows['v2_s1'][thr] + allrows['v2_s2'][thr])
        pairs['pooled_2_seeds'] = {nm: dict(dR=float(rec(B, n_, d_) - rec(A, n_, d_)), ci95=[float(np.percentile([rec(B[i], n_, d_) - rec(A[i], n_, d_) for i in ix], q)) for q in (2.5, 97.5)]) for nm, (n_, d_) in dict(all=(0, 1), osm=(2, 3), no_osm=(4, 5)).items()}
    out[f'thr_{thr}']['paired_v2_minus_v1'] = pairs
json.dump(out, open(f'{D}/runs_round2/thumamah_multi.json', 'w'), indent=1); print(json.dumps(out, indent=1)[:4000])
