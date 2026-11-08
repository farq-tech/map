"""Minimal numpy port of libDF (Rikorose/DeepFilterNet libDF/src/lib.rs) used only for
reference features / model export. Mirrors frame_analysis / frame_synthesis / erb_fb / norms."""
import math
import numpy as np

MEAN_NORM_INIT = (-60.0, -90.0)
UNIT_NORM_INIT = (0.001, 0.0001)

def freq2erb(f): return 9.265 * math.log1p(f / (24.7 * 9.265))
def erb2freq(n): return 24.7 * 9.265 * (math.exp(n / 9.265) - 1.0)

def erb_fb_widths(sr, fft_size, nb_bands, min_nb_freqs):
    nyq = sr // 2; fw = sr / fft_size
    lo, hi = freq2erb(0.0), freq2erb(nyq)
    step = (hi - lo) / nb_bands
    erb = [0] * nb_bands; prev = 0; over = 0
    for i in range(1, nb_bands + 1):
        f = erb2freq(lo + i * step)
        fb = int(round(f / fw))
        nb = fb - prev - over
        if nb < min_nb_freqs:
            over = min_nb_freqs - nb; nb = min_nb_freqs
        else:
            over = 0
        erb[i - 1] = nb; prev = fb
    erb[-1] += 1
    too = sum(erb) - (fft_size // 2 + 1)
    if too > 0: erb[-1] -= too
    return np.array(erb, dtype=np.int64)

def vorbis(n):
    h = n // 2
    i = np.arange(n, dtype=np.float64)
    s = np.sin(0.5 * np.pi * (i + 0.5) / h)
    return np.sin(0.5 * np.pi * s * s).astype(np.float32)

class DF:
    def __init__(self, sr=48000, fft_size=960, hop_size=480, nb_bands=32, min_nb_erb_freqs=2):
        self.sr, self.n, self.hop = sr, fft_size, hop_size
        self.erb = erb_fb_widths(sr, fft_size, nb_bands, min_nb_erb_freqs)
        self.win = vorbis(fft_size)
        self.wnorm = 1.0 / (fft_size ** 2 / (2 * hop_size))
    def erb_widths(self): return self.erb
    def fft_size(self): return self.n
    def hop_size(self): return self.hop
    def analysis(self, audio):  # [C, T] -> [C, Tf, F] complex64
        C, T = audio.shape
        nf = T // self.hop
        out = np.zeros((C, nf, self.n // 2 + 1), np.complex64)
        for c in range(C):
            mem = np.zeros(self.n - self.hop, np.float32)
            for t in range(nf):
                x = audio[c, t * self.hop:(t + 1) * self.hop].astype(np.float32)
                buf = np.concatenate([mem, x]) * self.win
                mem = np.concatenate([mem[self.hop:], x])[-(self.n - self.hop):]
                out[c, t] = np.fft.rfft(buf) * self.wnorm
        return out
    def synthesis(self, spec):  # [C, Tf, F] -> [C, T]
        C, nf, _ = spec.shape
        out = np.zeros((C, nf * self.hop), np.float32)
        for c in range(C):
            mem = np.zeros(self.n - self.hop, np.float32)
            for t in range(nf):
                # realfft inverse is unnormalised: irfft * n
                x = np.fft.irfft(spec[c, t], n=self.n).astype(np.float32) * self.n * self.win
                out[c, t * self.hop:(t + 1) * self.hop] = x[:self.hop] + mem[:self.hop]
                mem = np.concatenate([mem[self.hop:] + x[self.hop:self.n - self.hop] if self.n - 2*self.hop > 0 else np.zeros(0, np.float32), x[self.n - self.hop:]]) if self.n - 2*self.hop > 0 else x[self.hop:].copy()
        return out

def unit_norm_init(nb):
    return np.linspace(UNIT_NORM_INIT[0], UNIT_NORM_INIT[1], nb).astype(np.float32)

def erb(spec, widths, db=True):
    p = (spec.real ** 2 + spec.imag ** 2)
    out = []; b = 0
    for w in widths:
        out.append(p[..., b:b + w].mean(-1)); b += w
    e = np.stack(out, -1).astype(np.float32)
    return 10 * np.log10(e + 1e-10) if db else e

def erb_norm(x, alpha):  # [C, T, E]
    st = np.linspace(MEAN_NORM_INIT[0], MEAN_NORM_INIT[1], x.shape[-1]).astype(np.float32)
    out = np.empty_like(x)
    for c in range(x.shape[0]):
        s = st.copy()
        for t in range(x.shape[1]):
            s = x[c, t] * (1 - alpha) + s * alpha
            out[c, t] = (x[c, t] - s) / 40.0
    return out

def unit_norm(spec, alpha):
    st = unit_norm_init(spec.shape[-1])
    out = np.empty_like(spec)
    for c in range(spec.shape[0]):
        s = st.copy()
        for t in range(spec.shape[1]):
            s = np.abs(spec[c, t]) * (1 - alpha) + s * alpha
            out[c, t] = spec[c, t] / np.sqrt(s)
    return out
