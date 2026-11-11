"""Run the camp-site model for one region and write the candidate GeoJSON.

Usage: python -I build.py <region> <cache_dir> <out_dir>
       python -I build.py --route-layers <region> <cache_dir>   (national tiles: only what routes.py reads)
Reads  <cache_dir>/<region>/rasters_2.npz and osm.json (fetch_rasters.py, fetch_osm.py)
Writes <out_dir>/camp-sites-<region>.geojson  (ranked candidates, small: committed + bundled)
       <cache_dir>/<region>/layers.npz         (intermediate layers for render.py / routes)
"""
import json
import math
import os
import sys

import numpy as np
from rasterio.features import rasterize
from rasterio.transform import from_bounds
from scipy import ndimage
from shapely import wkt as swkt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model as M  # noqa: E402
from regions import ANALYSIS_ARCSEC, REGIONS  # noqa: E402

# Light sources for the dark-sky proxy beyond the bbox (population, approx., 2022 census).
MAJOR = [("الرياض", 24.71, 46.68, 7.0e6, 28.0), ("حائل", 27.52, 41.69, 4.0e5, 6.0), ("بريدة", 26.33, 43.97, 6.0e5, 8.0),
         ("المجمعة", 25.90, 45.35, 6.0e4, 2.5), ("رماح", 25.57, 47.16, 1.5e4, 1.5), ("الأرطاوية", 26.50, 45.35, 3.0e4, 2.0)]
KIND_POP = {"city": 2.0e5, "town": 2.0e4, "village": 2.0e3, "hamlet": 200, "suburb": 3.0e4, "neighbourhood": 5.0e3,
            "isolated_dwelling": 20, "farm": 20}


def raster_of(geoms, shape, tr, buffer_deg=0.0):
    shapes = [(g.buffer(buffer_deg) if buffer_deg else g, 1) for g in geoms]
    if not shapes:
        return np.zeros(shape, bool)
    return rasterize(shapes, out_shape=shape, transform=tr, fill=0, all_touched=True, dtype="uint8").astype(bool)


def dist_m(mask, dx, dy):
    if not mask.any():
        return np.full(mask.shape, 1e6)
    return ndimage.distance_transform_edt(~mask, sampling=(dy, dx))


def near(mask, radius_m, dx, dy):
    return (dist_m(mask, dx, dy) <= radius_m).astype("float32")


def glow_map(bbox, shape, settlements, dx, dy):
    """Walker's law sky glow ∝ P · d^-2.5, summed over towns (a dark-sky proxy; see report)."""
    s, w, n, e = bbox
    rows, cols = shape
    step = 10
    lat = np.linspace(n, s, rows)[::step]
    lon = np.linspace(w, e, cols)[::step]
    LON, LAT = np.meshgrid(lon, lat)
    g = np.zeros(LAT.shape)
    srcs = [(la, lo, p, r) for _, la, lo, p, r in MAJOR]
    for st in settlements:
        if st.get("kind") in KIND_POP and st["wkt"].startswith("POINT"):
            pt = swkt.loads(st["wkt"])
            srcs.append((pt.y, pt.x, KIND_POP[st["kind"]], 0.5))
    for la, lo, p, r in srcs:
        d = np.hypot((LAT - la) * 110.6, (LON - lo) * 111.3 * math.cos(math.radians(la)))
        d = np.maximum(d - r, 0.5)
        g += p * d ** -2.5
    up = ndimage.zoom(g, (rows / g.shape[0], cols / g.shape[1]), order=1)[:rows, :cols]
    return up


