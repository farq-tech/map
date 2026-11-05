#!/usr/bin/env python3
"""The cinematic intro's score: ~4 s of music with a soft reverb tail, synthesised
from scratch (numpy + scipy), so it is ours and free — no samples, no borrowed music.

    python3 scripts/make-intro-score.py            # writes Resources/Intro/intro-score.m4a

Timeline (seconds), matched to Sources/Intro/IntroScene.swift:
  0.0  low D drone + a dark Dm(add9) pad swell in, a filtered-noise riser builds
  2.3  the logo's "star" lights: a soft sub boom, the pad brightens to D(add9),
       and a five-note bell/shimmer arpeggio (inharmonic partials) rings out
  4.0  everything decays into a long, dark reverb tail (faded out by ~6 s)
"""
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np
from scipy import signal

SR = 44100
DUR = 6.2
REVEAL = 2.3
t = np.arange(int(SR * DUR)) / SR
rng = np.random.default_rng(1447)  # fixed seed: the same file every run


def env_adsr(a, hold_until, release, start=0.0):
    """Smooth swell (raised cosine) from `start` over `a` s, hold, then exponential release."""
    e = np.zeros_like(t)
    x = (t - start) / max(a, 1e-4)
    rise = 0.5 - 0.5 * np.cos(np.pi * np.clip(x, 0, 1))
    e = np.where(t >= start, rise, 0.0)
    after = t > hold_until
    e[after] *= np.exp(-(t[after] - hold_until) / release)
    return e


def pad_voice(freq, bright, detune_cents=7.0, harmonics=14):
    """A warm, slowly-beating additive 'string pad' voice. `bright` (0..1 per sample) opens the tone."""
    out = np.zeros_like(t)
    for d in (-detune_cents, 0.0, detune_cents):
        f = freq * 2 ** (d / 1200)
        vib = 1 + 0.0012 * np.sin(2 * np.pi * (0.21 + rng.random() * 0.1) * t + rng.random() * 6)
        ph = 2 * np.pi * np.cumsum(f * vib) / SR + rng.random() * 6.28
        for n in range(1, harmonics + 1):
            roll = np.exp(-n / (1.4 + 6.0 * bright))
            out += (1.0 / n) * roll * np.sin(n * ph)
    return out / 3.0


def bell(freq, at, decay=1.6, amp=1.0):
    """Struck bell / celesta: inharmonic partials with their own decays."""
    out = np.zeros_like(t)
    m = t >= at
    tt = t[m] - at
    for ratio, a, dk in ((1.0, 1.0, 1.0), (2.0, 0.42, 0.55), (2.76, 0.30, 0.38), (5.40, 0.12, 0.18), (8.93, 0.05, 0.10)):
        attack = 1 - np.exp(-tt / 0.004)
        out[m] += a * attack * np.exp(-tt / (decay * dk)) * np.sin(2 * np.pi * freq * ratio * tt + ratio)
    return out * amp


def pan(x, p):
    """Equal-power pan, p in [-1, 1]."""
    a = (p + 1) * np.pi / 4
    return np.stack([x * np.cos(a), x * np.sin(a)])


def lowpass(x, hz, order=2):
    b, a = signal.butter(order, hz / (SR / 2), "low")
    return signal.lfilter(b, a, x)


def bandpass(x, lo, hi, order=2):
    b, a = signal.butter(order, [lo / (SR / 2), hi / (SR / 2)], "band")
    return signal.lfilter(b, a, x)


mix = np.zeros((2, len(t)))

# 1) Low drone: D1 + D2, gently saturated, swelling in.
drone_env = env_adsr(1.4, 3.9, 1.1)
drone = 0.55 * np.sin(2 * np.pi * 36.71 * t) + 0.35 * np.sin(2 * np.pi * 73.42 * t + 0.3) + 0.12 * np.sin(2 * np.pi * 110.0 * t)
drone = np.tanh(1.6 * drone) * drone_env
mix += pan(drone * 0.30, 0.0)

# 2) Pad: Dm(add9) swelling in, brightening into D(add9) at the reveal.
bright = np.clip((t - 0.2) / 2.1, 0, 1) ** 1.5 * 0.65 + 0.35 * (t > REVEAL) * (1 - np.exp(-(t - REVEAL).clip(0) / 0.25))
dark_env = env_adsr(1.6, REVEAL + 0.15, 0.35, start=0.05)
lift_env = env_adsr(0.25, 3.7, 1.0, start=REVEAL - 0.05)
for f, p in ((146.83, -0.5), (220.0, 0.45), (329.63, -0.2), (349.23, 0.3)):  # D3 A3 E4 F4
    mix += pan(pad_voice(f, bright) * dark_env * 0.085, p)
