"""Mapbox satellite tile fetch (research only). Token read from Secrets.xcconfig at runtime, never printed.
Tiles are cached OUTSIDE git (MBX_TILE_DIR, default /tmp/mbx-highres-tiles)."""
import math, os, re, time
import cv2, numpy as np, requests

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))
SECRETS = os.path.join(ROOT, "apps/ios/SaryAlbarq/Config/Secrets.xcconfig")
TILE_DIR = os.environ.get("MBX_TILE_DIR", "/private/tmp/mbx-highres-tiles")
os.makedirs(TILE_DIR, exist_ok=True)
_tok = None; _s = requests.Session(); N_FETCHED = 0

def token():
    global _tok
    if _tok is None:
        _tok = re.search(r"^MAPBOX_ACCESS_TOKEN\s*=\s*(pk\.\S+)", open(SECRETS).read(), re.M).group(1)
    return _tok

def ll2tile(lat, lon, z):
    n = 2 ** z
    return (lon + 180) / 360 * n, (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n

def tile2ll(x, y, z):
    n = 2 ** z
    return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n)))), x / n * 360 - 180

def fetch(z, x, y):
    global N_FETCHED
    p = os.path.join(TILE_DIR, f"{z}_{x}_{y}@2x.jpg")
    if not os.path.exists(p):
        r = _s.get(f"https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}@2x.jpg90",
                   params={"access_token": token()}, timeout=30)
        if r.status_code != 200:
            raise RuntimeError(f"tile {z}/{x}/{y} HTTP {r.status_code}")  # URL (with token) never included
        open(p, "wb").write(r.content); N_FETCHED += 1; time.sleep(0.05)
    return cv2.imread(p)

def mosaic(lat, lon, z, nx, ny):
    fx, fy = ll2tile(lat, lon, z)
    x0, y0 = int(round(fx - nx / 2)), int(round(fy - ny / 2))
    img = np.zeros((ny * 512, nx * 512, 3), np.uint8)
    for j in range(ny):
        for i in range(nx):
            img[j*512:(j+1)*512, i*512:(i+1)*512] = fetch(z, x0 + i, y0 + j)
    lat_n, lon_w = tile2ll(x0, y0, z); lat_s, lon_e = tile2ll(x0 + nx, y0 + ny, z)
    mpp = 156543.03392 * math.cos(math.radians((lat_n + lat_s) / 2)) / 2 ** z / 2
    return img, dict(z=z, x0=x0, y0=y0, nx=nx, ny=ny, mpp=mpp, bbox=(lat_s, lon_w, lat_n, lon_e))
