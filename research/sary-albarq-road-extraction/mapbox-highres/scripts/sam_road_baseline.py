"""SAM-Road (official SpaceNet-3 checkpoint, NO fine-tuning) on Mapbox z17@2x windows along the real track.
Runs with the vendored official code in the other (read-only) research checkout. Window = 1024 px (553 m) centred on the track, resized to ~1 m/px
(the checkpoint's training GSD). Missing tiles (outside the 130 m corridor) are filled with the window mean and excluded from scoring."""
import os
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"   # must precede torch import
import sys, json, math, time
import numpy as np, cv2, torch
from common import *
RO = "/Users/m4pro/farq-map/research/sary-albarq-road-extraction"          # read-only
REPO = os.path.join(RO, "vendor/sam_road"); WEIGHT = os.path.join(RO, "data/spacenet_vitb_256_e10.ckpt")
CFG = os.path.join(REPO, "config/toponet_vitb_256_spacenet.yaml")
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
sys.path.insert(0, REPO); sys.path.insert(0, os.path.join(REPO, "sam"))
sys.argv = [os.path.join(REPO, "inferencer.py"), "--config", CFG, "--checkpoint", WEIGHT, "--device", "mps"]
cwd = os.getcwd(); os.chdir(REPO)                       # config uses repo-relative SAM ckpt path; nothing is written here
import inferencer as inf
from model import SAMRoad
from utils import load_config
cfg = load_config(CFG); cfg.SAM_CKPT_PATH = os.path.join(REPO, cfg.SAM_CKPT_PATH); cfg.INFER_BATCH_SIZE = 1
model = SAMRoad(cfg); ck = torch.load(WEIGHT, map_location="cpu", weights_only=False); model.load_state_dict(ck["state_dict"], strict=True)
model.eval().to(torch.device("mps")); os.chdir(cwd)
Z = np.load(os.path.join(AUX, "samples.npz")); d = Z["d"]; s = Z["s"]
NW = int(os.environ.get("NWIN", 24)); idx = np.linspace(40, len(d) - 40, NW).astype(int)
edges_all = []; wins = []
for k, i in enumerate(idx):
    lat, lon = m2ll(d[i:i+1]); lat, lon = float(lat[0]), float(lon[0]); gx, gy = gpx(lat, lon)
    x0, y0 = int(gx - 512), int(gy - 512); W = np.full((1024, 1024, 3), np.nan, np.float32); valid = np.zeros((1024, 1024), bool)
    for tx in range(x0 // 512, (x0 + 1023) // 512 + 1):
        for ty in range(y0 // 512, (y0 + 1023) // 512 + 1):
            p = os.path.join(tiles.TILE_DIR, f"17_{tx}_{ty}@2x.jpg")
            if not os.path.exists(p): continue
            im = cv2.imread(p)[:, :, ::-1].astype(np.float32)
            a0, b0 = max(tx * 512, x0), max(ty * 512, y0); a1, b1 = min(tx * 512 + 512, x0 + 1024), min(ty * 512 + 512, y0 + 1024)
            W[b0 - y0:b1 - y0, a0 - x0:a1 - x0] = im[b0 - ty * 512:b1 - ty * 512, a0 - tx * 512:a1 - tx * 512]; valid[b0 - y0:b1 - y0, a0 - x0:a1 - x0] = True
    W[~valid] = np.nanmean(W); mpp = MPP_LAT(lat); sc = mpp / 1.0                      # -> 1 m/px
    n = int(round(1024 * sc)); img = cv2.resize(W, (n, n), interpolation=cv2.INTER_AREA).clip(0, 255).astype(np.uint8)
    t0 = time.time()
    with torch.inference_mode(): nodes, edges, _, _ = inf.infer_one_img(model, img, cfg)
    torch.mps.synchronize(); print(k, "edges", len(edges), round(time.time() - t0, 1), "s", flush=True)
    nodes = np.asarray(nodes, float); E = np.asarray(edges, int).reshape(-1, 2)
    for a, b in E:
        pr = []
        for q in (a, b):
            r, c = nodes[q]; px = x0 + c / sc; py = y0 + r / sc
            la = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * py / 512 / 2 ** 17)))); lo = px / 512 / 2 ** 17 * 360 - 180
            ok = valid[int(min(max(r / sc, 0), 1023)), int(min(max(c / sc, 0), 1023))]
            pr.append((T.to_m(la, lo)[0], ok))
        if pr[0][1] and pr[1][1]: edges_all.append(np.r_[pr[0][0], pr[1][0]])
    wins.append(dict(i=int(i), center_m=d[i].tolist()))
np.savez(os.path.join(AUX, "sam.npz"), edges=np.array(edges_all), idx=idx)
json.dump(dict(windows=NW, edges=len(edges_all)), open(os.path.join(AUX, "sam_meta.json"), "w")); print("edges kept", len(edges_all))
