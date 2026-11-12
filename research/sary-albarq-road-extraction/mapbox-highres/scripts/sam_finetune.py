"""Experiment 2: spatial-holdout fine-tune of SAM-Road (road-mask head only; image encoder + naive map decoder) on Mapbox z17@2x resized to ~1 m/px.
usage: python3 sam_finetune.py <fold:north|middle|south> <steps> [zeroshot]
Train labels = GPS track in training sectors only (500 m guard around the test sector). Eval on the held-out sector with fixed threshold 0.5."""
import os
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
import sys, json, math, time, functools
import numpy as np, cv2, torch
from common import *
from scipy.spatial import cKDTree
from skimage.morphology import skeletonize, remove_small_objects
from skimage.measure import label
RO = "/Users/m4pro/farq-map/research/sary-albarq-road-extraction"; REPO = os.path.join(RO, "vendor/sam_road")
WEIGHT = os.path.join(RO, "data/spacenet_vitb_256_e10.ckpt"); CFG = os.path.join(REPO, "config/toponet_vitb_256_spacenet.yaml")
sys.path.insert(0, REPO); sys.path.insert(0, os.path.join(REPO, "sam"))
fold = sys.argv[1]; steps = int(sys.argv[2]); zeroshot = len(sys.argv) > 3 and sys.argv[3] == "zeroshot"
OUT = os.path.join(os.path.dirname(__file__), "..", "out")
dev = torch.device("mps")
cwd = os.getcwd(); os.chdir(REPO)
from model import SAMRoad
from utils import load_config
cfg = load_config(CFG); cfg.SAM_CKPT_PATH = os.path.join(REPO, cfg.SAM_CKPT_PATH)
net = SAMRoad(cfg); ck = torch.load(WEIGHT, map_location="cpu", weights_only=False); net.load_state_dict(ck["state_dict"], strict=True); os.chdir(cwd)
net.to(dev)
Z = np.load(os.path.join(AUX, "samples.npz")); d, tang, cls = Z["d"], Z["tang"], Z["cls"]; nrm = np.c_[-tang[:, 1], tang[:, 0]]
yk = d[:, 1] / 1000; zone = {"north": yk > 8, "middle": (yk >= -3) & (yk <= 8), "south": yk < -3}[fold]
dirt = np.isin(cls, ["dirt_default", "dirt_osm_track"])
idx = np.arange(len(d)); near_test = np.zeros(len(d), bool)
for i in np.nonzero(zone)[0][::1]: near_test[max(0, i - 50):i + 51] = True        # 500 m guard
train_ok = ~near_test
# ---------------- colour tile access
@functools.lru_cache(maxsize=64)
def tile_rgb(x, y):
    p = os.path.join(tiles.TILE_DIR, f"17_{x}_{y}@2x.jpg")
    if not os.path.exists(p): return None
    return cv2.imread(p)[:, :, ::-1].copy()
@functools.lru_cache(maxsize=16)
def block_rgb(tx, ty):
    B = np.zeros((1536, 1536, 3), np.uint8); V = np.zeros((1536, 1536), np.uint8)
    for j in range(3):
        for i in range(3):
            t = tile_rgb(tx - 1 + i, ty - 1 + j)
            if t is not None: B[j*512:(j+1)*512, i*512:(i+1)*512] = t; V[j*512:(j+1)*512, i*512:(i+1)*512] = 1
    return B, V
def center_tile(lat, lon):
    fx, fy = tiles.ll2tile(lat, lon, 17); return int(fx), int(fy)