def layers(region, cache):
    reg = REGIONS[region]
    bbox = reg["bbox"]
    s, w, n, e = bbox
    R = np.load(os.path.join(cache, region, f"rasters_{ANALYSIS_ARCSEC}.npz"))
    osm = json.load(open(os.path.join(cache, region, "osm.json")))
    dem = R["dem"].astype("float64")
    dem = np.where(np.isfinite(dem) & (dem > -1000), dem, np.nanmedian(dem))
    rows, cols = dem.shape
    tr = from_bounds(w, s, e, n, cols, rows)
    dx, dy = M.cell_size_m((s + n) / 2, ANALYSIS_ARCSEC)
    cell = math.hypot(dx, dy) / 2

    L = {}
    L["dem"] = dem
    L["slope"] = M.slope_pct(dem, dx, dy)
    filled = M.priority_flood(dem, eps=1e-5)
    L["sink_depth"] = filled - dem
    acc = M.d8_accumulation(filled, dx, dy)
    L["acc_km2"] = acc
    L["channel_excl"], L["d_channel"], idx = M.channel_exclusion(acc, dx, dy, L["sink_depth"])
    L["hand"] = M.hand(dem, idx)
    L["tpi500"] = M.tpi(dem, int(500 / dx))
    rough = M.roughness(dem, 2)
    L["rough"] = rough
    L["rough_1km"] = M.box_mean(rough, int(1000 / dx))

    frac = {c: R[f"wc_frac_{c}"] for c in (10, 20, 30, 50, 80, 90)}
    wc = R["wc"]
    s2 = {k: R[f"s2_{k}"].astype("float64") for k in ("blue", "green", "red", "nir", "swir16", "swir22")}
    for k in s2:
        s2[k] = np.where(np.isfinite(s2[k]), s2[k], np.nanmedian(s2[k]))
    G = M.ground_classes(s2, L["slope"], rough, wc, frac)
    wet = raster_of([swkt.loads(x["wkt"]) for x in osm["wet"]], dem.shape, tr)
    L["sabkha"] = G["sabkha"] | (wet & (wc != 80))
    L["sand"], L["gravel"] = G["sand"], G["gravel"]
    L["water_frac"] = np.maximum(frac[80], wet.astype("float32") * (wc == 80))
    L["built_frac"] = frac[50]
    nd = np.nan_to_num(R["ndvi_spring"].astype("float64"), nan=0.1)
    L["ndvi_here"] = nd
    veg = np.maximum.reduce([frac[10], frac[20], frac[30]])
    green_px = (nd > 0.16) | (veg > 0.3)
    L["green_near"] = np.clip(M.box_mean(green_px.astype(float), int(400 / dx)) / 0.08, 0, 1) * (nd < 0.25)
    L["gravel_near"] = near(G["gravel"], 150, dx, dy)
    L["sand_near"] = near(G["sand"] & (L["slope"] < 5), 100, dx, dy)
    L["sunset"] = M.sunset_openness(dem, dx, dy)
    L["shelter8"] = M.shelter_index(dem, dx, dy, veg_frac=veg)

    tracks = [swkt.loads(x["wkt"]) for x in osm["tracks"]]
    roads = [swkt.loads(x["wkt"]) for x in osm["roads"]]
    settle_geoms = [swkt.loads(x["wkt"]) for x in osm["settlements"]
                    if x.get("kind") not in {"city", "town", "suburb", "neighbourhood"} or not x["wkt"].startswith("POINT")]
    L["d_track"] = dist_m(raster_of(tracks, dem.shape, tr), dx, dy)
    L["d_road"] = dist_m(raster_of(roads, dem.shape, tr), dx, dy)
    L["d_settle"] = dist_m(raster_of(settle_geoms, dem.shape, tr) | (frac[50] > 0.3), dx, dy)
    L["d_military"] = dist_m(raster_of([swkt.loads(x["wkt"]) for x in osm["military"]], dem.shape, tr), dx, dy)
    prot = [(swkt.loads(x["wkt"]), x.get("name", "")) for x in osm["protected"]]
    L["protected_id"] = np.zeros(dem.shape, "int16")
    for i, (g, _) in enumerate(prot, start=1):
        m = raster_of([g], dem.shape, tr)
        L["protected_id"][m & (L["protected_id"] == 0)] = i
    glow = glow_map(bbox, dem.shape, osm["settlements"], dx, dy)
    L["glow"] = glow
    L["dark"] = 1 - M.ramp(np.log10(1 + glow), 0.3, 2.3)

    famous = [(swkt.loads(x["wkt"]), x["name"]) for x in osm["famous"]]
    fmask = raster_of([g for g, _ in famous], dem.shape, tr)
    dfam, fidx = ndimage.distance_transform_edt(~fmask, sampling=(dy, dx), return_indices=True) if fmask.any() else (np.full(dem.shape, 1e6), None)
    L["d_famous"] = dfam
    L["famous"] = 1 - M.ramp(dfam, 1500, 4000)
    meta = {"bbox": bbox, "dx": dx, "dy": dy, "tr": tr, "prot": [p for _, p in prot], "famous": famous, "fidx": fidx, "cell": cell}
    return L, meta


