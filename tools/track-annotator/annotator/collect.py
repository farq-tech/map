"""Smart data collection: what the annotated data is missing, aggregated into ONE batch request.

* Analyses every owner-annotated sample (programmatic ``fixture`` samples are ignored).
* Under-represented track types are compared against ``config/targets.json``.
* All needs are merged into a single batch of candidate windows (real tile windows near
  OSM-mapped tracks / the known study areas, see ``scripts/build_candidates.py``).
* Never re-asks: windows overlapping imagery already supplied, windows the owner skipped,
  and windows of a still-open batch are not proposed again.
"""
from __future__ import annotations

import json
import math
from datetime import datetime, timezone

from . import config, store
from .geo import lonlat_to_tile, region_cell, tile_to_lonlat

CANDIDATES_FILE = config.CONFIG_DIR / "candidates.json"
TARGETS_FILE = config.CONFIG_DIR / "targets.json"
MAX_WINDOWS = 24
OVERLAP_COVERED = 0.30


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def load_targets() -> dict:
    t = json.loads(TARGETS_FILE.read_text())
    return t


def load_candidates() -> list[dict]:
    if not CANDIDATES_FILE.is_file():
        return []
    return json.loads(CANDIDATES_FILE.read_text())["windows"]


# --------------------------------------------------------------------- analysis
def analyse() -> dict:
    """Per-type / per-terrain statistics over owner-annotated (non-fixture) samples."""
    tg = load_targets()
    types = {t: {"tracks": 0, "length_km": 0.0, "samples": set(), "regions": set(), "faint_or_worse": 0}
             for t in config.TRACK_TYPES}
    terrains: dict[str, int] = {}
    n_samples = 0
    for m in store.list_samples(include_fixtures=False):
        a = m.get("annotation")
        if not a or not a.get("n_tracks"):
            continue
        n_samples += 1
        if m.get("terrain"):
            terrains[m["terrain"]] = terrains.get(m["terrain"], 0) + 1
        for t, s in a["by_type"].items():
            d = types[t]
            d["tracks"] += s["n"]
            d["length_km"] += s["length_m"] / 1000.0
            d["samples"].add(m["sample_id"])
            d["regions"].add(m["region_cell"])
    out = {}
    for t, d in types.items():
        tgt = tg["per_type"].get(t, tg["default"])
        have = {"tracks": d["tracks"], "length_km": round(d["length_km"], 3),
                "samples": len(d["samples"]), "regions": len(d["regions"])}
        need = {"tracks": max(0, tgt["min_tracks"] - have["tracks"]),
                "length_km": round(max(0.0, tgt["min_length_km"] - have["length_km"]), 3),
                "regions": max(0, tgt["min_regions"] - have["regions"])}
        frac = min(1.0, have["tracks"] / tgt["min_tracks"], have["length_km"] / tgt["min_length_km"],
                   have["regions"] / tgt["min_regions"])
        out[t] = {"label": config.TRACK_TYPES[t], "have": have, "target": tgt, "need": need,
                  "progress": round(frac, 3), "deficient": frac < 1.0,
                  "_regions": sorted(d["regions"])}
    return {"annotated_samples": n_samples, "types": out, "terrains": terrains,
            "generated_utc": _now()}


# --------------------------------------------------------------------- coverage
def _rect_of_bbox(bbox, z: int = config.NATIVE_ZOOM):
    w, s, e, n = bbox
    x0, y1 = lonlat_to_tile(w, s, z)
    x1, y0 = lonlat_to_tile(e, n, z)
    return (x0, y0, x1, y1)


def _window_rect(w: dict):
    t = w["tiles"]
    return (t["x0"], t["y0"], t["x0"] + t["nx"], t["y0"] + t["ny"])


def _overlap_frac(a, b) -> float:
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    area = (a[2] - a[0]) * (a[3] - a[1])
    return ix * iy / area if area > 0 else 0.0


