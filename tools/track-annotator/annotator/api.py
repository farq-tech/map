"""FastAPI backend. The browser UI and the e2e script use exactly these endpoints."""
from __future__ import annotations

import json
import tempfile
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from . import collect, config, export as export_mod, quality, review, store, suggest, tiles
from .geo import lonlat_to_tile

app = FastAPI(title="Sary Albarq track annotator", docs_url="/api/docs", openapi_url="/api/openapi.json")
config.ensure_dirs()


class MosaicReq(BaseModel):
    lon: float | None = None
    lat: float | None = None
    x0: int | None = None
    y0: int | None = None
    nx: int = 3
    ny: int = 3
    fixture: bool = False


class AnnotReq(BaseModel):
    geojson: dict
    terrain: str | None = None
    clarity: int | None = None
    notes: str | None = None
    mask_width_m: float = config.MASK_WIDTH_M_DEFAULT
    complete: bool | None = None
    rejected_suggestions: list[str] | None = None


class SuggestReq(BaseModel):
    backend: str = "auto"


class SkipReq(BaseModel):
    window_id: str
    reason: str = ""


class ExportReq(BaseModel):
    gsd: float = 1.0
    tile: int = 400
    include_fixtures: bool = False
    keep_empty: bool = False
    only_complete: bool = False
    seed: int = 0
    block_km: float = 5.0
    buffer_m: float = 500.0


def _err(e: Exception, code: int = 400):
    raise HTTPException(code, str(e))


@app.get("/api/config")
def get_config():
    return {
        "types": config.TRACK_TYPES, "clarity": {str(k): v for k, v in config.CLARITY.items()},
        "terrain": config.TERRAIN, "negative_categories": config.NEGATIVE_CATEGORIES,
        "suggest_backends": suggest.available_backends(), "native_zoom": config.NATIVE_ZOOM,
        "has_token": config.has_token(), "budget": tiles.budget_status(),
        "mask_width_m": config.MASK_WIDTH_M_DEFAULT,
        "imagery_note": "الدقة الحقيقية z17@2x ≈ 0.54 م/بكسل عند خط عرض 25.5؛ ما فوق ذلك (z18+) تكبير فقط بلا تفاصيل جديدة.",
        "license": config.LICENSE_NOTE,
    }


@app.get("/tiles/{z}/{x}/{y}.jpg")
def tile(z: int, x: int, y: int):
    if z < 8 or z > config.NATIVE_ZOOM:
        raise HTTPException(404, "خارج النطاق")
    try:
        data = tiles.get_tile(z, x, y)
    except tiles.BudgetExceeded as e:
        return JSONResponse({"detail": str(e)}, status_code=429)
    except tiles.TileUnavailable as e:
        raise HTTPException(502, str(e))
    except RuntimeError as e:
        raise HTTPException(503, str(e))
    return Response(data, media_type="image/jpeg", headers={"Cache-Control": "public, max-age=86400"})


@app.post("/api/samples/mosaic")
def create_mosaic(req: MosaicReq):
    z = config.NATIVE_ZOOM
    if req.x0 is None or req.y0 is None:
        if req.lon is None or req.lat is None:
            raise HTTPException(400, "حدد lon/lat أو x0/y0")
        fx, fy = lonlat_to_tile(req.lon, req.lat, z)
        x0, y0 = int(round(fx - req.nx / 2)), int(round(fy - req.ny / 2))
    else:
        x0, y0 = req.x0, req.y0
    if not (1 <= req.nx <= 6 and 1 <= req.ny <= 6):
        raise HTTPException(400, "الحجم من 1 إلى 6 بلاطات")
    try:
        meta, existed = store.create_from_mosaic(z, x0, y0, req.nx, req.ny, fixture=req.fixture)
    except tiles.BudgetExceeded as e:
        raise HTTPException(429, str(e))
    except (store.SampleError, tiles.TileUnavailable, ValueError) as e:
        _err(e)
    except RuntimeError as e:
        raise HTTPException(503, str(e))
    return {"existing": existed, "metadata": meta}


