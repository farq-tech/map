"""Review mode: the machine proposes, the owner says صح / خطأ (a card stack, one short segment per card).

Proposal sources (provenance kept on every card and in every label):
  model          local SAM-Road checkpoint (MPS/CPU)           - weak, out of domain
  ridge_filter   Sato/Meijering ridge filter fallback           - weak
  osm_gps_weak   OSM track/path lines (weak labels)             - candidate windows in config/candidates.json
  desertmaps     DesertMaps lines (owner-supplied study data)   - tier "unverified" => needs per-line review
Controls (excluded from source precision): shifted-wrong (a real line moved ~120 m), likely-right
(DesertMaps lines that match OSM) and repeats of earlier cards (self-consistency).

A verdict becomes a label on a small sample window (2x2 z17 tiles): ✓ -> centreline (human_verified),
✗ -> hard negative with a category, منزاح -> logged for offset correction, تخطّى -> nothing.
The owner's reference GPS trace is never loaded here.
"""
from __future__ import annotations

import json
import math
import os
import random
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from PIL import Image

from . import collect, config, store, tiles
from .geo import GEOD, Grid, lonlat_to_tile, mosaic_grid, transformer

CARD_PX = 512
MAX_SEG_M = 260.0
MIN_SEG_M = 60.0
DESERTMAPS = Path(os.environ.get("DESERTMAPS_GEOJSON",
                                 "~/code/map-wt/desertmaps-study-data/geojson/desertmaps_cleaned_v1.geojson")).expanduser()
REVIEW_DIR = config.DATA_DIR / "review"
DECK = REVIEW_DIR / "deck.json"
VERDICTS = REVIEW_DIR / "verdicts.jsonl"
SOURCE_LABELS = {"model": "النموذج", "ridge_filter": "مرشّح خطوط", "osm_gps_weak": "OSM/GPS (ضعيف)",
                 "desertmaps_new": "DesertMaps (جديد غير OSM)", "desertmaps_matched": "DesertMaps (مطابق OSM)"}
REASONS = {  # chip -> hard-negative category (None = no label)
    "not_track": ("ليس درب", "other"), "fence_pipeline": ("سور/أنبوب", "fence"), "wadi": ("وادي", "wadi"),
    "paved": ("طريق معبّد", "plain_road"), "pivot": ("دائرة محور", "pivot_circle"), "offset": ("منزاح", None),
}
OSM_TYPE = {"track_grade5": "sandy", "track_grade4": "sandy", "track_grade3": "mixed", "track_grade2": "dirt",
            "track_grade1": "dirt", "track": "dirt", "path": "faint"}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# ------------------------------------------------------------------ geometry helpers
def _cum(coords):
    lon = [c[0] for c in coords]; lat = [c[1] for c in coords]
    d = [0.0]
    for i in range(1, len(coords)):
        d.append(d[-1] + GEOD.inv(lon[i - 1], lat[i - 1], lon[i], lat[i])[2])
    return d


def _cut(coords, s0, s1):
    """Sub-polyline between arc positions s0..s1 (metres), interpolated linearly in lon/lat."""
    d = _cum(coords)
    out = []

    def at(s):
        for i in range(1, len(d)):
            if d[i] >= s:
                t = (s - d[i - 1]) / max(d[i] - d[i - 1], 1e-9)
                return [coords[i - 1][0] + t * (coords[i][0] - coords[i - 1][0]), coords[i - 1][1] + t * (coords[i][1] - coords[i - 1][1])]
        return list(coords[-1])
    out.append(at(s0))
    out += [list(coords[i]) for i in range(len(coords)) if s0 < d[i] < s1]
    out.append(at(s1))
    return [[round(x, 7), round(y, 7)] for x, y in out]


def segment_of(coords, rng: random.Random, max_m=MAX_SEG_M):
    total = _cum(coords)[-1]
    if total < MIN_SEG_M:
        return None
    L = min(total, max_m)
    s = rng.uniform(0, total - L)
    return _cut(coords, s, s + L)


