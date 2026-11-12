#!/usr/bin/env python3
"""Round 2 training: same recipe as 06 (MPS, 900 steps) with trainset v1 | v2 (v2 = v1 + owner-verified cards, pixel weight 2.0, explicit hard negatives).
Evaluated on the SAME v1 held-out val/test tiles + the human_heldout cards. usage: 11_train_v2.py <data_dir> v1|v2 <seed> <tag> [steps]  (research .sam-venv python)"""
import os, sys, json, time
os.environ['PYTORCH_ENABLE_MPS_FALLBACK'] = '1'
import numpy as np, torch
from PIL import Image
from scipy.ndimage import distance_transform_edt
from skimage.morphology import skeletonize
D, SET, SEED, TAG = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]; STEPS = int(sys.argv[5]) if len(sys.argv) > 5 else 900
RO = '/Users/m4pro/farq-map/research/sary-albarq-road-extraction'; REPO = f'{RO}/vendor/sam_road'
CKPT = f'{RO}/data/spacenet_vitb_256_e10.ckpt'; CFG = f'{REPO}/config/toponet_vitb_256_spacenet.yaml'
V1 = f'{D}/dataset_v1'; V2 = f'{D}/dataset_v2_human'; TR = V2 if SET == 'v2' else V1; RUN = f'{D}/runs_round2'; os.makedirs(RUN, exist_ok=True)
sys.path.insert(0, REPO); sys.path.insert(0, f'{REPO}/sam'); cwd = os.getcwd(); os.chdir(REPO)
from model import SAMRoad
from utils import load_config
cfg = load_config(CFG); cfg.SAM_CKPT_PATH = f'{REPO}/{cfg.SAM_CKPT_PATH}'
model = SAMRoad(cfg); ck = torch.load(CKPT, map_location='cpu', weights_only=False); model.load_state_dict(ck['state_dict'], strict=True); os.chdir(cwd)
dev = torch.device('mps'); model.to(dev)
def rd(base, sp, kind, n): return np.asarray(Image.open(f'{base}/{sp}/{kind}/{n}.png'))
man1 = json.load(open(f'{V1}/manifest.json'))
def terrain(m):
    if m['lum'] < 110: return 'rocky_dark'
    if m['sat'] > 0.28 and m['tex'] < 7: return 'sand_orange'
    return 'gravel_plain'
for m in man1: m['terrain'] = terrain(m)
# ---------------- training
rng = np.random.default_rng(SEED); torch.manual_seed(SEED)
mtr = json.load(open(f'{TR}/manifest.json')); tr = [m for m in mtr if m['split'] == 'train']
cache = {}
for m in tr:
    n = m['tile']; z = np.zeros((256, 256), bool)
    cache[n] = (rd(TR, 'train', 'img', n)[:, :, :3], rd(TR, 'train', 'road', n) > 0, rd(TR, 'train', 'ignore', n) > 0,
                (rd(TR, 'train', 'neg', n) > 0) if (SET == 'v2' and os.path.exists(f'{TR}/train/neg/{n}.png')) else z,
                np.load(f'{TR}/train/weight/{n}.npy').astype(np.float32) if (SET == 'v2' and os.path.exists(f'{TR}/train/weight/{n}.npy')) else np.ones((256, 256), np.float32))
pos_t = [m for m in tr if m['has_dm_positive'] and not m.get('human_pos')]; neg_t = [m for m in tr if not m['has_dm_positive']]
hum_t = [m for m in tr if m.get('human_pos') or m.get('human_neg')] if SET == 'v2' else []
print('train', SET, 'tiles', len(tr), 'pos', len(pos_t), 'bg', len(neg_t), 'human tiles', len(hum_t), flush=True)
opt = torch.optim.Adam([{'params': list(model.image_encoder.parameters()), 'lr': 1e-5}, {'params': list(model.map_decoder.parameters()), 'lr': 1e-4}])
model.train(); t0 = time.time(); log = []
for step in range(1, STEPS + 1):
    # identical RNG consumption for v1 and v2: slot 7 is a human tile (v2) or one more regular positive (v1)
    b = [pos_t[i] for i in rng.integers(0, len(pos_t), 6)] + [neg_t[int(rng.integers(0, len(neg_t)))]]
    last = hum_t[int(rng.integers(0, len(hum_t)))] if hum_t else pos_t[int(rng.integers(0, len(pos_t)))]
    if SET == 'v2': rng.integers(0, 2)  # keep stream aligned
    b.append(last)
    X, Y, Ig, Wt = [], [], [], []
    for m in b:
        im, r, ig, ng, wt = cache[m['tile']]; k = int(rng.integers(0, 4)); fl = bool(rng.integers(0, 2))
        f = lambda a: np.ascontiguousarray(np.rot90(a[:, ::-1] if fl else a, k))
        X.append(np.clip(f(im).astype(np.float32) * float(rng.uniform(0.85, 1.15)), 0, 255)); Y.append(f(r)); Ig.append(f(ig)); Wt.append(f(wt))
    x = torch.from_numpy(np.stack(X)).to(dev); y = torch.from_numpy(np.stack(Y)).float().to(dev); ig = torch.from_numpy(np.stack(Ig)).float().to(dev); wt = torch.from_numpy(np.stack(Wt)).float().to(dev)
    s, _ = model.infer_masks_and_img_features(x); p = s[..., 1].clamp(1e-6, 1 - 1e-6); w = (1 - ig) * wt
    bce = -(y * torch.log(p) * 4.0 + (1 - y) * torch.log(1 - p)) * w; bce = bce.sum() / w.sum().clamp(min=1)
    inter = (p * y * w).sum(); dice = 1 - (2 * inter + 1) / ((p * w).sum() + (y * w).sum() + 1)
    loss = bce + dice; opt.zero_grad(); loss.backward(); opt.step()
    if step % 100 == 0 or step == 1: log.append(dict(step=step, loss=float(loss), sec=round(time.time() - t0, 1))); print(log[-1], flush=True)