def supplied_rects() -> list[tuple]:
    return [_rect_of_bbox(m["georef"]["bbox_wgs84"]) for m in store.list_samples()
            if (m.get("annotation") or {}).get("n_tracks") or m.get("fixture")]


# --------------------------------------------------------------------- batches
def _batch_files():
    config.BATCH_DIR.mkdir(parents=True, exist_ok=True)
    return sorted(config.BATCH_DIR.glob("batch-*.json"))


def _load_batches() -> list[dict]:
    return [json.loads(p.read_text()) for p in _batch_files()]


def _save_batch(b: dict) -> None:
    p = config.BATCH_DIR / f"{b['batch_id']}.json"
    p.write_text(json.dumps(b, ensure_ascii=False, indent=2))
    (config.BATCH_DIR / f"{b['batch_id']}.md").write_text(batch_markdown(b))


def _refresh_states(b: dict) -> dict:
    """Mark windows done when supplied imagery now covers them; close fulfilled batches."""
    rects = supplied_rects()
    for w in b["windows"]:
        if w["state"] == "pending" and any(_overlap_frac(_window_rect(w), r) >= OVERLAP_COVERED for r in rects):
            w["state"] = "done"
    if b["status"] == "open" and not any(w["state"] == "pending" for w in b["windows"]):
        b["status"] = "fulfilled"
        b["closed_utc"] = _now()
    return b


def _excluded_ids(batches: list[dict]) -> set[str]:
    """Windows that must not be proposed again: any window of ANY earlier batch."""
    return {w["id"] for b in batches for w in b["windows"]}


def build_batch(analysis: dict, exclude_ids: set[str]) -> dict | None:
    cands = load_candidates()
    rects = supplied_rects()
    pool = [c for c in cands if c["id"] not in exclude_ids
            and not any(_overlap_frac(_window_rect(c), r) >= OVERLAP_COVERED for r in rects)]
    deficient = {t: v for t, v in analysis["types"].items() if v["deficient"]}
    if not deficient:
        return None
    need_km = {t: max(v["need"]["length_km"], 0.0) for t, v in deficient.items()}
    need_reg = {t: v["need"]["regions"] for t, v in deficient.items()}
    seen_regions = {t: set(v["_regions"]) for t, v in deficient.items()}
    chosen: list[dict] = []
    used_ids: set[str] = set()
    while pool and len(chosen) < MAX_WINDOWS and (any(x > 0 for x in need_km.values()) or any(x > 0 for x in need_reg.values())):
        best, best_score, best_for = None, 0.0, []
        for c in pool:
            if c["id"] in used_ids or any(_overlap_frac(_window_rect(c), _window_rect(w)) >= OVERLAP_COVERED for w in chosen):
                continue  # never propose two overlapping windows in one batch
            score, for_types = 0.0, []
            for t in deficient:
                hint_km = min(c["type_hint_m"].get(t, 0.0) / 1000.0, 1.2)
                if hint_km <= 0:
                    continue
                gain = min(need_km[t], hint_km) if need_km[t] > 0 else 0.0
                if need_reg[t] > 0 and c["region_cell"] not in seen_regions[t]:
                    gain += 0.5 * min(1.0, hint_km)  # new region bonus
                if gain > 0:
                    score += gain * c.get("confidence", {}).get(t, 1.0)
                    for_types.append(t)
            # light preference for study-area windows (known ground)
            if score > 0 and c.get("source") == "study_area":
                score *= 1.25
            if score > best_score:
                best, best_score, best_for = c, score, for_types
        if not best:
            break
        used_ids.add(best["id"])
        w = {k: best[k] for k in ("id", "tiles", "centre", "bbox", "region_cell", "source", "hint_note")}
        w.update(for_types=best_for, state="pending", hint_m={t: best["type_hint_m"].get(t, 0) for t in best_for})
        chosen.append(w)
        for t in best_for:
            need_km[t] = max(0.0, need_km[t] - min(best["type_hint_m"].get(t, 0) / 1000.0, 1.2))
            if best["region_cell"] not in seen_regions[t]:
                seen_regions[t].add(best["region_cell"])
                need_reg[t] = max(0, need_reg[t] - 1)
    unmet = [t for t in deficient if not any(t in w["for_types"] for w in chosen)]
    batches = _load_batches()
    n = len(batches) + 1
    b = {
        "batch_id": f"batch-{n:04d}",
        "created_utc": _now(),
        "status": "open",
        "missing_types": [{"type": t, "label": v["label"], "have": v["have"], "target": v["target"],
                           "need": v["need"], "progress": v["progress"]} for t, v in deficient.items()],
        "types_without_candidates": unmet,
        "windows": chosen,
        "estimate": {"windows": len(chosen), "tiles_upper_bound": sum(w["tiles"]["nx"] * w["tiles"]["ny"] for w in chosen)},
        "note": "اقتراحات النوافذ من خطوط OSM (ضعيفة الثقة) ومناطق الدراسة المعروفة؛ الحكم النهائي بصريًا للمالك.",
    }
    return b


