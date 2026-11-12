"""Sample storage: one folder per annotated image, everything the owner asked for.

samples/<sample_id>/
    image.tif        original georeferenced image (GeoTIFF, own CRS/transform)
    preview.jpg      EPSG:3857 display copy for the web UI (+ preview.json bounds)
    tracks.geojson   tracks in WGS84 (RFC 7946): centrelines + optional edges
    mask.png/.tif    binary mask on the image pixel grid (.tif keeps the georeferencing)
    mask_types.png   class-index mask (1..6 = track type), mask_edges.png edges
    overlay.png      mask + vectors drawn on the image (visual proof of alignment)
    metadata.json    id, georeferencing, terrain, clarity, licence, provenance, stats
"""
from __future__ import annotations

import hashlib
import json
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import rasterio
from PIL import Image
from rasterio.enums import Resampling
from rasterio.warp import calculate_default_transform, reproject
from rasterio.windows import Window

from . import config, rasterize, tiles
from .geo import Grid, line_length_m, region_cell, utm_epsg

SCHEMA_VERSION = 1
MAX_IMPORT_PIXELS = 100_000_000


class SampleError(ValueError):
    pass


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sample_dir(sample_id: str) -> Path:
    if not sample_id.replace("_", "").replace("-", "").isalnum():
        raise SampleError("معرّف عينة غير صالح")
    return config.SAMPLES_DIR / sample_id


def _write_geojson(path: Path, fc: dict) -> None:
    """One feature per line: diff-friendly and readable (coordinates stay full precision)."""
    head = {k: v for k, v in fc.items() if k != "features"}
    lines = ",\n".join(json.dumps(f, ensure_ascii=False, separators=(",", ":")) for f in fc["features"])
    body = json.dumps(head, ensure_ascii=False)[:-1]
    tmp = path.with_suffix(".tmp")
    tmp.write_text(f'{body}{", " if head else ""}"features": [\n{lines}\n]}}\n')
    tmp.replace(path)


def _write_json(path: Path, obj) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=2))
    tmp.replace(path)


def read_metadata(sample_id: str) -> dict:
    p = sample_dir(sample_id) / "metadata.json"
    if not p.is_file():
        raise SampleError("العينة غير موجودة")
    return json.loads(p.read_text())


def grid_of(meta: dict) -> Grid:
    return Grid.from_dict(meta["georef"])


# ------------------------------------------------------------------ imagery I/O
def to_rgb8(arr: np.ndarray) -> np.ndarray:
    """(bands, H, W) any dtype -> (H, W, 3) uint8. Non-uint8 data gets a 2-98 percentile stretch."""
    if arr.shape[0] == 1:
        arr = np.repeat(arr, 3, axis=0)
    arr = arr[:3]
    if arr.dtype != np.uint8:
        out = np.zeros(arr.shape, np.uint8)
        for i in range(arr.shape[0]):
            band = arr[i].astype(np.float32)
            valid = band[band != 0] if (band != 0).any() else band
            lo, hi = np.percentile(valid, [2, 98])
            out[i] = np.clip((band - lo) / max(hi - lo, 1e-6) * 255, 0, 255).astype(np.uint8)
        arr = out
    return np.moveaxis(arr, 0, -1)


def read_rgb(sample_id: str) -> np.ndarray:
    with rasterio.open(sample_dir(sample_id) / "image.tif") as src:
        return to_rgb8(src.read())


def _write_rgb_geotiff(path: Path, rgb: np.ndarray, grid: Grid) -> None:
    with rasterio.open(path, "w", driver="GTiff", height=grid.height, width=grid.width, count=3,
                       dtype="uint8", crs=grid.crs, transform=grid.transform,
                       compress="deflate", predictor=2, photometric="RGB", tiled=True,
                       blockxsize=256, blockysize=256) as dst:
        dst.write(np.moveaxis(rgb, -1, 0))


