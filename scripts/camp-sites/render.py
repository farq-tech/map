"""Static PNG of the candidates over open data only: Sentinel-2 true colour (Copernicus) with a
Copernicus DEM hillshade, OSM tracks, and the hard exclusions. No Mapbox / Google / Esri.

Usage: python -I render.py <region> <cache_dir> <geojson_dir> <png_out> [wind_from_deg gust_kmh] [top]
"""
import json
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib import font_manager  # noqa: E402
from shapely import wkt as swkt  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model as M  # noqa: E402
from regions import ANALYSIS_ARCSEC, REGIONS  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = os.path.join(HERE, "..", "..", "apps", "ios", "SaryAlbarq", "Resources", "Fonts", "Tajawal-Bold.ttf")
FONT_R = os.path.join(HERE, "..", "..", "apps", "ios", "SaryAlbarq", "Resources", "Fonts", "Tajawal-Regular.ttf")


def ar(s):
    """Matplotlib >= 3.11 shapes and orders Arabic itself (libraqm)."""
    return s


def wind_reason(sh, wind_from):
    i = int(round((wind_from % 360) / 45)) % 8
    if M.shelter_for(sh, wind_from) >= 0.5:
        return f"في ظل من ريح {M.DIR_AR[M.DIRS[i]]}"
    return None


def live_rank(feats, wind_from, gust):
    out = []
    for f in feats:
        p = f["properties"]
        s = M.total_score(p, p["shelter"], wind_from, gust)
        out.append((s, f))
    out.sort(key=lambda t: -t[0])
    return out


def hillshade(dem, dx, dy, az=315, alt=45):
    gy, gx = np.gradient(dem, dy, dx)
    slope = np.arctan(np.hypot(gx, gy) * 2)
    aspect = np.arctan2(-gx, gy)
    a, b = np.radians(az), np.radians(alt)
    return np.clip(np.sin(b) * np.cos(slope) + np.cos(b) * np.sin(slope) * np.cos(a - aspect), 0, 1)


