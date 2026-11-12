"""Real reference track (read-only external KML; never copied into git) + tile set along it."""
import math, os, re
import numpy as np
import tiles
KML = os.environ.get("TRACK_KML", "/Users/m4pro/farq-map/research/sary-albarq-road-extraction/data/authorized-thumamah-west.kml")
Z = 17
def load_track():
    t = open(KML).read()
    m = re.search(r"<LineString><coordinates>(.*?)</coordinates>", t, re.S)
    return np.array([tuple(map(float, s.split(",")[:2]))[::-1] for s in m.group(1).split()])  # lat, lon
LAT0 = 25.2
def to_m(lat, lon):  # local equirectangular metres (fine over 50 km for 15/30 m tests)
    return np.c_[(np.asarray(lon) - 46.55) * 111320 * math.cos(math.radians(LAT0)), (np.asarray(lat) - LAT0) * 110574]
def densify(xy, step):
    seg = np.hypot(*np.diff(xy, axis=0).T); L = np.r_[0, np.cumsum(seg)]
    s = np.arange(0, L[-1], step); return np.c_[np.interp(s, L, xy[:, 0]), np.interp(s, L, xy[:, 1])], s
def tile_of(lat, lon):
    fx, fy = tiles.ll2tile(lat, lon, Z); return int(fx), int(fy)
def needed_tiles(track, buf_m=130):
    out = set(); ll = track
    # sample every 40 m, add tiles whose extent intersects the buffer around the sample
    xy = to_m(ll[:, 0], ll[:, 1]); d, _ = densify(xy, 40)
    lat = d[:, 1] / 110574 + LAT0; lon = d[:, 0] / (111320 * math.cos(math.radians(LAT0))) + 46.55
    dlat = buf_m / 110574; dlon = buf_m / (111320 * math.cos(math.radians(LAT0)))
    for la, lo in zip(lat, lon):
        x0, y0 = tile_of(la + dlat, lo - dlon); x1, y1 = tile_of(la - dlat, lo + dlon)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1): out.add((x, y))
    return sorted(out)
if __name__ == "__main__":
    import sys; from concurrent.futures import ThreadPoolExecutor
    tr = load_track(); ts = needed_tiles(tr); print("tiles", len(ts), flush=True)
    with ThreadPoolExecutor(6) as ex: list(ex.map(lambda t: tiles.fetch(Z, *t), ts))
    print("fetched new", tiles.N_FETCHED)
