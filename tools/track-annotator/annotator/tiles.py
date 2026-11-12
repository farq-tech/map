"""Mapbox Satellite raster tiles: disk cache, request budget, mosaic into a georeferenced chip.

Reuses the endpoint/naming convention of the earlier ``sat-tracks-sample`` rounds
(``{z}_{x}_{y}@2x.jpg``) so tiles fetched there are served from disk instead of re-requested.
The token never leaves this module: it is placed in the request URL only and errors are
sanitised so it can not leak into logs or API responses.
"""
from __future__ import annotations

import io
import json
import threading
import time
from datetime import date
from pathlib import Path

import httpx
import numpy as np
from PIL import Image

from . import config
from .geo import Grid, mosaic_grid

_lock = threading.Lock()
_client: httpx.Client | None = None


class BudgetExceeded(RuntimeError):
    pass


class TileUnavailable(RuntimeError):
    pass


def tile_name(z: int, x: int, y: int) -> str:
    return f"{z}_{x}_{y}@2x.jpg"


def _cache_lookup(z: int, x: int, y: int) -> Path | None:
    name = tile_name(z, x, y)
    for d in [config.CACHE_DIR, *config.TILE_FALLBACK_DIRS]:
        p = d / name
        if p.is_file() and p.stat().st_size > 0:
            return p
    return None


def _budget_load() -> dict:
    try:
        return json.loads(config.BUDGET_FILE.read_text())
    except (OSError, ValueError):
        return {}


def budget_status() -> dict:
    d = _budget_load()
    today = date.today().isoformat()
    used = int(d.get(today, 0))
    return {"date": today, "used": used, "limit": config.DAILY_TILE_BUDGET,
            "remaining": max(0, config.DAILY_TILE_BUDGET - used)}


def _budget_take() -> None:
    with _lock:
        d = _budget_load()
        today = date.today().isoformat()
        used = int(d.get(today, 0))
        if used >= config.DAILY_TILE_BUDGET:
            raise BudgetExceeded(
                f"استُنفدت ميزانية الطلبات اليومية ({config.DAILY_TILE_BUDGET} بلاطة). "
                "ارفعها عبر MAPBOX_DAILY_BUDGET أو استعمل بلاطات مخزنة.")
        d = {today: used + 1}  # keep only today's counter
        config.BUDGET_FILE.parent.mkdir(parents=True, exist_ok=True)
        config.BUDGET_FILE.write_text(json.dumps(d))


def _http() -> httpx.Client:
    global _client
    if _client is None:
        _client = httpx.Client(timeout=30.0, follow_redirects=True,
                               headers={"User-Agent": "sary-track-annotator/0.1"})
    return _client


def get_tile(z: int, x: int, y: int, allow_network: bool = True) -> bytes:
    """Return JPEG bytes of the @2x (512 px) satellite tile; cached on disk."""
    n = 2 ** z
    if not (0 <= y < n):
        raise TileUnavailable("خارج نطاق البلاطات")
    x %= n
    hit = _cache_lookup(z, x, y)
    if hit:
        return hit.read_bytes()
    if not allow_network:
        raise TileUnavailable("البلاطة غير مخزنة")
    _budget_take()
    url = (f"https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}@2x.jpg90"
           f"?access_token={config.mapbox_token()}")
    try:
        r = _http().get(url)
    except httpx.HTTPError as e:  # message may embed the URL -> sanitise
        raise TileUnavailable(f"تعذر الاتصال بـ Mapbox ({type(e).__name__})") from None
    if r.status_code != 200:
        raise TileUnavailable(f"Mapbox رد بالحالة {r.status_code}")
    config.CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = config.CACHE_DIR / tile_name(z, x, y)
    tmp = path.with_suffix(".tmp")
    tmp.write_bytes(r.content)
    tmp.replace(path)
    time.sleep(0.05)  # be polite
    return r.content


def count_missing(z: int, x0: int, y0: int, nx: int, ny: int) -> int:
    return sum(1 for j in range(ny) for i in range(nx) if _cache_lookup(z, x0 + i, y0 + j) is None)


def fetch_mosaic(z: int, x0: int, y0: int, nx: int, ny: int) -> tuple[np.ndarray, Grid]:
    """Mosaic nx*ny tiles into an RGB uint8 array (H, W, 3) with its exact EPSG:3857 grid."""
    if nx * ny > 36:
        raise ValueError("النافذة كبيرة جدًا (الحد 6×6 بلاطات)")
    missing = count_missing(z, x0, y0, nx, ny)
    st = budget_status()
    if missing > st["remaining"]:
        raise BudgetExceeded(f"النافذة تحتاج {missing} طلبًا جديدًا والمتبقي {st['remaining']} فقط اليوم.")
    px = config.TILE_PX
    out = np.zeros((ny * px, nx * px, 3), np.uint8)
    for j in range(ny):
        for i in range(nx):
            img = Image.open(io.BytesIO(get_tile(z, x0 + i, y0 + j))).convert("RGB")
            if img.size != (px, px):
                raise TileUnavailable(f"حجم بلاطة غير متوقع {img.size}")
            out[j * px:(j + 1) * px, i * px:(i + 1) * px] = np.asarray(img)
    return out, mosaic_grid(z, x0, y0, nx, ny, px)