def famous_name_at(meta, r, c, L):
    if meta["fidx"] is None or L["d_famous"][r, c] > 4000:
        return None
    fr, fc = meta["fidx"][0][r, c], meta["fidx"][1][r, c]
    s, w, n, e = meta["bbox"]
    rows, cols = L["dem"].shape
    lat = n - (fr + 0.5) * (n - s) / rows
    lon = w + (fc + 0.5) * (e - w) / cols
    best, bd = None, 1e9
    for g, name in meta["famous"]:
        d = abs(g.y - lat) + abs(g.x - lon)
        if d < bd:
            best, bd = name, d
    return best


def build(region, cache, out_dir, n_sites=60):
    L, meta = layers(region, cache)
    excluded, rules = M.hard_exclusions(L)
    ax = M.axis_scores(L)
    # Candidate pick: static total with the shelter of the region's prevailing winds
    # (N / NW in winter in Najd) averaged with the best shelter, so the list holds sites that
    # shine in other winds too; the app re-ranks with tonight's wind.
    sh = L["shelter8"]
    shelter_pick = 0.5 * np.maximum(sh[0], sh[7]) + 0.5 * sh.max(axis=0)
    static = (0.25 * ax["comfort"] + 0.35 * ax["beauty"] + 0.15 * ax["access"] + 0.25 * shelter_pick) * (0.7 + 0.3 * ax["safety"])
    picks = M.pick_sites(static, excluded, meta["dx"], meta["dy"], n=n_sites)
    s, w, n, e = meta["bbox"]
    rows, cols = L["dem"].shape
    feats = []
    for rank, (r, c) in enumerate(picks, start=1):
        lat = n - (r + 0.5) * (n - s) / rows
        lon = w + (c + 0.5) * (e - w) / cols
        parts = {k: float(v[r, c]) for k, v in ax["parts"].items()}
        fname = famous_name_at(meta, r, c, L) if parts["fame"] > 0 else None
        pid = int(L["protected_id"][r, c])
        props = {
            "id": f"{region}-{rank:03d}",
            "region": region,
            "rank": rank,
            "score": round(float(static[r, c]), 3),
            "safety": round(float(ax["safety"][r, c]), 3),
            "comfort": round(float(ax["comfort"][r, c]), 3),
            "beauty": round(float(ax["beauty"][r, c]), 3),
            "access": round(float(ax["access"][r, c]), 3),
            "shelter": [round(float(x), 2) for x in sh[:, r, c]],
            "reasons": M.reasons(parts, float(L["d_channel"][r, c]), float(L["d_track"][r, c])),
            "hand_m": round(float(L["hand"][r, c]), 1),
            "d_channel_m": int(min(L["d_channel"][r, c], 99999)),
            "d_track_m": int(min(L["d_track"][r, c], 99999)),
            "d_road_m": int(min(L["d_road"][r, c], 99999)),
            "elev_m": int(round(L["dem"][r, c])),
            "ground": "sand" if L["sand_near"][r, c] > 0 else ("gravel" if L["gravel_near"][r, c] > 0 else "bare"),
            "near_name": fname,
            "protected": meta["prot"][pid - 1] if pid else None,
        }
        feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [round(lon, 5), round(lat, 5)]}, "properties": props})
    fc = {"type": "FeatureCollection",
          "properties": {"region": region, "name": REGIONS[region]["name"], "bbox": meta["bbox"], "model": "rules-v1",
                         "note": "تقدير من صور الأقمار، تأكد بعينك",
                         "attribution": "ESA WorldCover 2021 (CC BY 4.0) · Copernicus DEM GLO-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the EU and ESA · Contains modified Copernicus Sentinel data 2025-2026 · © OpenStreetMap contributors (ODbL)"},
          "features": feats}
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, f"camp-sites-{region}.geojson"), "w") as f:
        json.dump(fc, f, ensure_ascii=False, separators=(",", ":"))
    excl_code = np.zeros(L["dem"].shape, "uint8")
    for i, (k, m) in enumerate(rules.items(), start=1):
        excl_code[(excl_code == 0) & m] = i
    np.savez_compressed(os.path.join(cache, region, "layers.npz"), static=static.astype("float32"), excluded=excluded,
                        excl_code=excl_code, excl_names=np.array(list(rules.keys())), dem=L["dem"].astype("float32"),
                        slope=L["slope"].astype("float32"), acc=L["acc_km2"].astype("float32"), sabkha=L["sabkha"], sand=L["sand"],
                        gravel=L["gravel"], channel=M.channel_mask(L["acc_km2"], L["sink_depth"]), sink=L["sink_depth"] > M.SINK_DEPTH_M, channel_excl=L["channel_excl"],
                        shelter8=L["shelter8"], dark=L["dark"].astype("float32"), d_track=L["d_track"].astype("float32"),
                        protected=L["protected_id"] > 0, bbox=np.array(meta["bbox"]), d_road=L["d_road"].astype("float32"),
                        built=L["built_frac"] > 0.3, military=L["d_military"] < 1.0, water=L["water_frac"] > 0.3)
    stats = {k: round(float(m.mean()) * 100, 1) for k, m in rules.items()}
    print(region, "sites", len(feats), "excluded%", round(float(excluded.mean()) * 100, 1), stats)
    return fc