def _write_preview(sample_dir_: Path, rgb: np.ndarray, grid: Grid) -> dict:
    """EPSG:3857 display copy (<= 2048 px) so Leaflet can overlay it with exact corners."""
    if grid.crs == "EPSG:3857" and max(rgb.shape[:2]) <= 2048:
        out = rgb
        bx0, by0, bx1, by1 = grid.bounds_native()
    else:
        dst_t, w, h = calculate_default_transform(
            grid.crs, "EPSG:3857", grid.width, grid.height, *grid.bounds_native(),
            dst_width=None, dst_height=None)
        scale = max(w, h) / 2048 if max(w, h) > 2048 else 1.0
        if scale > 1:
            dst_t, w, h = calculate_default_transform(
                grid.crs, "EPSG:3857", grid.width, grid.height, *grid.bounds_native(),
                resolution=(dst_t.a * scale, -dst_t.e * scale))
        out = np.zeros((h, w, 3), np.uint8)
        for b in range(3):
            reproject(rgb[..., b], out[..., b], src_transform=grid.transform, src_crs=grid.crs,
                      dst_transform=dst_t, dst_crs="EPSG:3857", resampling=Resampling.bilinear)
        bx0, by1 = dst_t.c, dst_t.f
        bx1, by0 = dst_t.c + dst_t.a * w, dst_t.f + dst_t.e * h
    Image.fromarray(out).save(sample_dir_ / "preview.jpg", quality=92)
    from .geo import transformer
    t = transformer("EPSG:3857", "EPSG:4326")
    w_lon, s_lat = t.transform(bx0, by0)
    e_lon, n_lat = t.transform(bx1, by1)
    info = {"bounds": [[s_lat, w_lon], [n_lat, e_lon]], "width": int(out.shape[1]), "height": int(out.shape[0])}
    _write_json(sample_dir_ / "preview.json", info)
    return info


def _base_metadata(sample_id: str, grid: Grid, source: dict, fixture: bool) -> dict:
    lon, lat = grid.centre_lonlat()
    return {
        "schema_version": SCHEMA_VERSION,
        "sample_id": sample_id,
        "created_utc": _now(),
        "updated_utc": _now(),
        "status": "new",
        "fixture": fixture,  # True = programmatic test sample, never counted as owner data
        "source": source,
        "georef": {
            **grid.to_dict(),
            "bbox_wgs84": list(grid.bbox_wgs84()),
            "centre_wgs84": [lon, lat],
            "ground_res_m": grid.ground_res_m(),
            "utm_epsg": utm_epsg(lon, lat),
            "pixel_convention": "rasterio: (0,0) = top-left corner of top-left pixel",
        },
        "region_cell": region_cell(lon, lat),
        "terrain": None,
        "clarity": None,
        "notes": "",
        "imagery_date": "unknown",
        "license": dict(config.LICENSE_NOTE),
        "annotation": None,
    }


def _finish_create(sample_id: str, sdir: Path, rgb: np.ndarray, grid: Grid, meta: dict, copy_from: Path | None) -> dict:
    if copy_from is None:
        _write_rgb_geotiff(sdir / "image.tif", rgb, grid)
    else:
        shutil.copyfile(copy_from, sdir / "image.tif")
    _write_preview(sdir, rgb, grid)
    empty = {"type": "FeatureCollection", "features": [], "sample_id": sample_id}
    _write_geojson(sdir / "tracks.geojson", empty)
    meta["image_sha256"] = hashlib.sha256((sdir / "image.tif").read_bytes()).hexdigest()
    _write_json(sdir / "metadata.json", meta)
    return meta


