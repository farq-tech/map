"""Fetch the open rasters for one region onto the analysis grid (windowed COG reads, no full tiles).

Sources (all from the AWS Open Data registry, anonymous HTTPS):
  * Copernicus DEM GLO-30  s3://copernicus-dem-30m   (Copernicus DEM licence, commercial use OK, attribution)
  * ESA WorldCover 10 m v200 (2021)  s3://esa-worldcover  (CC-BY 4.0)
  * Sentinel-2 L2A COGs  s3://sentinel-cogs via Earth Search STAC  (Copernicus Sentinel data terms)

Never Mapbox, Google or Esri imagery (docs/AI-SATELLITE.md).

Usage: python -I fetch_rasters.py <region> <cache_dir>
Writes <cache_dir>/<region>/rasters_<arcsec>.npz and appends to <cache_dir>/<region>/sources.json.
"""
import hashlib
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request

import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.transform import from_bounds
from rasterio.vrt import WarpedVRT

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from regions import ANALYSIS_ARCSEC, REGIONS, grid_shape  # noqa: E402

GDAL_ENV = dict(
    AWS_NO_SIGN_REQUEST="YES",
    GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR",
    CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif,.TIF",
    GDAL_HTTP_MAX_RETRY="4",
    GDAL_HTTP_RETRY_DELAY="2",
    # A stalled connection must fail (and be retried by read_into) instead of hanging a tile for an hour.
    GDAL_HTTP_CONNECTTIMEOUT="30",
    GDAL_HTTP_TIMEOUT="120",
)

DEM_URL = ("https://copernicus-dem-30m.s3.eu-central-1.amazonaws.com/"
           "Copernicus_DSM_COG_10_{ns}{lat:02d}_00_{ew}{lon:03d}_00_DEM/"
           "Copernicus_DSM_COG_10_{ns}{lat:02d}_00_{ew}{lon:03d}_00_DEM.tif")
WC_URL = ("https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/"
          "ESA_WorldCover_10m_2021_v200_{ns}{lat:02d}{ew}{lon:03d}_Map.tif")
STAC = "https://earth-search.aws.element84.com/v1/search"


def etag(url, attempts=5):
    """ETag and size of a remote file. A 404 is the answer (the caller decides); a reset or timeout is retried."""
    req = urllib.request.Request(url, method="HEAD")
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.headers.get("ETag", "").strip('"'), int(r.headers.get("Content-Length", 0))
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, OSError) as e:
            if attempt == attempts:
                raise
            print(f"HEAD failed ({attempt}/{attempts}), retrying: {str(e)[:80]} {url}", flush=True)
            time.sleep(5 * attempt)


def land_cells(urls):
    """(url, etag, bytes) of the cells that exist. Copernicus DEM and ESA WorldCover publish land cells only: a
    coastal tile whose halo reaches an open-sea cell gets a 404 there, which is not an error (sea, no ground)."""
    found = []
    for u in urls:
        try:
            tag, size = etag(u)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                print(f"no data (open sea): {u}", flush=True)
                continue
            raise
        found.append((u, tag, size))
    return found


def target(bbox, arcsec):
    s, w, n, e = bbox
    rows, cols = grid_shape(bbox, arcsec)
    return from_bounds(w, s, e, n, cols, rows), rows, cols


def read_into(url, bbox, arcsec, resampling, dtype="float32", nodata=None, attempts=5):
    """One windowed read. A server that cuts a response short ("got N bytes, expected M") or resets the
    connection raises RasterioIOError; that is transient, so retry with a growing pause before failing."""
    tr, rows, cols = target(bbox, arcsec)
    for attempt in range(1, attempts + 1):
        try:
            with rasterio.Env(**GDAL_ENV):
                with rasterio.open(url) as src:
                    with WarpedVRT(src, crs="EPSG:4326", transform=tr, width=cols, height=rows,
                                   resampling=resampling, src_nodata=nodata if nodata is not None else src.nodata,
                                   nodata=nodata if nodata is not None else src.nodata) as vrt:
                        return vrt.read(1).astype(dtype)
        except rasterio.errors.RasterioIOError as e:
            if attempt == attempts:
                raise
            print(f"read failed ({attempt}/{attempts}), retrying: {str(e)[:80]} {url}", flush=True)
            time.sleep(5 * attempt)


def tiles(bbox, step):
    s, w, n, e = bbox
    for lat in range(math.floor(s / step) * step, math.ceil(n / step) * step, step):
        for lon in range(math.floor(w / step) * step, math.ceil(e / step) * step, step):
            yield lat, lon


def mosaic(urls, bbox, arcsec, resampling, nodata):
    out = None
    for u in urls:
        a = read_into(u, bbox, arcsec, resampling, nodata=nodata)
        if out is None:
            out = a
        else:
            m = (out == nodata) | np.isnan(out)
            out[m] = a[m]
    return out


def fmt(lat, lon, url):
    return url.format(ns="N" if lat >= 0 else "S", lat=abs(lat), ew="E" if lon >= 0 else "W", lon=abs(lon))


