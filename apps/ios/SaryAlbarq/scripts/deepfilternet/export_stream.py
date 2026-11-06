#!/usr/bin/env python3
"""Export: DFN_SRC=… DFN_MODEL=… python export_stream.py OUT.mlpackage 200 fp16
(torch 2.7.0, coremltools 9.0). Prints Core ML vs PyTorch parity and a CPU/ANE timing."""
import sys, time, numpy as np, torch, coremltools as ct
from dfn_common import load
from stream_model import Stream, P
m, st, p = load()
C = int(sys.argv[2]); prec = ct.precision.FLOAT16 if sys.argv[3] == "fp16" else ct.precision.FLOAT32
sm = Stream(m, C).eval()
ex = (torch.randn(1, 1, P + C, 32) * .3, torch.randn(1, 2, P + C, 96) * .3, torch.randn(1, 1, 256) * .1, torch.randn(2, 1, 256) * .1, torch.randn(2, 1, 256) * .1, torch.ones(1))
with torch.no_grad():
    tr = torch.jit.trace(sm, ex); ref = sm(*ex)
names = ["feat_erb", "feat_spec", "h_enc", "h_erb", "h_df", "ctx_valid"]
ml = ct.convert(tr, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
                inputs=[ct.TensorType(name=n, shape=tuple(t.shape)) for n, t in zip(names, ex)],
                outputs=[ct.TensorType(name=n) for n in ["mask", "coefs", "h_enc_out", "h_erb_out", "h_df_out"]], compute_precision=prec)
ml.author = "DeepFilterNet3 © 2021 Hendrik Schröter (github.com/Rikorose/DeepFilterNet); Core ML conversion for Sary Albarq"
ml.license = "MIT OR Apache-2.0"
ml.short_description = f"DeepFilterNet3 stateful chunk: {P} context + {C} frames (48 kHz, hop 480), GRU states in/out"
ml.version = "dfn3-120-best"
ml.save(sys.argv[1])
o = ml.predict(dict(zip(names, [t.numpy() for t in ex])))
print("diff mask", np.abs(o["mask"] - ref[0].numpy()).max(), "coefs", np.abs(o["coefs"] - ref[1].numpy()).max(), "h", np.abs(o["h_df_out"] - ref[4].numpy()).max())
for cu in [ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.ALL]:
    mm = ct.models.MLModel(sys.argv[1], compute_units=cu); d = dict(zip(names, [t.numpy() for t in ex])); mm.predict(d)
    t0 = time.time()
    for _ in range(10): mm.predict(d)
    dt = (time.time() - t0) / 10
    print(cu, f"{dt*1000:.1f} ms/chunk → 60 s ≈ {dt * 6000 / C:.2f} s")