# ------------------------------------------------------------------ creation
def create_from_mosaic(z: int, x0: int, y0: int, nx: int, ny: int, fixture: bool = False) -> tuple[dict, bool]:
    """Fetch (cached) Mapbox z/x/y@2x tiles -> georeferenced chip. Returns (metadata, already_existed)."""
    if z != config.NATIVE_ZOOM:
        raise SampleError(f"الدقة الحقيقية هي z{config.NATIVE_ZOOM}@2x فقط؛ z18 مجرد تكبير.")
    sid = "s" + hashlib.sha1(f"mapbox|{z}|{x0}|{y0}|{nx}|{ny}".encode()).hexdigest()[:12]
    sdir = sample_dir(sid)
    if (sdir / "metadata.json").is_file():
        return read_metadata(sid), True
    rgb, grid = tiles.fetch_mosaic(z, x0, y0, nx, ny)
    sdir.mkdir(parents=True, exist_ok=True)
    source = {
        "type": "mapbox_satellite", "tileset": "mapbox.satellite", "zoom": z, "tile_scale": 2,
        "tiles": {"x0": x0, "y0": y0, "nx": nx, "ny": ny},
        "nominal_resolution_note": "z17@2x ~0.54 m/px at lat 25.5; z18 is only upscaled from z17 (no new detail)",
    }
    meta = _base_metadata(sid, grid, source, fixture)
    return _finish_create(sid, sdir, rgb, grid, meta, None), False


def create_from_geotiff(path: Path, filename: str | None = None,
                        crop_lonlat: tuple[float, float, float, float] | None = None,
                        fixture: bool = False) -> tuple[dict, bool]:
    path = Path(path)
    with rasterio.open(path) as src:
        if src.crs is None:
            raise SampleError("الملف بلا نظام إحداثيات (CRS) — لا يمكن استخدامه.")
        if src.count < 1:
            raise SampleError("الملف بلا نطاقات")
        window = Window(0, 0, src.width, src.height)
        if crop_lonlat:
            from .geo import transformer
            t = transformer("EPSG:4326", src.crs.to_string())
            x0, y0 = t.transform(crop_lonlat[0], crop_lonlat[1])
            x1, y1 = t.transform(crop_lonlat[2], crop_lonlat[3])
            window = rasterio.windows.from_bounds(min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1),
                                                  transform=src.transform).round_offsets().round_lengths()
            window = window.intersection(Window(0, 0, src.width, src.height))
        if window.width * window.height > MAX_IMPORT_PIXELS:
            raise SampleError("الصورة كبيرة (>100 ميغابكسل). اقصّها بخيار --crop أو gdal_translate -projwin.")
        arr = src.read(window=window)
        transform = src.window_transform(window)
        crs = src.crs.to_wkt() if src.crs.to_epsg() is None else f"EPSG:{src.crs.to_epsg()}"
        grid = Grid(crs, transform, int(window.width), int(window.height))
        file_sha = hashlib.sha256(path.read_bytes()).hexdigest()
        nodata = src.nodata
    key = f"geotiff|{file_sha}|{int(window.col_off)}|{int(window.row_off)}|{grid.width}|{grid.height}"
    sid = "s" + hashlib.sha1(key.encode()).hexdigest()[:12]
    sdir = sample_dir(sid)
    if (sdir / "metadata.json").is_file():
        return read_metadata(sid), True
    sdir.mkdir(parents=True, exist_ok=True)
    rgb = to_rgb8(arr)
    source = {
        "type": "geotiff_import", "original_filename": filename or path.name,
        "file_sha256": file_sha, "bands": int(arr.shape[0]), "dtype": str(arr.dtype),
        "stretch": "2-98 percentile" if arr.dtype != np.uint8 else "none",
        "window": [int(window.col_off), int(window.row_off), grid.width, grid.height],
        "nodata": nodata,
    }
    meta = _base_metadata(sid, grid, source, fixture)
    # Keep the original pixel values: write the (possibly cropped) source bands as-is.
    with rasterio.open(sdir / "image.tif", "w", driver="GTiff", height=grid.height, width=grid.width,
                       count=arr.shape[0], dtype=arr.dtype, crs=grid.crs, transform=transform,
                       compress="deflate", nodata=nodata) as dst:
        dst.write(arr)
    return _finish_import(sid, sdir, rgb, grid, meta), False