def stac_items(bbox, dt, max_cloud, limit=40):
    s, w, n, e = bbox
    body = json.dumps({
        "collections": ["sentinel-2-l2a"], "bbox": [w, s, e, n], "datetime": dt, "limit": limit,
        "query": {"eo:cloud_cover": {"lt": max_cloud}},
    }).encode()
    req = urllib.request.Request(STAC, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["features"]


def s2_by_date(bbox, dt, max_cloud, dates_wanted):
    """Group items by acquisition day; keep the days whose tiles together cover the bbox best."""
    items = stac_items(bbox, dt, max_cloud)
    days = {}
    for it in items:
        days.setdefault(it["properties"]["datetime"][:10], []).append(it)
    ranked = sorted(days.items(), key=lambda kv: (-len(kv[1]), np.mean([i["properties"]["eo:cloud_cover"] for i in kv[1]])))
    return ranked[:dates_wanted]


def s2_bands(bbox, arcsec, day_items, bands):
    out = {}
    for b in bands:
        acc = None
        for it in day_items:
            a = read_into(it["assets"][b]["href"], bbox, arcsec, Resampling.average, nodata=0)
            if acc is None:
                acc = a
            else:
                m = acc == 0
                acc[m] = a[m]
        acc = acc.astype("float32")
        acc[acc == 0] = np.nan
        # Earth Search v1 L2A (processing baseline >= 04.00) carries a +1000 offset; the
        # asset's raster:bands scale/offset says so. Convert to reflectance.
        rb = day_items[0]["assets"][b].get("raster:bands", [{}])[0]
        out[b] = acc * rb.get("scale", 1e-4) + rb.get("offset", -0.1)
    return out


def main(region, cache):
    reg = REGIONS[region]
    bbox = reg["bbox"]
    arc = ANALYSIS_ARCSEC
    odir = os.path.join(cache, region)
    os.makedirs(odir, exist_ok=True)
    sources = []

    all_dem = [fmt(la, lo, DEM_URL) for la, lo in tiles(bbox, 1)]
    dem_cells = land_cells(all_dem)
    if not dem_cells:
        raise SystemExit(f"{region}: no Copernicus DEM cell at all")
    for u, tag, size in dem_cells:
        sources.append({"dataset": "Copernicus DEM GLO-30", "url": u, "etag": tag, "bytes": size})
    dem_urls = [c[0] for c in dem_cells]
    dem = mosaic(dem_urls, bbox, arc, Resampling.average, nodata=-32767.0)
    if len(dem_urls) < len(all_dem):  # missing cells are open sea: sea level, not "no data"
        dem = np.where((dem == -32767.0) | np.isnan(dem), 0.0, dem).astype(dem.dtype)

    wc_cells = land_cells([fmt(la, lo, WC_URL) for la, lo in tiles(bbox, 3)])
    for u, tag, size in wc_cells:
        sources.append({"dataset": "ESA WorldCover 10m 2021 v200", "url": u, "etag": tag, "bytes": size})
    wc_urls = [c[0] for c in wc_cells]
    # The 10 m class map read once at ~10 m (6x the grid), then block statistics per cell:
    # the dominant class and the fraction of each class of interest.
    rows, cols = grid_shape(bbox, arc)
    wc10 = mosaic(wc_urls, bbox, arc / 6, Resampling.nearest, nodata=0).astype("uint8")[: rows * 6, : cols * 6]
    blocks = wc10.reshape(rows, 6, cols, 6)
    classes = (10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 100)
    fr = np.stack([(blocks == c).mean(axis=(1, 3)) for c in classes]).astype("float32")
    wc = np.array(classes, dtype="uint8")[fr.argmax(axis=0)]
    frac = {f"wc_frac_{c}": fr[i] for i, c in enumerate(classes) if c in (10, 20, 30, 50, 80, 90)}
    del wc10, blocks

    # Sentinel-2: spring greenness (after winter rain) and a recent dry-season scene for ground type.
    spring = s2_by_date(bbox, "2025-02-01T00:00:00Z/2025-04-30T23:59:59Z", 5, 3)
    recent = s2_by_date(bbox, "2026-09-01T00:00:00Z/2026-11-05T23:59:59Z", 3, 3)  # best day first, the rest are fallbacks
    ndvi_max = None
    for day, items in spring:
        try:
            b = s2_bands(bbox, arc, items, ["red", "nir"])
        except rasterio.errors.RasterioIOError as e:  # one damaged/truncated scene file must not sink the tile
            print(f"skipping spring scene day {day}: {str(e)[:80]}", flush=True)
            continue
        nd = (b["nir"] - b["red"]) / (b["nir"] + b["red"] + 1e-6)
        ndvi_max = nd if ndvi_max is None else np.fmax(ndvi_max, nd)
        for it in items:
            sources.append({"dataset": "Sentinel-2 L2A", "item": it["id"], "date": day, "use": "spring NDVI"})
    if ndvi_max is None:
        raise SystemExit(f"{region}: every spring Sentinel-2 day failed to read")
    rb = None
    for day, items in recent:
        try:
            rb = s2_bands(bbox, arc, items, ["blue", "green", "red", "nir", "swir16", "swir22"])
        except rasterio.errors.RasterioIOError as e:
            print(f"skipping dry-season scene day {day}: {str(e)[:80]}", flush=True)
            continue
        for it in items:
            sources.append({"dataset": "Sentinel-2 L2A", "item": it["id"], "date": day, "use": "ground type"})
        break
    if rb is None:
        raise SystemExit(f"{region}: every dry-season Sentinel-2 day failed to read")

    arrays = dict(dem=dem, wc=wc, ndvi_spring=ndvi_max.astype("float32"),
                  **{f"s2_{k}": v.astype("float32") for k, v in rb.items()}, **frac)
    path = os.path.join(odir, f"rasters_{arc}.npz")
    np.savez_compressed(path, bbox=np.array(bbox), arcsec=arc, **arrays)
    h = hashlib.sha256(open(path, "rb").read()).hexdigest()
    with open(os.path.join(odir, "sources.json"), "w") as f:
        json.dump({"region": region, "bbox": bbox, "arcsec": arc, "sources": sources,
                   "output": os.path.basename(path), "sha256": h}, f, indent=1, ensure_ascii=False)
    print(region, dem.shape, "dem", float(np.nanmin(dem)), float(np.nanmax(dem)), "sha256", h[:12])


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
