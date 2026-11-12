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

import numpy as np

from . import config, store
from .geo import block_xy, lonlat_to_tile, region_cell, tile_to_lonlat

CANDIDATES_FILE = config.CONFIG_DIR / "candidates.json"
TARGETS_FILE = config.CONFIG_DIR / "targets.json"
MAX_WINDOWS = 12
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
            if (m.get("annotation") or {}).get("n_tracks") or m.get("complete") or m.get("fixture")]


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


SCORES_FILE = config.DATA_DIR / "cache" / "window_scores.json"
MINUTES_BASE = 1.5          # open + look at the window
MINUTES_PER_KM = 3.0        # drawing time per expected km of tracks (OSM hint, capped at 1.5 km)
MODEL_SPEEDUP = 0.6         # accept/fix is faster than drawing from scratch (when a suggestion exists)


def load_scores() -> dict:
    try:
        return json.loads(SCORES_FILE.read_text())
    except (OSError, ValueError):
        return {}


def save_score(window_id: str, rec: dict) -> None:
    sc = load_scores()
    sc[window_id] = rec
    SCORES_FILE.parent.mkdir(parents=True, exist_ok=True)
    SCORES_FILE.write_text(json.dumps(sc, ensure_ascii=False, indent=1))


def disagreement(sug_lines_lonlat: list, osm_lines_lonlat: list, tol_m: float = 15.0) -> dict:
    """1 - F1 between model lines and OSM weak labels (both inside the window), tolerance 15 m."""
    from shapely.geometry import LineString
    from shapely.ops import unary_union
    from .geo import utm_crs_for, xform
    allc = [c for l in (sug_lines_lonlat + osm_lines_lonlat) for c in l]
    if not osm_lines_lonlat or not allc:
        return {"disagreement": None, "precision": None, "recall": None}
    utm = utm_crs_for(allc[0][0], allc[0][1])
    S = [xform(LineString(l), "EPSG:4326", utm) for l in sug_lines_lonlat if len(l) > 1]
    O = [xform(LineString(l), "EPSG:4326", utm) for l in osm_lines_lonlat if len(l) > 1]
    if not O:  # no OSM reference in this window -> no disagreement signal (caller falls back to the prior)
        return {"disagreement": None, "precision": None, "recall": None}
    if not S:
        return {"disagreement": 1.0, "precision": 0.0 if S else None, "recall": 0.0 if O else None}
    su, ou = unary_union(S), unary_union(O)
    prec = sum(l.intersection(ou.buffer(tol_m)).length for l in S) / max(sum(l.length for l in S), 1e-9)
    rec = sum(l.intersection(su.buffer(tol_m)).length for l in O) / max(sum(l.length for l in O), 1e-9)
    f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
    return {"disagreement": round(1 - f1, 3), "precision": round(prec, 3), "recall": round(rec, 3)}


def _entropy_norm(d: dict) -> float:
    v = np.array([x for x in d.values() if x > 0], float)
    if len(v) < 2:
        return 0.0
    p = v / v.sum()
    return float(-(p * np.log(p)).sum() / np.log(len(config.TRACK_TYPES)))


def labeled_centres() -> list[tuple[float, float]]:
    """Metric (EPSG:6933) centres of owner-annotated samples (fixtures excluded)."""
    out = []
    for m in store.list_samples(include_fixtures=False):
        if (m.get("annotation") or {}).get("n_tracks") or m.get("complete"):
            lon, lat = m["georef"]["centre_wgs84"]
            out.append(block_xy(lon, lat))
    return out


def window_value(c: dict, analysis: dict, anchors: list[tuple[float, float]], progress: dict | None = None) -> dict:
    """Expected information of annotating window ``c`` = uncertainty x diversity gap x spatial novelty."""
    progress = progress or {t: v["progress"] for t, v in analysis["types"].items()}
    hints = {t: m for t, m in c["type_hint_m"].items() if m > 0}
    # (a) uncertainty: model-vs-OSM disagreement if the model was run on this window, else an OSM-ambiguity prior
    sc = load_scores().get(c["id"])
    if sc and sc.get("disagreement") is not None:
        unc, usrc = max(0.1, sc["disagreement"]), f"model_vs_osm({sc['backend']})"
    else:
        conf = np.mean([c.get("confidence", {}).get(t, 0.5) for t in hints]) if hints else 0.5
        unc = float(np.clip(0.5 * _entropy_norm(hints) + 0.5 * (1 - conf), 0.1, 1.0))
        usrc = "osm_hint_prior"
    # (b) diversity gap: how much of the still-missing track types this window can supply
    gap_terms = {t: (1 - progress.get(t, 1.0)) * min(m / 1000.0, 1.2) / 1.2 * c.get("confidence", {}).get(t, 0.5) for t, m in hints.items()}
    div = float(np.clip(sum(gap_terms.values()) / max(1, len(config.TRACK_TYPES)) * 3.0, 0.05, 1.0))
    # (c) spatial-block novelty: distance to the nearest labelled/chosen window (10 km = fully novel)
    x, y = block_xy(*c["centre"])
    dist = min((math.hypot(x - ax, y - ay) for ax, ay in anchors), default=1e9)
    nov = float(np.clip(dist / 10000.0, 0.05, 1.0))
    km = min(max(hints.values(), default=0) / 1000.0, 1.2)
    minutes = (MINUTES_BASE + MINUTES_PER_KM * km) * (MODEL_SPEEDUP if sc else 1.0)
    need_types = sorted(gap_terms, key=lambda t: -gap_terms[t])
    why = []
    if need_types:
        t0 = need_types[0]
        why.append(f"نوع ناقص: {config.TRACK_TYPES[t0]} (تقدّمك {analysis['types'][t0]['progress']:.0%})")
    why.append(("كتلة مكانية جديدة" if dist >= 10000 else f"أقرب وسم لك على بعد {dist / 1000:.1f} كم")
               + (" — لا وسوم بعد" if not anchors else ""))
    why.append(f"عدم اليقين {unc:.2f} ({'اختلاف النموذج عن OSM' if usrc.startswith('model') else 'غموض فئات OSM — تقدير مسبق لا قياس'})")
    return {"score": round(unc * div * nov, 4), "uncertainty": round(unc, 3), "uncertainty_source": usrc,
            "diversity_gap": round(div, 3), "novelty": round(nov, 3), "novelty_km": None if dist > 1e8 else round(dist / 1000, 1),
            "est_minutes": round(minutes, 1), "why": why, "for_types": need_types[:3]}


