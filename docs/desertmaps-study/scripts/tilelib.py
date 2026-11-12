"""Mapbox satellite z17@2x tile cache + mosaic helper. Token is read from an env file, never printed."""
import math, os, time, threading, requests, io
from concurrent.futures import ThreadPoolExecutor
from PIL import Image
Z = 17
ENV = '/Users/m4pro/code/map-wt/annotation-tool/.env.local'
def _token():
    for l in open(ENV):
        if l.startswith('MAPBOX_ACCESS_TOKEN='): return l.split('=', 1)[1].strip()
    raise RuntimeError('no token')
TOKEN = _token()
CACHE = os.environ.get('DM_TILE_CACHE', '/Users/m4pro/code/map-wt/desertmaps-study-data/tiles')
os.makedirs(CACHE, exist_ok=True)
_lock = threading.Lock(); _last = [0.0]
def lonlat_to_tilef(lon, lat, z=Z):
    n = 2 ** z
    x = (lon + 180) / 360 * n
    y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return x, y
def tilef_to_lonlat(x, y, z=Z):
    n = 2 ** z
    return x / n * 360 - 180, math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
def mpp(lat, z=Z, scale=2): return 156543.03392 * math.cos(math.radians(lat)) / (2 ** z) / scale
def fetch(x, y, z=Z):
    p = f'{CACHE}/{z}_{x}_{y}.jpg'
    if os.path.exists(p) and os.path.getsize(p) > 0: return p
    with _lock:
        dt = time.time() - _last[0]
        if dt < 0.08: time.sleep(0.08 - dt)
        _last[0] = time.time()
    url = f'https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}@2x.jpg90'
    for a in range(3):
        try:
            r = requests.get(url, params={'access_token': TOKEN}, timeout=30)
            if r.status_code == 200 and len(r.content) > 500:
                open(p, 'wb').write(r.content); return p
            if r.status_code in (404, 422): open(p, 'wb').write(b''); return None
        except requests.RequestException: pass
        time.sleep(1 + a)
    return None
def fetch_many(tiles, workers=4):
    with ThreadPoolExecutor(workers) as ex: return list(ex.map(lambda t: fetch(*t), tiles))
def mosaic(x0, y0, x1, y1):
    """tiles x0..x1, y0..y1 inclusive -> PIL RGB (512px per tile), missing tiles = black (flag in mask)."""
    W, H = (x1 - x0 + 1) * 512, (y1 - y0 + 1) * 512
    im = Image.new('RGB', (W, H)); ok = Image.new('L', (W, H), 0)
    for ty in range(y0, y1 + 1):
        for tx in range(x0, x1 + 1):
            p = fetch(tx, ty)
            if p:
                t = Image.open(p).convert('RGB'); im.paste(t, ((tx - x0) * 512, (ty - y0) * 512)); ok.paste(255, ((tx - x0) * 512, (ty - y0) * 512, (tx - x0 + 1) * 512, (ty - y0 + 1) * 512))
    return im, ok