def make_patch(c_m, theta, S=256):
    """256x256 patch at 1 m/px centred at c_m (local metres), rotated by theta. returns rgb(S,S,3 float32), valid, maps (u,v)->metres for labelling"""
    lat, lon = m2ll(c_m[None]); lat, lon = float(lat[0]), float(lon[0]); tx, ty = center_tile(lat, lon); B, V = block_rgb(tx, ty)
    gx, gy = gpx(lat, lon); ox, oy = (tx - 1) * 512, (ty - 1) * 512; mpp = MPP_LAT(lat)
    u, v = np.meshgrid(np.arange(S) - S / 2 + .5, np.arange(S) - S / 2 + .5); c, s = math.cos(theta), math.sin(theta)
    xe = c * u - s * v; yn = s * u + c * v                                  # east / north offsets in metres
    mx = ((gx - ox) + xe / mpp).astype(np.float32); my = ((gy - oy) - yn / mpp).astype(np.float32)
    rgb = cv2.remap(B, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    val = cv2.remap(V, mx, my, cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT, borderValue=0)
    return rgb.astype(np.float32), val.astype(np.float32), (c, s)
def label_patch(c_m, cs, pts_m, S=256, w=5):
    c, s = cs; lab = np.zeros((S, S), np.uint8)
    rel = pts_m - c_m; u = c * rel[:, 0] + s * rel[:, 1] + S / 2 - .5; v = -s * rel[:, 0] + c * rel[:, 1] + S / 2 - .5      # inverse rotation
    P = np.c_[u, v]; ok = (np.abs(P[:, 0] - S / 2) < S) & (np.abs(P[:, 1] - S / 2) < S)
    for a, b, o1, o2 in zip(P[:-1], P[1:], ok[:-1], ok[1:]):
        if o1 or o2: cv2.line(lab, tuple(np.round(a).astype(int)), tuple(np.round(b).astype(int)), 1, w)
    return lab.astype(np.float32)
def batch(n, rng, tr_idx):
    X, Y, M = [], [], []
    while len(X) < n:
        i = rng.choice(tr_idx); c_m = d[i] + nrm[i] * rng.uniform(-60, 60); th = rng.uniform(0, 2 * math.pi)
        if rng.random() < .5: th += math.pi
        rgb, val, cs = make_patch(c_m, th)
        if val.mean() < .5: continue
        j0, j1 = max(0, i - 40), min(len(d), i + 41); keep = train_ok[j0:j1]
        lab = label_patch(c_m, cs, d[j0:j1][keep]) if keep.sum() > 1 else np.zeros((256, 256), np.float32)
        X.append(rgb); Y.append(lab); M.append(val)
    return [torch.from_numpy(np.stack(a)).to(dev) for a in (X, Y, M)]
def road_logits(x):
    xx = x.permute(0, 3, 1, 2); xx = (xx - net.pixel_mean) / net.pixel_std
    return net.map_decoder(net.image_encoder(xx))[:, 1]                    # channel 1 = road
if not zeroshot:
    net.train(); tr_idx = np.nonzero(train_ok & dirt)[0]; rng = np.random.default_rng(0)
    enc = [p for n_, p in net.named_parameters() if n_.startswith("image_encoder")]; dec = [p for n_, p in net.named_parameters() if n_.startswith("map_decoder")]
    for p in net.parameters(): p.requires_grad = False
    for p in enc + dec: p.requires_grad = True
    opt = torch.optim.AdamW([{"params": enc, "lr": 1e-5}, {"params": dec, "lr": 1e-4}], weight_decay=1e-4)
    t0 = time.time(); posw = torch.tensor(4.0, device=dev)
    for it in range(steps):
        X, Y, M = batch(4, rng, tr_idx)
        # light photometric augmentation
        X = (X * torch.empty(4, 1, 1, 1, device=dev).uniform_(.85, 1.15) + torch.empty(4, 1, 1, 1, device=dev).uniform_(-15, 15)).clamp(0, 255)
        lg = road_logits(X); loss = (torch.nn.functional.binary_cross_entropy_with_logits(lg, Y, pos_weight=posw, reduction="none") * M).sum() / M.sum()
        opt.zero_grad(); loss.backward(); opt.step()
        if it % 25 == 0: print(f"{fold} it {it}/{steps} loss {loss.item():.4f} {time.time()-t0:.0f}s", flush=True)
    net.eval()
else: net.eval()
# ---------------- held-out evaluation
tiles_all = T.needed_tiles(T.load_track()); test_tiles = []
for tx, ty in tiles_all:
    la, lo = tiles.tile2ll(tx + .5, ty + .5, 17); ym = T.to_m(la, lo)[0][1] / 1000
    if {"north": ym > 8, "middle": -3 <= ym <= 8, "south": ym < -3}[fold]: test_tiles.append((tx, ty))
print("test tiles", len(test_tiles), flush=True); PTS = []; PTSP = []
S = 256; scale = 0.54
with torch.inference_mode():
    for n, (tx, ty) in enumerate(test_tiles):
        B, V = block_rgb(tx, ty)
        # region = centre tile +- 64 px*... take 3x3 block resized to ~1 m/px, run 256 windows (stride 128), keep centre tile area
        mpp = MPP_LAT(tiles.tile2ll(tx + .5, ty + .5, 17)[0]); f = mpp / 1.0
        img = cv2.resize(B, None, fx=f, fy=f, interpolation=cv2.INTER_AREA).astype(np.float32); H = img.shape[0]
        Wm = cv2.resize(V.astype(np.float32), None, fx=f, fy=f, interpolation=cv2.INTER_NEAREST)
        img[Wm < .5] = img[Wm > .5].mean(0) if (Wm > .5).any() else 0
        prob = np.zeros((H, H), np.float32); cnt = np.zeros((H, H), np.float32); st = list(range(0, H - S + 1, 128)); st = st + ([H - S] if st[-1] != H - S else [])
        wins = [(y0, x0) for y0 in st for x0 in st]
        for k in range(0, len(wins), 9):
            ch = wins[k:k + 9]; X = torch.from_numpy(np.stack([img[y0:y0+S, x0:x0+S] for y0, x0 in ch])).to(dev)
            p = torch.sigmoid(road_logits(X)).cpu().numpy()
            for (y0, x0), pp in zip(ch, p): prob[y0:y0+S, x0:x0+S] += pp; cnt[y0:y0+S, x0:x0+S] += 1
        prob /= np.maximum(cnt, 1); c0 = int(512 * f); c1 = int(1024 * f); cen = prob[c0:c1, c0:c1]
        m = remove_small_objects(cen > 0.5, 30); sk = skeletonize(m); lab = label(sk, connectivity=2); cc = np.bincount(lab.ravel()); keep = cc >= 60; keep[0] = False
        ii, jj = np.nonzero(keep[lab])
        if len(ii):
            gx = tx * 512 + (jj + c0) / f + .5 * 0; gy = ty * 512 + (ii + c0) / f
            nn = 2 ** 17; lon = (tx * 512 - 0 + (jj + .5) / f) / 512 / nn * 360 - 180 if False else None
            gxx = (tx * 512 + jj / f) ; gyy = (ty * 512 + ii / f)                            # centre tile starts at 512 px of the block -> tile origin
            lonv = gxx / 512 / nn * 360 - 180; latv = np.degrees(np.arctan(np.sinh(np.pi * (1 - 2 * gyy / 512 / nn)))); PTS.append(T.to_m(latv, lonv))
        if n % 20 == 0: print("eval tile", n, "/", len(test_tiles), flush=True)
pts = np.vstack(PTS) if PTS else np.zeros((0, 2))
# ---------------- metrics (same as other detectors: asphalt mask 75 m, dirt-only, 1000 lateral-offset controls)
def dens(l, st=10):
    c = np.r_[0, np.cumsum(np.hypot(*np.diff(l, axis=0).T))]; q = np.arange(0, c[-1], st); return np.c_[np.interp(q, c, l[:, 0]), np.interp(q, c, l[:, 1])]
PAV = cKDTree(np.vstack([dens(l[1]) for l in osm_lines() if l[0] in ("paved", "ambig")])); n_all = len(pts)
pts = pts[PAV.query(pts)[0] > 75] if n_all else pts
osm_dirt = [dens(l[1], 5) for l in osm_lines() if l[0] == "dirt"]; ref = np.vstack([d] + osm_dirt)
dz = dirt & zone; R = dict(fold=fold, zeroshot=zeroshot, steps=0 if zeroshot else steps, test_tiles=len(test_tiles), dirt_km_in_zone=float(dz.sum() * .01), skeleton_km=float(len(pts) * 1.0 / 1000 / 1.0) if False else None)
if len(pts) > 0:
    tree = cKDTree(pts); d0 = tree.query(d)[0]; blk = np.arange(len(d)) // 50; rng = np.random.default_rng(5); ctl = {15: [], 30: []}
    for tol in (15, 30): R[f"coverage_{tol}m"] = float((d0[dz] <= tol).mean()); R[f"covered_km_{tol}m"] = float((d0[dz] <= tol).sum() * .01)
    for _ in range(1000):
        ob = rng.uniform(60, 75, blk.max() + 1) * rng.choice([-1, 1], blk.max() + 1); dc = tree.query(d + nrm * ob[blk][:, None])[0]
        for tol in ctl: ctl[tol].append((dc[dz] <= tol).mean())
    for tol in ctl:
        a = np.array(ctl[tol]); R[f"control_{tol}m_p50"] = float(np.median(a)); R[f"control_{tol}m_p95"] = float(np.percentile(a, 95)); R[f"frac_controls_ge_{tol}m"] = float((a >= R[f"coverage_{tol}m"]).mean())
    R["precision_30m_gps_plus_osm_tracks"] = float((cKDTree(ref).query(pts)[0] <= 30).mean())
    pc = []
    for _ in range(100):
        ob = rng.uniform(60, 75, blk.max() + 1) * rng.choice([-1, 1], blk.max() + 1); pc.append((cKDTree(np.vstack([d + nrm * ob[blk][:, None]] + osm_dirt)).query(pts)[0] <= 30).mean())
    R["precision_30m_control_p50"] = float(np.median(pc)); R["skeleton_px"] = int(len(pts))
    R["pass_gates"] = bool(R["coverage_30m"] >= .5 and R["precision_30m_gps_plus_osm_tracks"] >= .5 and R["coverage_30m"] > R["control_30m_p95"])
tag = f"{fold}_{'zeroshot' if zeroshot else 'ft'}"; json.dump(R, open(os.path.join(OUT, f"exp2_{tag}.json"), "w"), indent=1); print(json.dumps(R, indent=1))
np.save(os.path.join(AUX, f"exp2_pts_{tag}.npy"), pts)
if not zeroshot: torch.save({k: v for k, v in net.state_dict().items() if k.startswith(("image_encoder", "map_decoder"))}, os.path.join(AUX, f"exp2_{fold}.pt"))
