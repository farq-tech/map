#!/usr/bin/env python3
"""Loudness normalisation of the «صوت سرى» clips (ElevenLabs v4 set), measure-then-gain per clip.
Usage: sary-voice-normalize.py <src_dir> <dst_dir>   (needs ffmpeg, numpy, scipy)
Same chain for every clip (HPF 70 Hz, edge trim and 80 ms pads were applied upstream and are kept):
linear gain to -16 LUFS -> 4x-oversampled true-peak lookahead limiter -> AAC 96 kbps mono 44.1 kHz (ffmpeg native aac).
Iterates on the *encoded* result until -16 +/-0.3 LUFS and TP <= -1.6 dBTP. No trimming, no EQ change."""
import sys, os, subprocess, re, json, tempfile, numpy as np
from scipy.signal import resample_poly
from concurrent.futures import ThreadPoolExecutor
SR=44100; TARGET=-16.0
def ebur(path):
    r=subprocess.run(["ffmpeg","-hide_banner","-nostats","-i",path,"-af","ebur128=peak=true:framelog=quiet","-f","null","-"],capture_output=True,text=True).stderr
    return float(re.findall(r"I:\s+(-?[\d.]+) LUFS",r)[-1]), float(re.findall(r"Peak:\s+(-?[\d.]+|-inf) dBFS",r)[-1])
def read(path):
    raw=subprocess.run(["ffmpeg","-v","error","-i",path,"-f","f32le","-ac","1","-ar",str(SR),"-"],capture_output=True,check=True).stdout
    return np.frombuffer(raw,dtype=np.float32).astype(np.float64)
def limit(x, ceil_db):
    c=10**(ceil_db/20)
    up=np.abs(resample_poly(x,4,1))
    pk=up.reshape(-1,4).max(axis=1) if len(up)%4==0 else np.pad(up,(0,(-len(up))%4)).reshape(-1,4).max(axis=1)
    pk=pk[:len(x)]
    g=np.minimum(1.0,c/np.maximum(pk,1e-9))
    la=int(0.003*SR)  # 3 ms lookahead: min over window
    from numpy.lib.stride_tricks import sliding_window_view
    gp=np.pad(g,(0,la),constant_values=1.0)
    g=sliding_window_view(gp,la+1).min(axis=1)
    # smooth: instant attack (already looked ahead), 60 ms release
    rel=np.exp(-1/(0.060*SR)); out=np.empty_like(g); s=1.0
    for i,v in enumerate(g):
        s = v if v<s else v+(s-v)*rel
        out[i]=s
    # attack smoothing over lookahead window (moving average of the min-filtered gain, never above it)
    k=np.ones(la)/la
    sm=np.convolve(np.pad(out,(la-1,0),constant_values=1.0),k,mode='valid')
    return x*np.minimum(sm,out)
def encode(x,dst):
    with tempfile.NamedTemporaryFile(suffix=".wav",delete=False) as t: tmp=t.name
    subprocess.run(["ffmpeg","-v","error","-y","-f","f32le","-ar",str(SR),"-ac","1","-i","-","-c:a","pcm_f32le",tmp],input=x.astype(np.float32).tobytes(),check=True)
    subprocess.run(["ffmpeg","-v","error","-y","-i",tmp,"-c:a","aac","-b:a","96k","-ar",str(SR),"-ac","1","-movflags","+faststart","-map_metadata","-1",dst],check=True)
    os.unlink(tmp)
def process(args):
    src,dst=args
    x=read(src); I0,T0=ebur(src)
    gain=TARGET-I0; ceil=-2.1; log=[]
    for it in range(8):
        y=limit(x*10**(gain/20),ceil)
        encode(y,dst); I,T=ebur(dst); log.append((round(gain,2),ceil,I,T))
        ok_I=abs(I-TARGET)<=0.3; ok_T=T<=-1.6
        if ok_I and ok_T: break
        if not ok_T: ceil-= (T+1.6)+0.2
        gain+= (TARGET-I)
    return dict(file=os.path.basename(src),I0=I0,T0=T0,I=I,TP=T,iters=len(log),log=log,in_len=len(x),out_len=len(read(dst)))
src_dir,dst_dir=sys.argv[1],sys.argv[2]
files=sorted(f for f in os.listdir(src_dir) if f.endswith(".m4a"))
with ThreadPoolExecutor(8) as ex: res=list(ex.map(process,[(os.path.join(src_dir,f),os.path.join(dst_dir,f)) for f in files]))
json.dump(res,sys.stdout,ensure_ascii=False)
