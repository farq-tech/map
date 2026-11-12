#!/usr/bin/env python3
"""Independent cross-check: baseline vs DesertMaps-fine-tuned model on the authorized Thumamah GPS trace (NOT part of any training/val/test split).
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
def probs():
    out = []
    for i in range(0, len(data), 16):
        with torch.inference_mode():
            s, _ = model.infer_masks_and_img_features(torch.from_numpy(np.stack([d[0] for d in data[i:i + 16]])).float().to(dev)); out += list(s[..., 1].cpu().numpy())
    return out
def score(pr, thr, use_ignore):
    rows = []
    for p, (_, G, ign, _o) in zip(pr, data):
        pred = p > thr; ps = skeletonize(pred) if pred.any() else pred; gs = skeletonize(G) if G.any() else G
        dg = distance_transform_edt(~G) if G.any() else np.full(G.shape, 1e3); dp = distance_transform_edt(~ps) if ps.any() else np.full(G.shape, 1e3)
        vp = ps & ~ign if use_ignore else ps
        rows.append((int((vp & (dg <= TOL)).sum()), int(vp.sum()), int((gs & (dp <= TOL)).sum()), int(gs.sum()), int((gs & _o & (dp <= TOL)).sum()), int((gs & _o).sum()), int((gs & ~_o & (dp <= TOL)).sum()), int((gs & ~_o).sum())))
    a = np.array(rows); tp_p, n_p, tp_r, n_r, tr_o, n_o, tr_n, n_n = a.sum(0); P = tp_p / max(n_p, 1); R = tp_r / max(n_r, 1)
    rng = np.random.default_rng(0); boots = []
    for _ in range(1000):
        ix = rng.integers(0, len(a), len(a)); q = a[ix].sum(0); boots.append(q[2] / max(q[3], 1))
    return dict(P=float(P), R=float(R), F1=float(2 * P * R / max(P + R, 1e-9)), R_ci95=[float(np.percentile(boots, 2.5)), float(np.percentile(boots, 97.5))], gt_skeleton_px=int(n_r), R_where_OSM_has_track=float(tr_o / max(n_o, 1)), px_OSM=int(n_o), R_where_OSM_has_no_track=float(tr_n / max(n_n, 1)), px_noOSM=int(n_n))
res = {}
model.eval(); pb = probs()
model.load_state_dict(torch.load(f'{D}/runs/ft_v1_state.pt', map_location='cpu')); model.to(dev).eval(); pf = probs()
for thr in (0.3, 0.5):
    res[f'thr_{thr}'] = {'baseline': {'osm_ignored': score(pb, thr, True), 'osm_not_ignored': score(pb, thr, False)},
                         'finetuned_desertmaps_v1': {'osm_ignored': score(pf, thr, True), 'osm_not_ignored': score(pf, thr, False)}}
res['note'] = 'trace not in any DM split; GT includes ~11% paved sections (not excluded); tolerance 15 m; numbers only'
json.dump(res, open(f'{D}/runs/thumamah_check.json', 'w'), indent=1); print(json.dumps(res, indent=1))