@app.get("/api/samples/estimate")
def estimate(lon: float, lat: float, nx: int = 3, ny: int = 3):
    z = config.NATIVE_ZOOM
    fx, fy = lonlat_to_tile(lon, lat, z)
    x0, y0 = int(round(fx - nx / 2)), int(round(fy - ny / 2))
    return {"x0": x0, "y0": y0, "new_tiles": tiles.count_missing(z, x0, y0, nx, ny), "budget": tiles.budget_status()}


@app.post("/api/samples/import")
async def import_geotiff(file: UploadFile = File(...), crop: str | None = Form(None)):
    suffix = Path(file.filename or "x.tif").suffix.lower()
    if suffix not in (".tif", ".tiff", ".gtiff"):
        raise HTTPException(400, "الملف يجب أن يكون GeoTIFF (.tif)")
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "upload.tif"
        with open(p, "wb") as fh:
            while chunk := await file.read(1 << 20):
                fh.write(chunk)
        cr = tuple(float(v) for v in crop.split(",")) if crop else None
        try:
            meta, existed = store.create_from_geotiff(p, filename=file.filename, crop_lonlat=cr)
        except Exception as e:  # rasterio errors are varied
            _err(e)
    return {"existing": existed, "metadata": meta}


@app.get("/api/samples")
def list_samples():
    out = []
    for m in store.list_samples():
        a = m.get("annotation") or {}
        out.append({"sample_id": m["sample_id"], "status": m["status"], "fixture": m.get("fixture", False),
                    "centre": m["georef"]["centre_wgs84"], "n_tracks": a.get("n_tracks", 0),
                    "terrain": m.get("terrain"), "source": m["source"]["type"], "updated_utc": m["updated_utc"]})
    return out


@app.get("/api/samples/{sid}")
def get_sample(sid: str):
    try:
        m = store.read_metadata(sid)
    except store.SampleError as e:
        raise HTTPException(404, str(e))
    prev = json.loads((store.sample_dir(sid) / "preview.json").read_text())
    return {"metadata": m, "geojson": store.read_tracks(sid), "preview": prev, "suggestions": store.read_suggestions(sid)}


@app.get("/api/samples/{sid}/file/{name}")
def sample_file(sid: str, name: str):
    allowed = {"preview.jpg", "overlay.png", "mask.png", "mask_types.png", "mask_edges.png", "image.tif", "mask.tif",
               "tracks.geojson", "metadata.json"}
    if name not in allowed:
        raise HTTPException(404)
    p = store.sample_dir(sid) / name
    if not p.is_file():
        raise HTTPException(404)
    return FileResponse(p, headers={"Cache-Control": "no-cache"})


@app.put("/api/samples/{sid}/annotations")
def put_annotations(sid: str, req: AnnotReq):
    updates = {k: v for k, v in (("terrain", req.terrain), ("clarity", req.clarity), ("notes", req.notes),
                                 ("complete", req.complete), ("rejected_suggestions", req.rejected_suggestions)) if v is not None}
    try:
        meta = store.save_annotations(sid, req.geojson, updates, req.mask_width_m)
        q = quality.check_sample(sid)
    except store.SampleError as e:
        _err(e)
    return {"metadata": meta, "quality": q}


@app.post("/api/samples/{sid}/suggest")
def start_suggest(sid: str, req: SuggestReq):
    try:
        store.read_metadata(sid)
    except store.SampleError as e:
        raise HTTPException(404, str(e))
    if req.backend not in ("auto", "sam_road", "ridge"):
        raise HTTPException(400, "backend غير معروف")
    return {"job": suggest.start_job(sid, req.backend)}


@app.get("/api/jobs/{jid}")
def get_job(jid: str):
    j = suggest.JOBS.get(jid)
    if not j:
        raise HTTPException(404, "مهمة غير موجودة")
    return j


@app.get("/api/impact/{sid}")
def get_impact(sid: str):
    try:
        return collect.impact(sid)
    except store.SampleError as e:
        raise HTTPException(404, str(e))


class VerdictReq(BaseModel):
    pid: str
    verdict: str
    reason: str | None = None
    ms: int | None = None
    line_px: list | None = None
    edits: list | None = None
    more_tracks: bool = False