def route_layers(region, cache):
    """Only the layers routes.py reads, for a national tile (tiles.py). Same rules as `layers`, without
    the camp-site extras (shelter in 8 winds, sunset horizon, dark sky, ...), which cost most of the
    time and are not part of the route grid. Writes <cache>/<region>/layers.npz."""
    bbox = REGIONS[region]["bbox"]
    s, w, n, e = bbox
    R = np.load(os.path.join(cache, region, f"rasters_{ANALYSIS_ARCSEC}.npz"))
    osm = json.load(open(os.path.join(cache, region, "osm.json")))
    dem = R["dem"].astype("float64")
    dem = np.where(np.isfinite(dem) & (dem > -1000), dem, np.nanmedian(dem))
    rows, cols = dem.shape
    tr = from_bounds(w, s, e, n, cols, rows)
    dx, dy = M.cell_size_m((s + n) / 2, ANALYSIS_ARCSEC)
    slope = M.slope_pct(dem, dx, dy)
    filled = M.priority_flood(dem, eps=1e-5)
    sink = filled - dem
    acc = M.d8_accumulation(filled, dx, dy)
    rough = M.roughness(dem, 2)
    frac = {c: R[f"wc_frac_{c}"] for c in (10, 20, 30, 50, 80, 90)}
    wc = R["wc"]
    s2 = {k: R[f"s2_{k}"].astype("float64") for k in ("blue", "green", "red", "nir", "swir16", "swir22")}
    for k in s2:
        s2[k] = np.where(np.isfinite(s2[k]), s2[k], np.nanmedian(s2[k]))
    G = M.ground_classes(s2, slope, rough, wc, frac)
    wet = raster_of([swkt.loads(x["wkt"]) for x in osm["wet"]], dem.shape, tr)
    water_frac = np.maximum(frac[80], wet.astype("float32") * (wc == 80))
    tracks = [swkt.loads(x["wkt"]) for x in osm["tracks"]]
    roads = [swkt.loads(x["wkt"]) for x in osm["roads"]]
    d_military = dist_m(raster_of([swkt.loads(x["wkt"]) for x in osm["military"]], dem.shape, tr), dx, dy)
    np.savez_compressed(os.path.join(cache, region, "layers.npz"), dem=dem.astype("float32"), slope=slope.astype("float32"),
                        acc=acc.astype("float32"), sabkha=G["sabkha"] | (wet & (wc != 80)), sand=G["sand"],
                        channel=M.channel_mask(acc, sink), bbox=np.array(bbox),
                        d_track=dist_m(raster_of(tracks, dem.shape, tr), dx, dy).astype("float32"),
                        d_road=dist_m(raster_of(roads, dem.shape, tr), dx, dy).astype("float32"),
                        built=frac[50] > 0.3, military=d_military < 1.0, water=water_frac > 0.3)
    print(region, "route layers", dem.shape)


if __name__ == "__main__":
    if sys.argv[1] == "--route-layers":
        route_layers(sys.argv[2], sys.argv[3])
    else:
        build(sys.argv[1], sys.argv[2], sys.argv[3])