def _finish_import(sid: str, sdir: Path, rgb: np.ndarray, grid: Grid, meta: dict) -> dict:
    _write_preview(sdir, rgb, grid)
    _write_geojson(sdir / "tracks.geojson", {"type": "FeatureCollection", "features": [], "sample_id": sid})
    meta["image_sha256"] = hashlib.sha256((sdir / "image.tif").read_bytes()).hexdigest()
    _write_json(sdir / "metadata.json", meta)
    return meta


# ------------------------------------------------------------------ annotations
def validate_geojson(fc: dict) -> dict:
    """Normalise incoming annotations; raise SampleError on anything unusable."""
    if not isinstance(fc, dict) or fc.get("type") != "FeatureCollection":
        raise SampleError("يجب أن يكون GeoJSON من نوع FeatureCollection")
    out = []
    ids = set()
    for f in fc.get("features", []):
        g = f.get("geometry") or {}
        if g.get("type") != "LineString":
            raise SampleError("المسموح خطوط LineString فقط")
        coords = [[round(float(x), 9), round(float(y), 9)] for x, y in g["coordinates"]]
        if len(coords) < 2:
            raise SampleError("كل خط يحتاج نقطتين على الأقل")
        if any(not (-180 <= x <= 180 and -90 <= y <= 90) for x, y in coords):
            raise SampleError("إحداثيات خارج النطاق (يجب WGS84 lon/lat)")
        p = dict(f.get("properties") or {})
        kind = p.get("kind", "centerline")
        if kind not in ("centerline", "edge"):
            raise SampleError("kind يجب أن يكون centerline أو edge")
        fid = str(p.get("id") or uuid.uuid4().hex[:10])
        if fid in ids:
            raise SampleError("معرّف ميزة مكرر")
        ids.add(fid)
        props = {"id": fid, "kind": kind}
        if kind == "centerline":
            tt = p.get("track_type", "dirt")
            if tt not in config.TRACK_TYPES:
                raise SampleError(f"نوع مسار غير معروف: {tt}")
            cl = int(p.get("clarity", 2))
            if cl not in config.CLARITY:
                raise SampleError("درجة وضوح غير صالحة (1-4)")
            props.update(track_type=tt, clarity=cl, track_id=fid)
        else:
            props.update(track_id=str(p.get("track_id") or ""), side=p.get("side"))
        if p.get("note"):
            props["note"] = str(p["note"])[:500]
        out.append({"type": "Feature", "properties": props, "geometry": {"type": "LineString", "coordinates": coords}})
    centre_ids = {f["properties"]["id"] for f in out if f["properties"]["kind"] == "centerline"}
    for f in out:
        if f["properties"]["kind"] == "edge" and f["properties"]["track_id"] not in centre_ids:
            raise SampleError("حافة مرتبطة بمسار غير موجود")
    return {"type": "FeatureCollection", "features": out}


def _edge_sides(fc: dict) -> None:
    """Tag each edge left/right of its track's centreline (looking along drawing direction)."""
    from shapely.geometry import LineString, Point
    cl = {f["properties"]["id"]: LineString(f["geometry"]["coordinates"]) for f in fc["features"]
          if f["properties"]["kind"] == "centerline"}
    for f in fc["features"]:
        if f["properties"]["kind"] != "edge":
            continue
        c = cl[f["properties"]["track_id"]]
        e = LineString(f["geometry"]["coordinates"])
        mid = e.interpolate(0.5, normalized=True)
        d = c.project(mid)
        p0, p1 = c.interpolate(max(d - 1e-6, 0)), c.interpolate(min(d + 1e-6, c.length))
        cross = (p1.x - p0.x) * (mid.y - p0.y) - (p1.y - p0.y) * (mid.x - p0.x)
        f["properties"]["side"] = "left" if cross > 0 else "right"