@app.get("/api/review/deck")
def review_deck():
    d = review.load_deck()
    done = {v["pid"] for v in review.read_verdicts()}
    prog = review.progress(d)
    if not d:
        return {"ready": False, "progress": prog, "build": review.JOB, "reasons": {k: v[0] for k, v in review.REASONS.items()}}
    cards = [review.card_payload(c) for c in d["cards"] if c["pid"] not in done]
    return {"ready": True, "progress": prog, "cards": cards, "meta": {k: d[k] for k in ("created_utc", "sources_count", "controls", "unavailable_sources", "non_osm_share") if k in d},
            "batches": {k: {kk: v.get(kk) for kk in ("n_cards", "strata_evidence", "caveats", "composition")} for k, v in d.get("batches", {}).items()},
            "reasons": {k: v[0] for k, v in review.REASONS.items()}, "build": review.JOB}


@app.post("/api/review/build")
def review_build(cards: int = 60):
    return review.start_build(cards)


@app.get("/api/review/img/{pid}.jpg")
def review_img(pid: str):
    c = review.card_by_id(pid)
    if not c:
        raise HTTPException(404)
    try:
        im = review.crop_image(c)
    except tiles.BudgetExceeded as e:
        return JSONResponse({"detail": str(e)}, status_code=429)
    except (tiles.TileUnavailable, RuntimeError) as e:
        raise HTTPException(502, str(e))
    import io
    b = io.BytesIO()
    im.save(b, "JPEG", quality=88)
    return Response(b.getvalue(), media_type="image/jpeg", headers={"Cache-Control": "public, max-age=3600"})


@app.get("/api/review/snap/{pid}")
def review_snap(pid: str, wide: bool = False):
    c = review.card_by_id(pid)
    if not c:
        raise HTTPException(404)
    return review.snap(c, 64.0 if wide else 16.0)


@app.post("/api/review/verdict")
def review_verdict(req: VerdictReq):
    try:
        rec = review.verdict(req.pid, req.verdict, req.reason, req.ms, req.line_px, req.edits, req.more_tracks)
    except KeyError as e:
        raise HTTPException(404, str(e))
    except (ValueError, store.SampleError) as e:
        _err(e)
    return {"verdict": rec, "progress": review.progress()}


@app.post("/api/review/undo")
def review_undo():
    last = review.undo_last()
    return {"undone": last, "progress": review.progress()}


@app.get("/api/review/stats")
def review_stats():
    return {**review.stats(), "progress": review.progress()}


@app.delete("/api/samples/{sid}")
def delete_sample(sid: str):
    store.delete_sample(sid)
    return {"deleted": sid}


@app.get("/api/collection/status")
def collection_status():
    a = collect.analyse()
    for v in a["types"].values():
        v.pop("_regions", None)
    return a


@app.get("/api/collection/batch")
def collection_batch(create: bool = True):
    return collect.current_batch(create=create)


@app.post("/api/collection/skip")
def collection_skip(req: SkipReq):
    try:
        return collect.skip_window(req.window_id, req.reason)
    except KeyError as e:
        raise HTTPException(404, str(e))


@app.post("/api/export")
def do_export(req: ExportReq):
    try:
        root = export_mod.run_export(gsd=req.gsd, tile=req.tile, include_fixtures=req.include_fixtures,
                                     keep_empty=req.keep_empty, only_complete=req.only_complete, seed=req.seed, block_km=req.block_km,
                                     buffer_m=req.buffer_m)
    except (ValueError, FileExistsError) as e:
        _err(e)
    rep = json.loads((root / "quality_report.json").read_text())
    return {"path": str(root), "ready_for_training": rep["ready_for_training"], "counts": rep["counts"],
            "integrity_passed": rep["integrity_passed"], "sufficiency_issues": rep["sufficiency_issues"]}


@app.middleware("http")
async def _no_cache_static(request, call_next):
    resp = await call_next(request)
    p = request.url.path
    if not p.startswith(("/tiles/", "/api/")) and "Cache-Control" not in resp.headers:
        resp.headers["Cache-Control"] = "no-cache"   # the UI files change between versions
    return resp


app.mount("/", StaticFiles(directory=config.STATIC_DIR, html=True), name="static")