def current_batch(create: bool = True) -> dict:
    """Return the open batch (refreshed), or create ONE new batch if none is open."""
    batches = _load_batches()
    open_b = [b for b in batches if b["status"] == "open"]
    if open_b:
        b = _refresh_states(open_b[-1])
        _save_batch(b)
        if b["status"] == "open":
            return b
        batches = _load_batches()
    analysis = analyse()
    if not create:
        return {"status": "none", "analysis_summary": summarize(analysis)}
    nb = build_batch(analysis, _excluded_ids(batches))
    if nb is None:
        return {"status": "none", "message": "كل الأنواع بلغت أهدافها الحالية — لا حاجة لدفعة جديدة.",
                "analysis_summary": summarize(analysis)}
    _save_batch(nb)
    return nb


def skip_window(window_id: str, reason: str = "") -> dict:
    for p in _batch_files():
        b = json.loads(p.read_text())
        for w in b["windows"]:
            if w["id"] == window_id and w["state"] == "pending":
                w["state"] = "skipped"
                w["skip_reason"] = reason[:200]
                b = _refresh_states(b)
                _save_batch(b)
                return b
    raise KeyError("النافذة غير موجودة أو ليست معلّقة")


def summarize(analysis: dict) -> dict:
    return {t: {"label": v["label"], "have": v["have"], "progress": v["progress"], "deficient": v["deficient"]}
            for t, v in analysis["types"].items()}


def batch_markdown(b: dict) -> str:
    L = [f"# طلب دفعة بيانات — {b['batch_id']}", "",
         "طلب واحد مجمّع. افتح كل نافذة واحدة واحدة ثم ارسم الدروب فيها دفعة واحدة؛ لن نطلب منك شيئًا آخر قبل إتمامها.", "",
         "## الأنواع الناقصة", ""]
    for m in b["missing_types"]:
        L.append(f"- **{m['label']}** (`{m['type']}`): لديك {m['have']['tracks']} مسار / {m['have']['length_km']} كم / "
                 f"{m['have']['regions']} منطقة — المطلوب إضافة ≈ {m['need']['tracks']} مسار، {m['need']['length_km']} كم، "
                 f"{m['need']['regions']} منطقة جديدة")
    if b.get("types_without_candidates"):
        L += ["", "> لا توجد نوافذ مرشحة لـ: " + "، ".join(b["types_without_candidates"]) + " (أضف مرشحات في config/candidates.json)"]
    L += ["", "## النوافذ المقترحة", "", "| # | المعرّف | المركز (lat, lon) | الأنواع المطلوبة | المصدر | الحالة |", "|---|---|---|---|---|---|"]
    for i, w in enumerate(b["windows"], 1):
        L.append(f"| {i} | {w['id']} | {w['centre'][1]:.5f}, {w['centre'][0]:.5f} | "
                 f"{'، '.join(config.TRACK_TYPES[t] for t in w['for_types'])} | {w['source']} | {w['state']} |")
    L += ["", b.get("note", "")]
    return "\n".join(L) + "\n"
