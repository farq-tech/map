#!/usr/bin/env python3
"""First local fine-tune (Apple MPS, no paid compute) of the SpaceNet-3 SAM-Road checkpoint on DesertMaps-verified labels,
with a no-fine-tune baseline evaluated on the SAME held-out blocks.  Road channel only; loss masked by an ignore map.
usage: 06_train_eval.py <data_dir> baseline|train [steps]   (run with research .sam-venv python)"""
import os, sys, json, time, math
os.environ['PYTORCH_ENABLE_MPS_FALLBACK'] = '1'
import numpy as np, torch, torch.nn.functional as F
from PIL import Image
from scipy.ndimage import distance_transform_edt
from skimage.morphology import skeletonize
D, MODE = sys.argv[1], sys.argv[2]; STEPS = int(sys.argv[3]) if len(sys.argv) > 3 else 900
RO = '/Users/m4pro/farq-map/research/sary-albarq-road-extraction'; REPO = f'{RO}/vendor/sam_road'
CKPT = f'{RO}/data/spacenet_vitb_256_e10.ckpt'; CFG = f'{REPO}/config/toponet_vitb_256_spacenet.yaml'
BASE = f'{D}/dataset_v1'; RUN = f'{D}/runs'; os.makedirs(RUN, exist_ok=True)
sys.path.insert(0, REPO); sys.path.insert(0, f'{REPO}/sam')
sys.argv = [f'{REPO}/inferencer.py', '--config', CFG, '--checkpoint', CKPT, '--device', 'mps']
cwd = os.getcwd(); os.chdir(REPO)
from model import SAMRoad
from utils import load_config
cfg = load_config(CFG); cfg.SAM_CKPT_PATH = f'{REPO}/{cfg.SAM_CKPT_PATH}'
model = SAMRoad(cfg); ck = torch.load(CKPT, map_location='cpu', weights_only=False); model.load_state_dict(ck['state_dict'], strict=True); os.chdir(cwd)
dev = torch.device('mps'); model.to(dev)
man = json.load(open(f'{BASE}/manifest.json'))
def terrain(m):  # fixed rule, set before any model result was seen
    if m['lum'] < 110: return 'rocky_dark'
    if m['sat'] > 0.28 and m['tex'] < 7: return 'sand_orange'
    return 'gravel_plain'
for m in man: m['terrain'] = terrain(m)
def load(m):
    n = m['tile']; sp = m['split']
    return (np.asarray(Image.open(f'{BASE}/{sp}/img/{n}.png').convert('RGB')), np.asarray(Image.open(f'{BASE}/{sp}/road/{n}.png')) > 0, np.asarray(Image.open(f'{BASE}/{sp}/ignore/{n}.png')) > 0)
def road_prob(imgs):
    with torch.inference_mode():
        x = torch.from_numpy(np.stack(imgs)).float().to(dev)
        s, _ = model.infer_masks_and_img_features(x)
        return s[..., 1].cpu().numpy()
TOL = 14  # px ~ 15 m
def counts(prob, road, ign, thr):
    pred = prob > thr; ps = skeletonize(pred) if pred.any() else pred; gs = skeletonize(road) if road.any() else road
    d_gt = distance_transform_edt(~road) if road.any() else np.full(road.shape, 1e3)
    d_pr = distance_transform_edt(~ps) if ps.any() else np.full(road.shape, 1e3)
    valid_p = ps & ~ign
    tp_p = int((valid_p & (d_gt <= TOL)).sum()); n_p = int(valid_p.sum()); tp_r = int((gs & (d_pr <= TOL)).sum()); n_r = int(gs.sum())
    return tp_p, n_p, tp_r, n_r
def evaluate(split, thrs, tag):
    ms = [m for m in man if m['split'] == split]; probs = []
    for i in range(0, len(ms), 16):
        probs += list(road_prob([load(m)[0] for m in ms[i:i + 16]]))
    res = {}
    for thr in thrs:
        rows = []
        for m, p in zip(ms, probs):
            _, r, ig = load(m); rows.append(counts(p, r, ig, thr))
        res[thr] = (ms, np.array(rows))
    return res
def f1(a):
    tp_p, n_p, tp_r, n_r = a.sum(0); P = tp_p / max(n_p, 1); R = tp_r / max(n_r, 1); return P, R, (2 * P * R / max(P + R, 1e-9))
