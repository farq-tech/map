"""Gate 0b: effective resolution via radial power spectrum (fraction of energy above 0.25 cyc/px at 2x sampling)."""
import sys, os, json, cv2, numpy as np
sys.path.insert(0, os.path.dirname(__file__)); import tiles
LAT, LON = 25.50, 47.10
def spec(img):
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32); g -= g.mean()
    g *= np.outer(np.hanning(g.shape[0]), np.hanning(g.shape[1]))
    P = np.abs(np.fft.fftshift(np.fft.fft2(g))) ** 2
    n = g.shape[0]; yy, xx = np.indices(P.shape); r = np.hypot(yy-n/2, xx-n/2) / n
    bins = np.linspace(0, 0.5, 11); tot = P.sum()
    return {f"{bins[i]:.2f}-{bins[i+1]:.2f}": float(P[(r>=bins[i])&(r<bins[i+1])].sum()/tot) for i in range(10)}
res = {}
for z in (16, 17, 18):
    m, meta = tiles.mosaic(LAT, LON, z, 2, 2)
    res[f"z{z}"] = spec(m[256:768+256, 256:768+256][:512, :512] if False else m[:1024, :1024])
print(json.dumps(res, indent=1))