def card_geometry(c: dict) -> tuple[Grid, tuple[int, int]]:
    """EPSG:3857 mosaic grid of the card's 2x2 tiles and the 512-px crop offset inside it."""
    g = mosaic_grid(17, c["x0"], c["y0"], 2, 2)
    mx, my = g.lonlat_to_pixel(c["mid"][0], c["mid"][1])
    ox = int(np.clip(round(float(mx)) - CARD_PX // 2, 0, 2 * 512 - CARD_PX))
    oy = int(np.clip(round(float(my)) - CARD_PX // 2, 0, 2 * 512 - CARD_PX))
    return g, (ox, oy)


def line_px(c: dict) -> list[list[float]]:
    g, (ox, oy) = card_geometry(c)
    col, row = g.lonlat_to_pixel([p[0] for p in c["line"]], [p[1] for p in c["line"]])
    return [[round(float(x) - ox, 1), round(float(y) - oy, 1)] for x, y in zip(col, row)]


def px_to_lonlat(c: dict, pts: list[list[float]]) -> list[list[float]]:
    g, (ox, oy) = card_geometry(c)
    lon, lat = g.pixel_to_lonlat([p[0] + ox for p in pts], [p[1] + oy for p in pts])
    return [[round(float(a), 9), round(float(b), 9)] for a, b in zip(lon, lat)]


def crop_image(c: dict) -> Image.Image:
    rgb, grid = tiles.fetch_mosaic(17, c["x0"], c["y0"], 2, 2)
    _, (ox, oy) = card_geometry(c)
    return Image.fromarray(rgb[oy:oy + CARD_PX, ox:ox + CARD_PX])


def _tile_origin(mid):
    fx, fy = lonlat_to_tile(mid[0], mid[1], 17)
    return int(math.floor(fx - 0.5)), int(math.floor(fy - 0.5))


def _mk(source, line, rng_id, detail, conf=None, type_hint="dirt", type_source="default", control=None, extra=None):
    mid = line[len(line) // 2] if len(line) < 3 else _cut(line, 0, 1e9)[0]
    L = _cum(line)[-1]
    # mid = point at half length
    mid = _cut(line, L / 2, L / 2 + 0.01)[0]
    x0, y0 = _tile_origin(mid)
    return {"pid": rng_id, "source": source, "detail": detail, "conf": conf, "line": line, "mid": mid,
            "length_m": round(L, 1), "x0": x0, "y0": y0, "type_hint": type_hint, "type_source": type_source,
            "control": control, **(extra or {})}


# ------------------------------------------------------------------ source pools
def pool_desertmaps(rng: random.Random, n: int, tier="unverified") -> list[dict]:
    if not DESERTMAPS.is_file():
        return []
    fs = [f for f in json.load(open(DESERTMAPS))["features"]
          if f["properties"].get("tier") == tier and f["properties"].get("length_km", 0) >= 0.1]
    rng.shuffle(fs)
    out = []
    for f in fs:
        seg = segment_of(f["geometry"]["coordinates"], rng)
        if not seg:
            continue
        p = f["properties"]
        out.append(_mk("desertmaps_new" if tier == "unverified" else "desertmaps_matched", seg, f"dm-{p['fid']}-{len(out)}",
                       f"{p.get('region', '')} · {'جديد (لا يوجد في OSM)' if tier == 'unverified' else 'مطابق لـ OSM'}",
                       type_hint="dirt", control="likely_right" if tier == "verified_osm" else None,
                       extra={"region": p.get("region"), "non_osm": tier == "unverified"}))
        if len(out) >= n:
            break
    return out


def pool_osm(rng: random.Random, n: int) -> list[dict]:
    cands = collect.load_candidates()
    items = []
    for w in cands:
        for l in w.get("osm_lines", []):
            items.append((w, l))
    rng.shuffle(items)
    out = []
    for w, l in items:
        seg = segment_of(l["xy"], rng)
        if not seg:
            continue
        out.append(_mk("osm_gps_weak", seg, f"osm-{w['id']}-{len(out)}", f"OSM {l['c']} · {w['hint_note'][:40]}",
                       type_hint=OSM_TYPE.get(l["c"], "dirt"), type_source="hint", extra={"window": w["id"], "non_osm": False}))
        if len(out) >= n:
            break
    return out


def pool_algo(centres: list[tuple], backend: str, log=print) -> list[dict]:
    """Run ridge/SAM-Road on 2x2-tile mosaics around ``centres`` and keep the best ~250 m line in each."""
    from . import suggest, export
    from .geo import utm_crs_for
    out = []
    for lon, lat, osm_l in centres:
        x0, y0 = _tile_origin([lon, lat])
        try:
            rgb, grid = tiles.fetch_mosaic(17, x0, y0, 2, 2)
        except Exception as e:  # noqa: BLE001
            log("skip", lon, lat, e)
            continue
        urgb, valid, ug = export.warp_to_utm(rgb, grid, suggest.GSD, utm_crs_for(*grid.centre_lonlat()))
        try:
            lines, info = suggest.run_sam_road(urgb, valid) if backend == "model" else suggest.run_ridge(urgb, valid)
        except Exception as e:  # noqa: BLE001
            log("algo fail", e)
            continue
        feats = suggest._pixel_lines_to_lonlat(lines, ug)
        if not feats:
            continue
        def non_osm(f):
            return collect.disagreement([f["geometry"]["coordinates"]], osm_l)["precision"] in (None, 0.0) if osm_l else True
        novel = [f for f in feats if non_osm(f)]      # the owner's verdicts are most valuable where OSM has nothing
        best = max(novel or feats, key=lambda f: f["properties"]["confidence"] * min(f["properties"]["length_m"], 250))
        seg = best["geometry"]["coordinates"]
        L = _cum(seg)[-1]
        if L > MAX_SEG_M:
            seg = _cut(seg, (L - MAX_SEG_M) / 2, (L + MAX_SEG_M) / 2)
        out.append(_mk("model" if backend == "model" else "ridge_filter", seg, f"{backend[:3]}-{x0}-{y0}", f"{info.get('backend')} · ثقة {best['properties']['confidence']}",
                       conf=best["properties"]["confidence"], extra={"non_osm": bool(novel)}))
    return out


def shifted_control(p: dict, rng: random.Random, shift_m=120.0) -> dict:
    """A real line moved sideways by ~120 m: should be judged wrong (measures consistency)."""
    lon0, lat0 = p["line"][0]
    az = GEOD.inv(*p["line"][0], *p["line"][-1])[0] + 90 * rng.choice((-1, 1))
    line = []
    for lon, lat in p["line"]:
        lo, la, _ = GEOD.fwd(lon, lat, az, shift_m)
        line.append([round(lo, 7), round(la, 7)])
    c = _mk(p["source"], line, "ctl-" + p["pid"], "تحكّم: خط أُزيح 120 م", control="shifted_wrong")
    return c


# ------------------------------------------------------------------ deck
def build_deck(n_cards: int = 60, seed: int = 7, n_model: int = 4, n_ridge: int = 6, log=print) -> dict:
    rng = random.Random(seed)
    REVIEW_DIR.mkdir(parents=True, exist_ok=True)
    cands = collect.load_candidates()
    centres = [(w["centre"][0], w["centre"][1], [l["xy"] for l in w.get("osm_lines", [])]) for w in cands if w["source"] == "osm_weak"]
    rng.shuffle(centres)
    n_dm, n_osm = 32, 12      # ~75 % of non-control cards are NOT in OSM (desertmaps_new + model/ridge novel)
    pools = {
        "desertmaps_new": pool_desertmaps(rng, n_dm * 3),
        "osm_gps_weak": pool_osm(rng, n_osm * 3),
        "ridge_filter": pool_algo(centres[:n_ridge], "ridge", log) if n_ridge else [],
        "model": pool_algo(centres[n_ridge:n_ridge + n_model], "model", log) if n_model else [],
    }
    # value ranking inside each source (information value x diversity x novelty, same as the batch queue)
    analysis = collect.analyse()
    anchors = collect.labeled_centres()
    for src, items in pools.items():
        for p in items:
            pseudo = {"id": p["pid"], "centre": p["mid"], "type_hint_m": {p["type_hint"]: 600.0}, "confidence": {p["type_hint"]: 0.5}}
            v = collect.window_value(pseudo, analysis, anchors)
            p["value"], p["why"] = v["score"], v["why"]
        items.sort(key=lambda p: -p["value"])
    quota = {"osm_gps_weak": n_osm, "desertmaps_new": n_dm, "ridge_filter": n_ridge, "model": n_model}
    chosen: list[dict] = []
    for src, items in pools.items():
        chosen += items[:quota[src]]
    rng.shuffle(chosen)           # interleave sources
    # controls: 2 shifted-wrong, 2 likely-right (DesertMaps matching OSM), later 2 repeats
    base = [p for p in chosen if p["source"] in ("osm_gps_weak", "desertmaps_new")]
    ctl = [shifted_control(base[i], rng) for i in range(min(2, len(base)))] + pool_desertmaps(rng, 2, tier="verified_osm")
    for c in ctl:
        c.setdefault("non_osm", False)
    deck = chosen[:max(0, n_cards - len(ctl) - 2)]
    for i, c in enumerate(ctl):
        deck.insert(min(len(deck), 9 + i * 12), c)
    for j, k in enumerate((3, 8)):
        if k < len(deck):
            r = dict(deck[k]); r["pid"] = deck[k]["pid"] + "-rep"; r["control"] = "repeat"; r["repeat_of"] = deck[k]["pid"]
            deck.insert(min(len(deck), 40 + j * 12), r)
    for i, c in enumerate(deck):
        c["idx"] = i
    sources = {s: sum(1 for c in deck if c["source"] == s and not c.get("control")) for s in SOURCE_LABELS}
    obj = {"created_utc": _now(), "n_cards": len(deck), "sources_count": sources,
           "controls": {k: sum(1 for c in deck if c.get("control") == k) for k in ("shifted_wrong", "likely_right", "repeat")},
           "non_osm_share": round(sum(1 for c in deck if not c.get("control") and c.get("non_osm")) / max(1, sum(1 for c in deck if not c.get("control"))), 3),
           "unavailable_sources": [s for s, items in pools.items() if not items], "cards": deck}
    DECK.write_text(json.dumps(obj, ensure_ascii=False))
    return obj


def load_deck() -> dict | None:
    try:
        return json.loads(DECK.read_text())
    except (OSError, ValueError):
        return None


# ------------------------------------------------------------------ verdict log
def read_verdicts() -> list[dict]:
    if not VERDICTS.is_file():
        return []
    return [json.loads(l) for l in VERDICTS.read_text().splitlines() if l.strip()]


def _append(v: dict) -> None:
    REVIEW_DIR.mkdir(parents=True, exist_ok=True)
    with open(VERDICTS, "a") as fh:
        fh.write(json.dumps(v, ensure_ascii=False) + "\n")


def _rewrite(vs: list[dict]) -> None:
    VERDICTS.write_text("".join(json.dumps(v, ensure_ascii=False) + "\n" for v in vs))


def card_by_id(pid: str) -> dict | None:
    d = load_deck()
    return next((c for c in (d or {}).get("cards", []) if c["pid"] == pid), None)


# ------------------------------------------------------------------ applying verdicts to labels
def _sample_for(c: dict) -> tuple[dict, str]:
    meta, _ = store.create_from_mosaic(17, c["x0"], c["y0"], 2, 2)
    return meta, meta["sample_id"]


def _strip(fc: dict, pid: str) -> dict:
    return {"type": "FeatureCollection", "features": [f for f in fc["features"] if f["properties"].get("proposal_id") != pid]}


def apply_label(c: dict, verdict: str, reason: str | None, line_lonlat: list | None, edited: bool) -> str | None:
    """Write the label into the card's sample. Returns sample_id (or None when no label)."""
    if c.get("control"):
        return None  # controls never become labels
    if verdict not in ("correct", "correct_incomplete", "wrong"):
        return None
    if verdict == "wrong" and REASONS.get(reason, (None, None))[1] is None:
        return None
    meta, sid = _sample_for(c)
    fc = _strip(store.read_tracks(sid), c["pid"])
    geom = line_lonlat or c["line"]
    base = {"id": uuid.uuid4().hex[:10], "proposal_id": c["pid"], "proposal_source": c["source"]}
    if verdict in ("correct", "correct_incomplete"):
        fc["features"].append({"type": "Feature", "properties": {**base, "kind": "centerline", "track_type": c["type_hint"],
                               "clarity": 2, "source": "human_verified", "type_source": c["type_source"], "edited": bool(edited)},
                               "geometry": {"type": "LineString", "coordinates": geom}})
    else:
        fc["features"].append({"type": "Feature", "properties": {**base, "kind": "negative", "category": REASONS[reason][1], "reason": reason},
                               "geometry": {"type": "LineString", "coordinates": c["line"]}})
    upd = {}
    if verdict == "correct_incomplete":
        m = store.read_metadata(sid)
        m["review_more_tracks"] = True
        store._write_json(store.sample_dir(sid) / "metadata.json", m)
    store.save_annotations(sid, fc, upd)
    return sid


def verdict(pid: str, v: str, reason: str | None = None, ms: int | None = None, line_px_edit: list | None = None,
            edits: list | None = None) -> dict:
    c = card_by_id(pid)
    if not c:
        raise KeyError("بطاقة غير معروفة")
    if v not in ("correct", "correct_incomplete", "wrong", "skip"):
        raise ValueError("حكم غير صالح")
    if v == "wrong" and reason not in REASONS:
        raise ValueError("اختر سببًا")
    line = px_to_lonlat(c, line_px_edit) if line_px_edit else None
    edited = bool(line_px_edit) and bool(edits)
    sid = apply_label(c, v, reason, line, edited)
    rec = {"pid": pid, "source": c["source"], "control": c.get("control"), "verdict": v, "reason": reason, "ms": ms,
           "edited": edited, "edits": edits or [], "sample_id": sid, "ts": _now(), "repeat_of": c.get("repeat_of")}
    _append(rec)
    return rec


def undo_last() -> dict | None:
    vs = read_verdicts()
    if not vs:
        return None
    last = vs.pop()
    _rewrite(vs)
    if last.get("sample_id"):
        try:
            fc = _strip(store.read_tracks(last["sample_id"]), last["pid"])
            store.save_annotations(last["sample_id"], fc, {})
        except store.SampleError:
            pass
    return last


# ------------------------------------------------------------------ progress / stats
def wilson(k: int, n: int, z: float = 1.96) -> tuple[float, float] | None:
    if n == 0:
        return None
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return round((c - h) / d, 3), round((c + h) / d, 3)


def stats() -> dict:
    vs = read_verdicts()
    out = {}
    for src in SOURCE_LABELS:
        mine = [v for v in vs if v["source"] == src and not v["control"] and v["verdict"] != "skip"]
        ok = [v for v in mine if v["verdict"] in ("correct", "correct_incomplete")]
        raw = [v for v in ok if not v["edited"]]
        wrong = [v for v in mine if v["verdict"] == "wrong" and v["reason"] != "offset"]
        off = [v for v in mine if v["verdict"] == "wrong" and v["reason"] == "offset"]
        n = len(mine)
        out[src] = {"label": SOURCE_LABELS[src], "n": n, "approved": len(ok), "approved_unedited": len(raw), "wrong": len(wrong),
                    "offset": len(off), "precision_raw": round(len(raw) / n, 3) if n else None,
                    "precision_usable": round(len(ok) / n, 3) if n else None, "wilson95_raw": wilson(len(raw), n),
                    "wilson95_usable": wilson(len(ok), n)}
    ctl = [v for v in vs if v["control"] and v["verdict"] != "skip"]
    sw = [v for v in ctl if v["control"] == "shifted_wrong"]
    lr = [v for v in ctl if v["control"] == "likely_right"]
    rp = [v for v in ctl if v["control"] == "repeat"]
    first = {v["pid"]: v["verdict"] for v in vs if not v["control"]}
    agree = [1 if (first.get(v["repeat_of"], "")[:5] == v["verdict"][:5]) else 0 for v in rp if v.get("repeat_of") in first]
    ms = [v["ms"] for v in vs if v.get("ms") and v["verdict"] != "skip"]
    ok_all = [v for v in vs if v["verdict"] in ("correct", "correct_incomplete") and not v["control"]]
    return {"sources": out, "n_verdicts": len(vs),
            "controls": {"shifted_wrong_rejected": f"{sum(1 for v in sw if v['verdict'] == 'wrong')}/{len(sw)}",
                         "likely_right_accepted": f"{sum(1 for v in lr if v['verdict'] != 'wrong')}/{len(lr)}",
                         "repeat_consistent": f"{sum(agree)}/{len(agree)}"},
            "median_seconds_per_card": round(float(np.median(ms)) / 1000, 1) if ms else None,
            "edit_rate": round(sum(1 for v in ok_all if v["edited"]) / len(ok_all), 3) if ok_all else None}


def progress(deck: dict | None = None) -> dict:
    deck = deck or load_deck()
    if not deck:
        return {"total": 0, "done": 0, "left": 0, "minutes_left": 0}
    done = {v["pid"] for v in read_verdicts()}
    left = [c for c in deck["cards"] if c["pid"] not in done]
    ms = [v["ms"] for v in read_verdicts() if v.get("ms")]
    sec = float(np.median(ms)) / 1000 if len(ms) >= 3 else 10.0
    return {"total": len(deck["cards"]), "done": len(deck["cards"]) - len(left), "left": len(left),
            "minutes_left": round(len(left) * sec / 60, 1), "seconds_per_card": round(sec, 1)}


def card_payload(c: dict) -> dict:
    return {"pid": c["pid"], "idx": c.get("idx"), "source": c["source"], "source_label": SOURCE_LABELS[c["source"]],
            "detail": c["detail"], "conf": c.get("conf"), "control": bool(c.get("control")), "length_m": c["length_m"],
            "type_hint": c["type_hint"], "line_px": line_px(c), "size": CARD_PX,
            "img": f"/api/review/img/{c['pid']}.jpg", "why": c.get("why", [])}


# ------------------------------------------------------------------ one-tap snap (انطباق)
def snap(c: dict, max_shift_px: float = 16.0) -> dict:
    """Move the line onto the local ridge (track centre) using a Sato response of the card imagery.

    Stage 1: ONE rigid sideways shift (|shift| <= max_shift_px) that maximises the mean ridge response along the line
    (fixes whole-line offsets, e.g. DesertMaps 20-130 m). Stage 2: per-vertex refinement within +-8 px.
    """
    from skimage.color import rgb2gray
    from skimage.filters import sato
    from scipy.ndimage import map_coordinates, median_filter
    img = np.asarray(crop_image(c))
    g = rgb2gray(img)
    resp = np.maximum(sato(g, sigmas=(2.0, 3.0, 4.0), black_ridges=False), sato(g, sigmas=(2.0, 3.0, 4.0), black_ridges=True))
    resp = resp / (np.percentile(resp, 99.5) + 1e-9)
    pts = np.array(line_px(c), float)
    seg = np.hypot(*np.diff(pts, axis=0).T)
    cum = np.r_[0, np.cumsum(seg)]
    n = max(3, int(cum[-1] / 8) + 1)
    t = np.linspace(0, cum[-1], n)
    dense = np.stack([np.interp(t, cum, pts[:, 0]), np.interp(t, cum, pts[:, 1])], 1)
    tang = np.gradient(dense, axis=0)
    tang /= (np.linalg.norm(tang, axis=1, keepdims=True) + 1e-9)
    nrm = np.stack([-tang[:, 1], tang[:, 0]], 1)

    def mean_resp(sh):
        xy = dense + nrm * sh
        return float(map_coordinates(resp, [xy[:, 1], xy[:, 0]], order=1, mode="nearest").mean())
    cands = np.arange(-max_shift_px, max_shift_px + 0.5, 2.0)
    scores = np.array([mean_resp(sh) - 0.0015 * abs(sh) for sh in cands])
    rigid = float(cands[int(np.argmax(scores))])
    base = dense + nrm * rigid
    offs = np.arange(-8, 9, 1.0)
    fine = np.zeros(n)
    for i in range(n):
        xs = base[i, 0] + nrm[i, 0] * offs
        ys = base[i, 1] + nrm[i, 1] * offs
        v = map_coordinates(resp, [ys, xs], order=1, mode="nearest") - 0.01 * np.abs(offs)
        fine[i] = offs[int(np.argmax(v))]
    fine = median_filter(fine, size=7, mode="nearest")
    snapped = base + nrm * fine[:, None]
    from shapely.geometry import LineString
    out = np.array(LineString(snapped).simplify(1.5).coords)
    tot = rigid + fine
    return {"line_px": [[round(float(x), 1), round(float(y), 1)] for x, y in out],
            "rigid_shift_px": rigid, "mean_shift_px": round(float(np.mean(np.abs(tot))), 2), "max_shift_px": round(float(np.max(np.abs(tot))), 2),
            "response_before": round(mean_resp(0.0), 3), "response_after": round(float(map_coordinates(resp, [snapped[:, 1], snapped[:, 0]], order=1, mode="nearest").mean()), 3),
            "metres_per_px": round(mosaic_grid(17, c["x0"], c["y0"], 2, 2).ground_res_m(), 3)}


# ------------------------------------------------------------------ background deck build
JOB: dict = {}


def start_build(n_cards: int = 60) -> dict:
    if JOB.get("state") == "running":
        return JOB
    JOB.clear()
    JOB.update(state="running", started=time.time())

    def work():
        try:
            d = build_deck(n_cards)
            JOB.update(state="done", n_cards=d["n_cards"], sources=d["sources_count"], unavailable=d["unavailable_sources"])
        except Exception as e:  # noqa: BLE001
            JOB.update(state="error", error=str(e)[:300])
    threading.Thread(target=work, daemon=True).start()
    return JOB
