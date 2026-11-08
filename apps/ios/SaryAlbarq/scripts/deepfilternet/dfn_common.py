"""Shared loader for the DeepFilterNet3 export (build-time only; nothing here ships in the app).

Inputs, from the official repo only (github.com/Rikorose/DeepFilterNet, commit 7b14b895fe):
  DFN_SRC   = the repo source tree (archive/7b14b895fe.tar.gz, sha256 60ddfcd8a4b62b78e95c59707a9c9bd6df74f09d72db41abad8987c67f2a680a)
  DFN_MODEL = models/DeepFilterNet3.zip unpacked (sha256 49c52edc8947ae1f9bf50d81530beaf3a2c3245aeaf34b6f31ff535cd22284d2,
              git blob ea53bac00d064378451d0201d573f44f05f1d746) → DeepFilterNet3/{config.ini, checkpoints/model_120.ckpt.best}
Licence: MIT OR Apache-2.0 (code and model weights), © 2021 Hendrik Schröter.
"""
import math, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # the numpy libdf port next to this file
sys.path.insert(1, os.path.join(os.environ["DFN_SRC"], "DeepFilterNet"))
import numpy as np, torch
from df.config import config
MODEL_DIR = os.environ["DFN_MODEL"]
config.load(os.path.join(MODEL_DIR, "config.ini"), config_must_exist=True, allow_defaults=True, allow_reload=True)
from df.model import ModelParams
from df.deepfilternet3 import init_model
import libdf

def load():
    p = ModelParams()
    st = libdf.DF(sr=p.sr, fft_size=p.fft_size, hop_size=p.hop_size, nb_bands=p.nb_erb, min_nb_erb_freqs=p.min_nb_freqs)
    m = init_model(st)
    ck = torch.load(os.path.join(MODEL_DIR, "checkpoints", "model_120.ckpt.best"), map_location="cpu", weights_only=False)
    m.load_state_dict(ck["model"] if isinstance(ck, dict) and "model" in ck else ck, strict=True)
    return m.eval(), st, p

def alpha(p):
    a_ = math.exp(-(p.hop_size / p.sr) / p.norm_tau); prec = 3; a = 1.0
    while a >= 1.0:
        a = round(a_, prec); prec += 1
    return a

def features(audio48, st, p):
    spec = st.analysis(audio48[None]); a = alpha(p)
    e = libdf.erb_norm(libdf.erb(spec, st.erb_widths()), a)
    c = libdf.unit_norm(spec[..., :p.nb_df], a)
    return spec[0], e[0], c[0]