THRS = [0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
def full_eval(tag):
    out = {'tag': tag}
    val = evaluate('val', THRS, tag); best = max(THRS, key=lambda t: f1(val[t][1])[2]); out['val'] = {str(t): dict(zip('PRF', map(float, f1(val[t][1])))) for t in THRS}; out['best_thr_on_val'] = best
    tst = evaluate('test', sorted(set(THRS + [best])), tag); ms = tst[0.5][0]
    out['test'] = {}
    rng = np.random.default_rng(0)
    for name, thr in (('thr_0.5', 0.5), ('thr_val_best', best)):
        a = tst[thr][1]; P, R, F = f1(a); boots = []
        for _ in range(1000):
            ix = rng.integers(0, len(a), len(a)); boots.append(f1(a[ix])[2])
        grp = {}
        for key in ('region', 'terrain'):
            for v in sorted(set(m[key] for m in ms)):
                ix = [i for i, m in enumerate(ms) if m[key] == v]; P_, R_, F_ = f1(a[ix]); grp[f'{key}={v}'] = dict(n_tiles=len(ix), P=float(P_), R=float(R_), F1=float(F_))
        out['test'][name] = dict(thr=thr, n_tiles=len(a), P=float(P), R=float(R), F1=float(F), F1_ci95=[float(np.percentile(boots, 2.5)), float(np.percentile(boots, 97.5))], groups=grp, per_tile=a.tolist())
    out['test_tiles'] = [m['tile'] for m in ms]
    return out
if MODE == 'baseline':
    model.eval(); r = full_eval('baseline_no_finetune'); json.dump(r, open(f'{RUN}/eval_baseline.json', 'w'), indent=1)
    print(json.dumps({k: v for k, v in r.items() if k not in ('test_tiles',)}, default=lambda o: None)[:3000])
else:
    rng = np.random.default_rng(1); torch.manual_seed(1)
    tr = [m for m in man if m['split'] == 'train']; print('train tiles', len(tr), 'with positives', sum(m['has_dm_positive'] for m in tr))
    cache = {m['tile']: load(m) for m in tr}
    enc = [p for p in model.image_encoder.parameters()]; dec = list(model.map_decoder.parameters())
    opt = torch.optim.Adam([{'params': enc, 'lr': 1e-5}, {'params': dec, 'lr': 1e-4}])
    BS = 8; log = []; t0 = time.time(); model.train()
    for step in range(1, STEPS + 1):
        pos_t = [m for m in tr if m['has_dm_positive']]; neg_t = [m for m in tr if not m['has_dm_positive']]
        batch = [pos_t[i] for i in rng.integers(0, len(pos_t), BS - 1)] + [neg_t[int(rng.integers(0, len(neg_t)))]]
        X, Y, Ig = [], [], []
        for m in batch:
            im, r, ig = cache[m['tile']]; k = int(rng.integers(0, 4)); fl = bool(rng.integers(0, 2))
            f = lambda a: np.ascontiguousarray(np.rot90(a[:, ::-1] if fl else a, k))
            im2 = f(im).astype(np.float32) * float(rng.uniform(0.85, 1.15)); X.append(np.clip(im2, 0, 255)); Y.append(f(r)); Ig.append(f(ig))
        x = torch.from_numpy(np.stack(X)).to(dev); y = torch.from_numpy(np.stack(Y)).float().to(dev); ig = torch.from_numpy(np.stack(Ig)).float().to(dev)
        s, _ = model.infer_masks_and_img_features(x); p = s[..., 1].clamp(1e-6, 1 - 1e-6)
        w = (1 - ig)
        bce = -(y * torch.log(p) * 4.0 + (1 - y) * torch.log(1 - p)) * w; bce = bce.sum() / w.sum().clamp(min=1)
        inter = (p * y * w).sum(); dice = 1 - (2 * inter + 1) / ((p * w).sum() + (y * w).sum() + 1)
        loss = bce + dice; opt.zero_grad(); loss.backward(); opt.step()
        if step % 20 == 0 or step == 1:
            log.append(dict(step=step, loss=float(loss), bce=float(bce), dice=float(dice), sec=round(time.time() - t0, 1))); print(log[-1], flush=True)
    torch.save(model.state_dict(), f'{RUN}/ft_v1_state.pt'); json.dump(log, open(f'{RUN}/train_log.json', 'w'))
    model.eval(); r = full_eval('finetuned_desertmaps_v1'); json.dump(r, open(f'{RUN}/eval_finetuned.json', 'w'), indent=1)
    print(json.dumps({k: v for k, v in r.items() if k not in ('test_tiles',)}, default=lambda o: None)[:3000])