def stats_of(fc: dict) -> dict:
    by_type: dict[str, dict] = {}
    for f in rasterize.centerline_features(fc):
        t = f["properties"]["track_type"]
        s = by_type.setdefault(t, {"n": 0, "length_m": 0.0})
        s["n"] += 1
        s["length_m"] += line_length_m(f["geometry"]["coordinates"])
    for s in by_type.values():
        s["length_m"] = round(s["length_m"], 2)
    clar = {}
    for f in rasterize.centerline_features(fc):
        clar[str(f["properties"]["clarity"])] = clar.get(str(f["properties"]["clarity"]), 0) + 1
    return {
        "n_tracks": len(rasterize.centerline_features(fc)),
        "n_edges": len(rasterize.edge_features(fc)),
        "by_type": by_type,
        "clarity_counts": clar,
    }


def save_annotations(sample_id: str, fc_in: dict, updates: dict | None = None,
                     width_m: float = config.MASK_WIDTH_M_DEFAULT) -> dict:
    meta = read_metadata(sample_id)
    sdir = sample_dir(sample_id)
    grid = grid_of(meta)
    fc = validate_geojson(fc_in)
    _edge_sides(fc)
    fc["sample_id"] = sample_id
    fc["crs_note"] = "WGS84 lon/lat (RFC 7946). Pixel grid + CRS of the image: see metadata.json georef"
    masks = rasterize.make_masks(grid, fc, width_m)
    # outputs
    Image.fromarray(masks["mask"]).save(sdir / "mask.png")
    Image.fromarray(masks["types"]).save(sdir / "mask_types.png")
    Image.fromarray(masks["edges"]).save(sdir / "mask_edges.png")
    with rasterio.open(sdir / "mask.tif", "w", driver="GTiff", height=grid.height, width=grid.width, count=1,
                       dtype="uint8", crs=grid.crs, transform=grid.transform, compress="deflate") as dst:
        dst.write(masks["mask"], 1)
    rgb = read_rgb(sample_id)
    rasterize.render_overlay(rgb, grid, fc, masks).save(sdir / "overlay.png")
    _write_geojson(sdir / "tracks.geojson", fc)
    # metadata
    u = updates or {}
    if "terrain" in u:
        if u["terrain"] not in (None, *config.TERRAIN):
            raise SampleError("نوع تضاريس غير معروف")
        meta["terrain"] = u["terrain"]
    if "clarity" in u:
        if u["clarity"] is not None and int(u["clarity"]) not in config.CLARITY:
            raise SampleError("درجة وضوح غير صالحة")
        meta["clarity"] = None if u["clarity"] is None else int(u["clarity"])
    if "notes" in u:
        meta["notes"] = str(u["notes"])[:2000]
    st = stats_of(fc)
    meta["annotation"] = {
        **st,
        "mask_width_m": width_m,
        "mask_pixels": int((masks["mask"] > 0).sum()),
        "mask_coverage": round(float((masks["mask"] > 0).mean()), 6),
        "tracks_sha256": hashlib.sha256(json.dumps(fc, sort_keys=True).encode()).hexdigest(),
        "annotated_utc": _now(),
    }
    meta["status"] = "annotated" if st["n_tracks"] else "new"
    meta["updated_utc"] = _now()
    _write_json(sdir / "metadata.json", meta)
    return meta


def read_tracks(sample_id: str) -> dict:
    return json.loads((sample_dir(sample_id) / "tracks.geojson").read_text())


def list_samples(include_fixtures: bool = True) -> list[dict]:
    out = []
    if not config.SAMPLES_DIR.is_dir():
        return out
    for d in sorted(config.SAMPLES_DIR.iterdir()):
        p = d / "metadata.json"
        if p.is_file():
            m = json.loads(p.read_text())
            if include_fixtures or not m.get("fixture"):
                out.append(m)
    return out


def delete_sample(sample_id: str) -> None:
    shutil.rmtree(sample_dir(sample_id), ignore_errors=True)