torch.save(model.state_dict(), f'{RUN}/{TAG}_state.pt'); model.eval()
# ---------------- evaluation (identical to round 1: v1 val/test truth)
TOL = 14
def probs(imgs):
    out = []
    for i in range(0, len(imgs), 16):
        with torch.inference_mode():
            s, _ = model.infer_masks_and_img_features(torch.from_numpy(np.stack(imgs[i:i + 16])).float().to(dev)); out += list(s[..., 1].cpu().numpy())
    return out
def counts(p, road, ign, thr):
    pred = p > thr; ps = skeletonize(pred) if pred.any() else pred; gs = skeletonize(road) if road.any() else road
    dg = distance_transform_edt(~road) if road.any() else np.full(road.shape, 1e3); dp = distance_transform_edt(~ps) if ps.any() else np.full(road.shape, 1e3)
    vp = ps & ~ign; return (int((vp & (dg <= TOL)).sum()), int(vp.sum()), int((gs & (dp <= TOL)).sum()), int(gs.sum()))
def f1(a):
    tp_p, n_p, tp_r, n_r = a.sum(0); P = tp_p / max(n_p, 1); R = tp_r / max(n_r, 1); return float(P), float(R), float(2 * P * R / max(P + R, 1e-9))
out = dict(tag=TAG, set=SET, seed=SEED, steps=STEPS)
res = {}
for sp in ('val', 'test'):
    ms = [m for m in man1 if m['split'] == sp]; imgs = [rd(V1, sp, 'img', m['tile'])[:, :, :3] for m in ms]; pr = probs(imgs)
    gt = [(rd(V1, sp, 'road', m['tile']) > 0, rd(V1, sp, 'ignore', m['tile']) > 0) for m in ms]
    res[sp] = (ms, pr, gt)
THR = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
vms, vpr, vgt = res['val']; vf = {t: f1(np.array([counts(p, r, i, t) for p, (r, i) in zip(vpr, vgt)]))[2] for t in THR}; best = max(THR, key=lambda t: vf[t]); out['val_F1'] = vf; out['best_thr'] = best
tms, tpr, tgt = res['test']; out['test'] = {}
for name, thr in (('thr_0.5', 0.5), ('thr_val_best', best)):
    a = np.array([counts(p, r, i, thr) for p, (r, i) in zip(tpr, tgt)]); P, R, F = f1(a); grp = {}
    for key in ('region', 'terrain'):
        for v in sorted({m[key] for m in tms}):
            ix = [i for i, m in enumerate(tms) if m[key] == v]; grp[f'{key}={v}'] = dict(zip('PRF', f1(a[ix])), n=len(ix))
    out['test'][name] = dict(thr=thr, P=P, R=R, F1=F, per_tile=a.tolist(), groups=grp)
# human held-out cards: recall of human-verified lines (15 m), and share of explicit-negative line pixels covered by prediction
hh = sorted(os.listdir(f'{V2}/human_heldout/img')); H = []
imgs = [np.asarray(Image.open(f'{V2}/human_heldout/img/{n}'))[:, :, :3] for n in hh]; pr = probs(imgs)
for n, p in zip(hh, pr):
    road = np.asarray(Image.open(f'{V2}/human_heldout/road/{n}')) > 0; neg = np.asarray(Image.open(f'{V2}/human_heldout/neg/{n}')) > 0
    pred = p > 0.5; ps = skeletonize(pred) if pred.any() else pred; dp = distance_transform_edt(~ps) if ps.any() else np.full(road.shape, 1e3)
    gs = skeletonize(road) if road.any() else road
    H.append(dict(tile=n, pos_px=int(gs.sum()), pos_hit=int((gs & (dp <= TOL)).sum()), neg_px=int(neg.sum()), neg_hit=int((neg & (dp <= 5)).sum())))
out['human_heldout'] = H
json.dump(out, open(f'{RUN}/{TAG}_eval.json', 'w'), indent=1)
print(TAG, 'test thr0.5', {k: round(out['test']['thr_0.5'][k], 3) for k in 'PRF1'.replace('1', '') if k in out['test']['thr_0.5']}, 'F1', round(out['test']['thr_0.5']['F1'], 3), 'best_thr', best, flush=True)