for f, p in ((146.83, -0.45), (220.0, 0.5), (329.63, -0.25), (369.99, 0.25), (440.0, -0.05)):  # D3 A3 E4 F#4 A4
    mix += pan(pad_voice(f, bright) * lift_env * 0.075, p)

# 3) Riser: filtered air building into the reveal.
noise = rng.standard_normal(len(t))
riser_env = np.clip((t - 0.6) / (REVEAL - 0.6), 0, 1) ** 2.2 * (t < REVEAL + 0.05)
riser_env = lowpass(riser_env, 30, 1)
air = bandpass(noise, 1800, 7000)
mix += np.stack([air, np.roll(air, 377)]) * riser_env * 0.035

# 4) The reveal: a soft sub boom (pitch falling 62 → 36 Hz) and a felt-mallet thump.
m = t >= REVEAL
tt = t[m] - REVEAL
boom = np.zeros_like(t)
fsweep = 36 + 26 * np.exp(-tt / 0.18)
boom[m] = np.sin(2 * np.pi * np.cumsum(fsweep) / SR) * np.exp(-tt / 0.9) * (1 - np.exp(-tt / 0.01))
thump = np.zeros_like(t)
thump[m] = lowpass(noise[m], 260) * np.exp(-tt / 0.12)
mix += pan(boom * 0.55 + thump * 0.25, 0.0)

# 5) Shimmer: a five-note bell arpeggio in D (A5 D6 E6 F#6 A6), spread across the stereo field.
for i, (f, p) in enumerate(((880.0, -0.55), (1174.66, 0.35), (1318.51, -0.15), (1479.98, 0.55), (1760.0, -0.35))):
    mix += pan(bell(f, REVEAL + 0.02 + i * 0.13, decay=1.8 - i * 0.15, amp=0.11 - i * 0.012), p)
# …and a few high glints after it, like stars catching the light.
for at, f, p in ((2.95, 3520.0, 0.6), (3.25, 2637.0, -0.6), (3.6, 2960.0, 0.2)):
    mix += pan(bell(f, at, decay=0.7, amp=0.025), p)

# 6) Reverb: synthetic stereo hall (decorrelated decaying noise, darker as it decays).
ir_len = int(SR * 3.2)
it = np.arange(ir_len) / SR
ir = np.zeros((2, ir_len))
for c in range(2):
    n = rng.standard_normal(ir_len) * np.exp(-it / 0.75)
    early = lowpass(n, 6500)
    late = lowpass(n, 2200)
    w = np.clip(it / 1.2, 0, 1)
    ir[c] = early * (1 - w) + late * w
    ir[c][: int(SR * 0.012)] = 0  # pre-delay
    ir[c] /= np.sqrt(np.sum(ir[c] ** 2))
wet = np.stack([signal.fftconvolve(mix[c], ir[c])[: len(t)] for c in range(2)])
out = mix * 0.78 + wet * 0.55

# 7) Master: gentle low cut, soft clip, fade in/out, normalise to -1.5 dBFS.
b, a = signal.butter(2, 28 / (SR / 2), "high")
out = signal.lfilter(b, a, out, axis=1)
out = np.tanh(out * 1.2) / 1.2
fade_in = np.clip(t / 0.03, 0, 1)
fade_out = np.clip((DUR - t) / 1.6, 0, 1) ** 2
out *= fade_in * fade_out
out *= 10 ** (-1.5 / 20) / np.max(np.abs(out))

here = os.path.dirname(os.path.abspath(__file__))
dest = os.path.join(here, "..", "Resources", "Intro", "intro-score.m4a")
if len(sys.argv) > 1:
    dest = sys.argv[1]
with tempfile.TemporaryDirectory() as d:
    wav = os.path.join(d, "intro.wav")
    pcm = (out.T * 32767).astype("<i2")
    with wave.open(wav, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    if os.environ.get("KEEP_WAV"):
        import shutil
        shutil.copy(wav, os.environ["KEEP_WAV"])
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", "-q", "127", wav, dest], check=True)
print(dest, os.path.getsize(dest), "bytes")