def main(region, cache, gj_dir, png, wind_from=0.0, gust=25.0, top=8):
    R = np.load(os.path.join(cache, region, f"rasters_{ANALYSIS_ARCSEC}.npz"))
    Ly = np.load(os.path.join(cache, region, "layers.npz"))
    osm = json.load(open(os.path.join(cache, region, "osm.json")))
    fc = json.load(open(os.path.join(gj_dir, f"camp-sites-{region}.geojson")))
    s, w, n, e = REGIONS[region]["bbox"]
    dx, dy = M.cell_size_m((s + n) / 2, ANALYSIS_ARCSEC)
    rgb = np.dstack([R["s2_red"], R["s2_green"], R["s2_blue"]]).astype("float64")
    rgb = np.nan_to_num(rgb, nan=0.2)
    rgb = np.clip(rgb * 2.4, 0, 1) ** 0.9  # plain true colour (reflectance x2.4), no false stretch
    hs = hillshade(Ly["dem"].astype("float64"), dx, dy)
    img = np.clip(rgb * (0.55 + 0.6 * hs[..., None]), 0, 1)

    font_manager.fontManager.addfont(FONT)
    font_manager.fontManager.addfont(FONT_R)
    fp = font_manager.FontProperties(fname=FONT)
    fr = font_manager.FontProperties(fname=FONT_R)
    fig = plt.figure(figsize=(16, 10), dpi=110)
    axm = fig.add_axes([0.01, 0.04, 0.60, 0.92])
    axm.imshow(img, extent=(w, e, s, n), interpolation="bilinear")
    over = np.zeros(Ly["dem"].shape + (4,))
    over[Ly["channel_excl"]] = (0.15, 0.45, 1.0, 0.35)
    over[Ly["channel"]] = (0.1, 0.3, 1.0, 0.75)
    over[Ly["sink"]] = (0.0, 0.8, 0.9, 0.30)
    over[Ly["sabkha"]] = (1, 1, 1, 0.7)
    code = Ly["excl_code"]
    names = list(Ly["excl_names"])
    over[(code == names.index("built") + 1)] = (0.3, 0.3, 0.3, 0.30)
    over[(code == names.index("military") + 1)] = (0.6, 0.0, 0.0, 0.35)
    over[(code == names.index("steep") + 1)] = (0.5, 0.2, 0.0, 0.30)
    axm.imshow(over, extent=(w, e, s, n), interpolation="nearest")
    for t in osm["tracks"]:
        g = swkt.loads(t["wkt"])
        for ln in getattr(g, "geoms", [g]):
            x, y = ln.xy
            axm.plot(x, y, color="#f7d79a", lw=0.8, ls=(0, (3, 2)), alpha=0.9)
    for t in osm["roads"]:
        g = swkt.loads(t["wkt"])
        for ln in getattr(g, "geoms", [g]):
            x, y = ln.xy
            axm.plot(x, y, color="#ffffff", lw=0.6, alpha=0.6)
    ranked = live_rank(fc["features"], wind_from, gust)
    for f in fc["features"]:
        x, y = f["geometry"]["coordinates"]
        axm.plot(x, y, "o", ms=4, color="#ff9f43", mec="k", mew=0.4, alpha=0.8)
    for i, (sc, f) in enumerate(ranked[:top], start=1):
        x, y = f["geometry"]["coordinates"]
        axm.plot(x, y, "o", ms=17, color="#ff7a00", mec="white", mew=1.6)
        axm.text(x, y, str(i), ha="center", va="center", color="white", fontproperties=fp, fontsize=11)
    axm.set_xlim(w, e)
    axm.set_ylim(s, n)
    axm.set_aspect(1 / np.cos(np.radians((s + n) / 2)))
    axm.tick_params(labelsize=7)

    axt = fig.add_axes([0.62, 0.02, 0.37, 0.96])
    axt.axis("off")
    i = int(round((wind_from % 360) / 45)) % 8
    head = f"{REGIONS[region]['name']} — أحلى {top if top <= 5 else 5} جلسات"
    axt.text(1, 0.985, ar(head), ha="right", va="top", fontproperties=fp, fontsize=17)
    axt.text(1, 0.955, ar(f"الريح الليلة (مثال): من {M.DIR_AR[M.DIRS[i]]} {int(gust)} كم/س"), ha="right", va="top", fontproperties=fr, fontsize=12, color="#444")
    y = 0.915
    for k, (sc, f) in enumerate(ranked[:5], start=1):
        p = f["properties"]
        rs = []
        wr = wind_reason(p["shelter"], wind_from)
        if wr:
            rs.append(wr)
        rs += [M.REASON_AR[c] + (f" ({p['near_name']})" if c == "fame" and p.get("near_name") else "") for c in p["reasons"]]
        lon, lat = f["geometry"]["coordinates"]
        axt.text(1, y, ar(f"{k}.  درجة {int(round(sc * 100))}" + (f" · قرب {p['near_name']}" if p.get("near_name") else "")), ha="right", va="top", fontproperties=fp, fontsize=13, color="#c25400")
        axt.text(0, y, f"{lat:.4f}, {lon:.4f}", ha="left", va="top", fontsize=9, color="#888")
        y -= 0.03
        axt.text(1, y, ar(" · ".join(rs[:3])), ha="right", va="top", fontproperties=fr, fontsize=12)
        y -= 0.027
        extra = rs[3:6]
        if extra:
            axt.text(1, y, ar(" · ".join(extra)), ha="right", va="top", fontproperties=fr, fontsize=10.5, color="#555")
            y -= 0.025
        axs = f"سلامة {int(p['safety']*100)} · راحة {int(p['comfort']*100)} · جمال {int(p['beauty']*100)} · وصول {int(p['access']*100)} · فوق المجرى {p['hand_m']} م · عن الدرب {p['d_track_m']} م"
        axt.text(1, y, ar(axs), ha="right", va="top", fontproperties=fr, fontsize=9.5, color="#777")
        y -= 0.024
        if p.get("protected"):
            axt.text(1, y, ar(f"محمية ({p['protected']}): تأكد من التصريح"), ha="right", va="top", fontproperties=fr, fontsize=10, color="#a00")
            y -= 0.024
        y -= 0.018
    legend = ["أزرق: مجرى سيل ومنطقة استبعاده", "فيروزي: منخفض يتجمع فيه الماء", "أبيض: سبخة", "رمادي: عمران وعزب", "أحمر: منطقة عسكرية", "بني: ميل قوي",
              "خط أصفر متقطع: دروب OSM", "النقاط البرتقالية الصغيرة: باقي المرشحين"]
    fig.text(0.61, 0.016, "  ·  ".join(legend[:4]), ha="right", va="bottom", fontproperties=fr, fontsize=9, color="#222")
    fig.text(0.61, 0.0, "  ·  ".join(legend[4:]), ha="right", va="bottom", fontproperties=fr, fontsize=9, color="#222")
    axt.text(1, 0.03, ar("تقدير من صور الأقمار، تأكد بعينك. الاحتطاب ممنوع، ولا تخيّم فوق النبات."), ha="right", va="bottom", fontproperties=fp, fontsize=11, color="#a00")
    axt.text(1, 0.005, "Sentinel-2 L2A (Copernicus) · Copernicus DEM GLO-30 · ESA WorldCover 2021 CC BY 4.0 · © OpenStreetMap contributors",
             ha="right", va="bottom", fontsize=7.5, color="#666")
    os.makedirs(os.path.dirname(png), exist_ok=True)
    fig.savefig(png)
    print("wrote", png)


if __name__ == "__main__":
    a = sys.argv
    main(a[1], a[2], a[3], a[4], float(a[5]) if len(a) > 5 else 0.0, float(a[6]) if len(a) > 6 else 25.0, int(a[7]) if len(a) > 7 else 8)
