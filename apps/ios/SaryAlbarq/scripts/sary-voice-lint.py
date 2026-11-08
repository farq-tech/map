#!/usr/bin/env python3
"""Asset linter for Resources/SaryVoice (needs ffmpeg, numpy).
Checks every manifest key: file exists, decodes, 44.1 kHz mono, > 0.1 s, no duplicate key/file/audio,
integrated loudness -16 +/-0.5 LUFS, true peak <= -1.5 dBTP (ffmpeg ebur128, 4x oversampled),
and silence <= -60 dBFS in the outer 60 ms of the 80 ms pads. Exit 1 on any failure."""
import sys, os, re, json, hashlib, subprocess, numpy as np
from concurrent.futures import ThreadPoolExecutor
d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "Resources", "SaryVoice")
m = json.load(open(os.path.join(d, "manifest.json")))
fails = []
keys = [e["key"] for e in m]; files = [e["file"] for e in m]
if len(set(keys)) != len(keys): fails.append("duplicate keys")
if len(set(files)) != len(files): fails.append("duplicate files")
def check(e):
    p = os.path.join(d, e["file"]); out = {"key": e["key"]}
    if not os.path.exists(p): return {**out, "err": "missing file"}
    pr = subprocess.run(["ffprobe","-v","error","-select_streams","a:0","-show_entries","stream=sample_rate,channels","-of","json",p],capture_output=True,text=True)
    s = json.loads(pr.stdout or "{}").get("streams", [{}])[0]
    r = subprocess.run(["ffmpeg","-hide_banner","-nostats","-i",p,"-af","ebur128=peak=true:framelog=quiet","-f","null","-"],capture_output=True,text=True).stderr
    raw = subprocess.run(["ffmpeg","-v","error","-i",p,"-f","f32le","-ac","1","-"],capture_output=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).astype(float)
    db = lambda a: 20*np.log10(np.sqrt((a**2).mean())+1e-12)
    try:
        I = float(re.findall(r"I:\s+(-?[\d.]+) LUFS", r)[-1]); TP = float(re.findall(r"Peak:\s+(-?[\d.]+|-inf) dBFS", r)[-1])
    except IndexError: return {**out, "err": "does not decode"}
    n = int(0.06*44100)
    return {**out, "sr": int(s.get("sample_rate", 0)), "ch": s.get("channels"), "dur": len(x)/44100, "I": I, "TP": TP,
            "pad": max(db(x[:n]), db(x[-n:])), "md5": hashlib.md5(open(p,"rb").read()).hexdigest()}
with ThreadPoolExecutor(8) as ex: res = list(ex.map(check, m))
for r in res:
    k = r["key"]
    if "err" in r: fails.append(f"{k}: {r['err']}"); continue
    if r["sr"] != 44100 or r["ch"] != 1: fails.append(f"{k}: {r['sr']} Hz {r['ch']} ch")
    if r["dur"] <= 0.1: fails.append(f"{k}: {r['dur']:.3f} s")
    if abs(r["I"] + 16) > 0.5: fails.append(f"{k}: {r['I']} LUFS")
    if r["TP"] > -1.5: fails.append(f"{k}: TP {r['TP']} dBTP")
    if r["pad"] > -60: fails.append(f"{k}: pad {r['pad']:.1f} dBFS")
md5s = [r.get("md5") for r in res if "md5" in r]
if len(set(md5s)) != len(md5s): fails.append("duplicate audio")
ok = [r for r in res if "I" in r]
print(f"{len(m)} clips  LUFS {min(r['I'] for r in ok)}..{max(r['I'] for r in ok)}  TP {min(r['TP'] for r in ok)}..{max(r['TP'] for r in ok)} dBTP  "
      f"dur {min(r['dur'] for r in ok):.2f}..{max(r['dur'] for r in ok):.2f} s  pad <= {max(r['pad'] for r in ok):.1f} dBFS")
for f in fails: print("FAIL", f)
sys.exit(1 if fails else 0)