def build_batch(analysis: dict, exclude_ids: set[str]) -> dict | None:
    cands = load_candidates()
    rects = supplied_rects()
    pool = [c for c in cands if c["id"] not in exclude_ids
            and not any(_overlap_frac(_window_rect(c), r) >= OVERLAP_COVERED for r in rects)]
    deficient = {t: v for t, v in analysis["types"].items() if v["deficient"]}
    if not deficient:
        return None
    progress = {t: v["progress"] for t, v in analysis["types"].items()}
    anchors = labeled_centres()
    chosen: list[dict] = []
    while pool and len(chosen) < MAX_WINDOWS:
        best, best_v = None, None
        for c in pool:
            if any(_overlap_frac(_window_rect(c), _window_rect(w)) >= OVERLAP_COVERED for w in chosen):
                continue
            if not any(t in deficient and c["type_hint_m"].get(t, 0) > 0 for t in c["type_hint_m"]):
                continue
            v = window_value(c, analysis, anchors, progress)
            if best_v is None or v["score"] > best_v["score"]:
                best, best_v = c, v
        if not best or best_v["score"] <= 0:
            break
        w = {k: best[k] for k in ("id", "tiles", "centre", "bbox", "region_cell", "source", "hint_note")}
        for_types = [t for t in best_v["for_types"] if t in deficient] or best_v["for_types"]
        w.update(best_v, for_types=for_types, state="pending", priority=len(chosen) + 1,
                 hint_m={t: best["type_hint_m"].get(t, 0) for t in for_types})
        chosen.append(w)
        anchors = anchors + [block_xy(*best["centre"])]                    # spread the batch spatially
        for t in for_types:                                                # diminishing returns per type
            progress[t] = min(1.0, progress.get(t, 0) + min(best["type_hint_m"].get(t, 0) / 1000.0, 1.2)
                              / max(deficient[t]["target"]["min_length_km"], 1e-9))
    unmet = [t for t in deficient if not any(t in w["for_types"] for w in chosen)]
    batches = _load_batches()
    n = len(batches) + 1
    total_min = round(sum(w["est_minutes"] for w in chosen), 1)
    b = {
        "batch_id": f"batch-{n:04d}",
        "created_utc": _now(),
        "status": "open",
        "ranking": "expected information = uncertainty x diversity gap x spatial novelty (see window.why)",
        "missing_types": [{"type": t, "label": v["label"], "have": v["have"], "target": v["target"],
                           "need": v["need"], "progress": v["progress"]} for t, v in deficient.items()],
        "types_without_candidates": unmet,
        "windows": chosen,
        "estimate": {"windows": len(chosen), "tiles_upper_bound": sum(w["tiles"]["nx"] * w["tiles"]["ny"] for w in chosen),
                     "minutes_total": total_min,
                     "minutes_formula": f"{MINUTES_BASE} د + {MINUTES_PER_KM} د لكل كم متوقع (الأطول بين التلميحات، حدّ 1.2 كم)، ×{MODEL_SPEEDUP} إن وُجد مقترح نموذج"},
        "note": "الأولوية = عدم اليقين × فجوة التنوّع × جِدّة الكتلة المكانية. أرقام الدقائق تقديرية. "
                "النوافذ من OSM (ضعيفة الثقة)؛ الحكم النهائي بصريًا للمالك.",
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
    est = b.get("estimate", {})
    L += ["", f"## النوافذ المقترحة (الأعلى قيمة أولًا) — إجمالي ≈ {est.get('minutes_total', '?')} دقيقة", "",
          "| # | المركز (lat, lon) | الأنواع | ≈دقائق | القيمة | لماذا | الحالة |", "|---|---|---|---|---|---|---|"]
    for i, w in enumerate(b["windows"], 1):
        L.append(f"| {i} | {w['centre'][1]:.5f}, {w['centre'][0]:.5f} | "
                 f"{'، '.join(config.TRACK_TYPES[t] for t in w['for_types'])} | {w.get('est_minutes', '?')} | {w.get('score', '?')} | "
                 f"{' ؛ '.join(w.get('why', []))} | {w['state']} |")
    L += ["", b.get("note", "")]
    return "\n".join(L) + "\n"


# --------------------------------------------------------------------- «أثر وسمك»
def split_preview(exclude_sample: str | None = None, tile_m: float = 400.0, block_km: float = 5.0, buffer_m: float = 500.0) -> dict:
    """Cheap estimate of the spatial split (400 m grid inside each annotated sample footprint)."""
    from shapely.geometry import box as sbox
    from . import splits
    tiles_ = []
    for m in store.list_samples(include_fixtures=False):
        if m["sample_id"] == exclude_sample or not ((m.get("annotation") or {}).get("n_tracks") or m.get("complete")):
            continue
        poly = splits.tile_footprint_m(store.grid_of(m).corners_lonlat())
        x0, y0, x1, y1 = poly.bounds
        i = 0
        for gx in np.arange(x0, x1 - tile_m * 0.5, tile_m):
            for gy in np.arange(y0, y1 - tile_m * 0.5, tile_m):
                t = sbox(gx, gy, gx + tile_m, gy + tile_m)
                if poly.contains(t.centroid):
                    tiles_.append({"id": f"{m['sample_id']}:{i}", "footprint": t})
                    i += 1
    if not tiles_:
        return {"tiles": {s: 0 for s in splits.SPLITS}, "blocks": 0, "leakage_ok": True, "assign": {}, "min_distance_m": {}}
    sp = splits.split_tiles(tiles_, load_targets()["split"], block_m=block_km * 1000, buffer_m=buffer_m)
    leak = splits.check_leakage(tiles_, sp["assign"], buffer_m)
    return {"tiles": leak["counts"], "blocks": len(sp["blocks"]), "dropped_by_buffer": len(sp["dropped"]),
            "leakage_ok": leak["ok"], "min_distance_m": leak["min_distance_m"], "assign": sp["assign"]}


def impact(sample_id: str) -> dict:
    """What THIS sample added, split impact, remaining need, and model-quality signals."""
    m = store.read_metadata(sample_id)
    ann = m.get("annotation") or {}
    a = analyse()
    added = {t: round(v["length_m"] / 1000.0, 3) for t, v in ann.get("by_type", {}).items()}
    types = {}
    for t, v in a["types"].items():
        before = max(0.0, v["have"]["length_km"] - added.get(t, 0.0)) if not m.get("fixture") else v["have"]["length_km"]
        types[t] = {"label": v["label"], "added_km": added.get(t, 0.0), "total_km": v["have"]["length_km"],
                    "target_km": v["target"]["min_length_km"], "remaining_km": v["need"]["length_km"],
                    "progress": v["progress"], "progress_before": round(min(1.0, before / v["target"]["min_length_km"]), 3)}
    after = split_preview()
    before = split_preview(exclude_sample=sample_id)
    flipped = sum(1 for k, s in before["assign"].items() if k in after["assign"] and after["assign"][k] != s)
    neg_km = {c: round(v["length_m"] / 1000.0, 3) for c, v in (ann.get("negatives_by_category") or {}).items()}
    sg = ann.get("suggestions")
    allsg = [x.get("annotation", {}).get("suggestions") for x in store.list_samples(include_fixtures=False)]
    allsg = [x for x in allsg if x]
    tot = {k: sum(x[k] for x in allsg) for k in ("n_suggested", "accepted_unchanged", "accepted_corrected", "rejected", "added_by_hand")} if allsg else None
    return {
        "sample_id": sample_id, "fixture": bool(m.get("fixture")), "complete": bool(m.get("complete")),
        "added_km_total": round(sum(added.values()), 3), "types": types,
        "negatives_km": neg_km,
        "split": {"after": {k: after[k] for k in ("tiles", "blocks", "leakage_ok", "min_distance_m", "dropped_by_buffer")},
                  "before": {k: before[k] for k in ("tiles", "blocks")}, "tiles_changing_split": flipped,
                  "note": "تقدير بشبكة 400 م؛ التصدير الفعلي يعيد الحساب بدقة. عينات fixture خارج الحساب."},
        "model_quality_this_sample": sg,
        "model_quality_all": tot,
        "annotated_samples": a["annotated_samples"],
        "complete_samples": sum(1 for x in store.list_samples(include_fixtures=False) if x.get("complete")),
        "unflagged_samples": sum(1 for x in store.list_samples(include_fixtures=False)
                                 if (x.get("annotation") or {}).get("n_tracks") and not x.get("complete")),
    }
