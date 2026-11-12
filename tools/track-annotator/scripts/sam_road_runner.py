#!/usr/bin/env python3
"""Run the SpaceNet-trained SAM-Road checkpoint on one RGB array (executed in the research .venv-sam, py3.9).

    PYTORCH_ENABLE_MPS_FALLBACK=1 <root>/.venv-sam/bin/python sam_road_runner.py \
        --root <research dir> --image in.npy --out out.npz [--device mps|cpu]

Local inference only (MPS/CPU). Writes nodes_rc (N,2), edges (E,2), road_mask uint8 (H,W), keypoint_mask.
The image must be square (the caller pads). Out-of-domain for desert tracks: expect weak suggestions.
"""
import argparse
import hashlib
import math
import sys
import time
from pathlib import Path

import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("--root", required=True)
ap.add_argument("--image", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--device", default="mps")
a = ap.parse_args()

ROOT = Path(a.root)
REPO = ROOT / "vendor/sam_road"
WEIGHT = ROOT / "data/spacenet_vitb_256_e10.ckpt"
CONFIG = REPO / "config/toponet_vitb_256_spacenet.yaml"
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "sam"))
sys.argv = [str(REPO / "inferencer.py"), "--config", str(CONFIG), "--checkpoint", str(WEIGHT), "--device", a.device]
import torch  # noqa: E402
import inferencer as official  # noqa: E402
from model import SAMRoad  # noqa: E402
from utils import load_config  # noqa: E402

if a.device == "mps" and not torch.backends.mps.is_available():
    a.device = "cpu"
    official.args.device = "cpu"
img = np.load(a.image)
assert img.ndim == 3 and img.shape[0] == img.shape[1], "square RGB array required"
config = load_config(str(CONFIG))
config.SAM_CKPT_PATH = str(REPO / config.SAM_CKPT_PATH)
config.INFER_BATCH_SIZE = 1
# sliding-window density: ~1 patch per 128 px (the training config uses 16 per edge for 400 px tiles)
config.INFER_PATCHES_PER_EDGE = max(2, math.ceil(img.shape[0] / 128))
t0 = time.perf_counter()
model = SAMRoad(config)
ck = torch.load(WEIGHT, map_location="cpu", weights_only=False)
model.load_state_dict(ck["state_dict"], strict=True)
model.eval().to(torch.device(a.device))
with torch.inference_mode():
    nodes, edges, kp, road = official.infer_one_img(model, img, config)
np.savez_compressed(a.out, nodes_rc=np.asarray(nodes), edges=np.asarray(edges, dtype=np.int32).reshape(-1, 2),
                    road_mask=road, keypoint_mask=kp,
                    meta=np.array([hashlib.sha256(WEIGHT.read_bytes()).hexdigest(), a.device, f"{time.perf_counter() - t0:.2f}"]))
print("ok", len(nodes), len(edges))
