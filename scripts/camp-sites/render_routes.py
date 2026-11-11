"""Illustration of «مخطط دروب البر»: the three options between two points over open data.

Usage: python -I render_routes.py <region> <cache_dir> <png> <lat1,lng1> <lat2,lng2> [rain]
"""
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib import font_manager  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import routes as RT  # noqa: E402
from regions import ANALYSIS_ARCSEC, REGIONS  # noqa: E402
from render import FONT, FONT_R, hillshade  # noqa: E402
import model as M  # noqa: E402

LABEL = {"easy": "الأسهل", "short": "الأقصر", "balanced": "المتوازن"}
COLOR = {"easy": "#2ecc71", "short": "#e74c3c", "balanced": "#3498db"}
TIP = {
    "crest": "لفّ مع بطن الفلج بدل ما تقطع الطعس",
    "against": "امشِ مع العرق لين تلقى قطعة منخفضة ثم اعبر",
    "sabkha": "دُر حول السبخة من الأرض الصلبة",
    "wadi": "اعبر الوادي عرضيًا ولا تمشي في بطنه",
    "down": "نزلة قوية: انزل مع ميلها بشويش أو لف حولها",
    "up": "طلعة قوية: خذها بزاوية أو لف حولها",
    "rock": "منحدر صخري: دوّر مدخل أسهل",
}


