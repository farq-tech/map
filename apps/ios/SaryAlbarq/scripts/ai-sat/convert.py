# Real-ESRGAN x4plus -> Core ML (mlprogram, fp16, iOS17), image in / image out, 256 -> 1024 px.
# Rebuilds Sources/Map/AIEnhance/Model/SatelliteEnhancer.mlpackage (see docs/AI-SATELLITE.md):
#   mkdir -p $W/models && curl -L -o $W/models/RealESRGAN_x4plus.pth \
#     https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth
#   (sha256 4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1)
#   uv venv --python 3.11 $W/venv && uv pip install --python $W/venv/bin/python torch==2.5.1 coremltools==8.3 "numpy<2"
#   $W/venv/bin/python -I convert.py $W   -> $W/models/SatelliteEnhancer.mlpackage
import sys, os, time, numpy as np, torch, torch.nn as nn, coremltools as ct
sys.path.insert(0, os.path.dirname(__file__))
from arch import load
W = sys.argv[1]
class Wrap(nn.Module):
    def __init__(s, m): super().__init__(); s.m = m
    def forward(s, x): return (s.m(x).clamp(0, 1) * 255.0)
m = Wrap(load("x4plus", f"{W}/models/RealESRGAN_x4plus.pth")).eval()
ex = torch.rand(1, 3, 256, 256)
tr = torch.jit.trace(m, ex)
shapes = [1, 3, 256, 256]   # fixed 256: enumerated 128/256 shapes crash BNNS on the CPU path (macOS 27)
ml = ct.convert(tr, inputs=[ct.ImageType(name="image", shape=shapes, scale=1/255.0, color_layout=ct.colorlayout.RGB)],
                outputs=[ct.ImageType(name="enhanced", color_layout=ct.colorlayout.RGB)],
                convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                minimum_deployment_target=ct.target.iOS17)
ml.author = "Xintao Wang et al. (Real-ESRGAN, BSD-3-Clause); converted for Sary Albarq"
ml.license = "BSD-3-Clause"
ml.short_description = "Real-ESRGAN x4plus, fp16, 256 px input -> 1024 px"
p = f"{W}/models/SatelliteEnhancer.mlpackage"; ml.save(p)
sz = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(p) for f in fs) / 1e6
print(f"mlpackage {sz:.1f} MB")