def main(region, cache, png, a, b, rain=False):
    g = RT.grid_from_layers(region, cache)
    G = RT.Grid(g)
    A = G.rc(*a)
    B = G.rc(*b)
    res = {}
    for mode in RT.MODES:
        p = RT.route(G, A, B, mode, rain=rain)
        res[mode] = (p, RT.summarize(G, p, rain=rain) if p else None)
    R = np.load(os.path.join(cache, region, f"rasters_{ANALYSIS_ARCSEC}.npz"))
    s, w, n, e = REGIONS[region]["bbox"]
    dx, dy = M.cell_size_m((s + n) / 2, ANALYSIS_ARCSEC)
    rgb = np.clip(np.nan_to_num(np.dstack([R["s2_red"], R["s2_green"], R["s2_blue"]]), nan=0.2) * 2.4, 0, 1) ** 0.9
    hs = hillshade(R["dem"].astype("float64"), dx, dy)
    img = np.clip(rgb * (0.55 + 0.6 * hs[..., None]), 0, 1)

    font_manager.fontManager.addfont(FONT)
    font_manager.fontManager.addfont(FONT_R)
    fp = font_manager.FontProperties(fname=FONT)
    fr = font_manager.FontProperties(fname=FONT_R)
    lats = [G.latlng(*c)[0] for m in res.values() if m[0] for c in m[0]] + [a[0], b[0]]
    lngs = [G.latlng(*c)[1] for m in res.values() if m[0] for c in m[0]] + [a[1], b[1]]
    pad = 0.02
    x0, x1, y0, y1 = min(lngs) - pad, max(lngs) + pad, min(lats) - pad, max(lats) + pad
    fig = plt.figure(figsize=(16, 10), dpi=110)
    axm = fig.add_axes([0.01, 0.04, 0.58, 0.92])
    axm.imshow(img, extent=(w, e, s, n), interpolation="bilinear")
    over = np.zeros(g["cls"].shape + (4,))
    over[g["cls"] == RT.WADI] = (0.1, 0.3, 1.0, 0.45)
    over[g["cls"] == RT.SABKHA] = (1, 1, 1, 0.7)
    over[g["cls"] == RT.CREST] = (0.55, 0.25, 0.0, 0.35)
    over[g["cls"] == RT.FORBIDDEN] = (0.4, 0.4, 0.4, 0.5)
    over[g["track"]] = (1.0, 0.85, 0.5, 0.9)
    axm.imshow(over, extent=(w, e, s, n), interpolation="nearest")
    for mode in ("short", "balanced", "easy"):
        p, sm = res[mode]
        if not p:
            continue
        ll = np.array([G.latlng(*c) for c in p])
        axm.plot(ll[:, 1], ll[:, 0], color=COLOR[mode], lw=3.2 if mode == "easy" else 2.4, alpha=0.95, solid_capstyle="round")
        for h in sm["hard"]:
            hl = np.array([G.latlng(*c) for c in h["cells"]])
            axm.plot(hl[:, 1], hl[:, 0], color="#ff0055", lw=6, alpha=0.55)
    axm.plot(a[1], a[0], "o", ms=12, color="white", mec="k")
    axm.plot(b[1], b[0], "*", ms=20, color="#ff7a00", mec="k")
    axm.set_xlim(x0, x1)
    axm.set_ylim(y0, y1)
    axm.set_aspect(1 / np.cos(np.radians((s + n) / 2)))
    axm.tick_params(labelsize=7)

    axt = fig.add_axes([0.61, 0.02, 0.38, 0.96])
    axt.axis("off")
    axt.text(1, 0.985, "مخطط دروب البر — ٣ خيارات", ha="right", va="top", fontproperties=fp, fontsize=18)
    axt.text(1, 0.955, f"{REGIONS[region]['name']}" + (" · فيه تحذير مطر: بطون الأودية ممنوعة" if rain else ""), ha="right", va="top",
             fontproperties=fr, fontsize=12, color="#444")
    y = 0.91
    for mode in ("easy", "balanced", "short"):
        p, sm = res[mode]
        axt.text(1, y, LABEL[mode], ha="right", va="top", fontproperties=fp, fontsize=15, color=COLOR[mode])
        y -= 0.032
        if not sm:
            axt.text(1, y, "ما لقينا طريق", ha="right", va="top", fontproperties=fr, fontsize=12)
            y -= 0.04
            continue
        line = f"{sm['distance_m'] / 1000:.1f} كم · نحو {int(round(sm['time_min']))} دقيقة · {int(round(sm['track_pct']))}٪ على درب معروف"
        axt.text(1, y, line, ha="right", va="top", fontproperties=fr, fontsize=12)
        y -= 0.028
        reasons = {}
        for h in sm["hard"]:
            reasons[h["reason"]] = reasons.get(h["reason"], 0) + h["m"]
        if reasons:
            t = " · ".join(f"{RT.REASON_AR[k]} {int(v)} م" for k, v in sorted(reasons.items(), key=lambda kv: -kv[1]))
            axt.text(1, y, "مقاطع صعبة: " + t, ha="right", va="top", fontproperties=fr, fontsize=11, color="#c0003c")
            y -= 0.026
            top = max(reasons, key=reasons.get)
            axt.text(1, y, "كيف تتجنبها: " + TIP.get(top, ""), ha="right", va="top", fontproperties=fr, fontsize=11, color="#555")
            y -= 0.026
        else:
            axt.text(1, y, "ما فيه مقاطع صعبة تُذكر", ha="right", va="top", fontproperties=fr, fontsize=11, color="#2a7")
            y -= 0.026
        y -= 0.025
    legend = ["أبيض: البداية · نجمة: الوجهة", "خط وردي عريض: مقطع صعب", "أزرق: مجرى وادي", "بني: طعس قوي",
              "أصفر: درب OSM", "رمادي: ممنوع (عسكري/عمران)"]
    for t in legend:
        axt.text(1, y, t, ha="right", va="top", fontproperties=fr, fontsize=10, color="#333")
        y -= 0.022
    axt.text(1, 0.03, "مسار مقترح من صور الأقمار، تأكد بعينك. ما يغني عن خبرة الدليل.", ha="right", va="bottom",
             fontproperties=fp, fontsize=12, color="#a00")
    axt.text(1, 0.005, "Sentinel-2 L2A (Copernicus) · Copernicus DEM GLO-30 · ESA WorldCover 2021 CC BY 4.0 · © OpenStreetMap contributors",
             ha="right", va="bottom", fontsize=7.5, color="#666")
    fig.savefig(png)
    for mode, (p, sm) in res.items():
        if sm:
            print(mode, round(sm["distance_m"]), round(sm["time_min"]), round(sm["track_pct"]), [(h["reason"], round(h["m"])) for h in sm["hard"]])
    print("wrote", png)


if __name__ == "__main__":
    a = sys.argv
    p1 = tuple(float(x) for x in a[4].split(","))
    p2 = tuple(float(x) for x in a[5].split(","))
    main(a[1], a[2], a[3], p1, p2, rain=len(a) > 6 and a[6] == "rain")
